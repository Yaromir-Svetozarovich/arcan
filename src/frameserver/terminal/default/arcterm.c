#include <arcan_shmif.h>
#include <stdio.h>
#include <arcan_tui.h>
#include <inttypes.h>
#include <stdarg.h>
#include <sys/types.h>
#include <sys/stat.h>
#include <sys/socket.h>
#include <pwd.h>
#include <ctype.h>
#include <signal.h>
#include <pthread.h>
#include <poll.h>
#include <unistd.h>

#include "cli.h"
#include "cli_builtin.h"

#include "tsm/libtsm.h"
#include "tsm/libtsm_int.h"
#include "tsm/shl-pty.h"

static struct {
	struct tui_context* screen;
	struct tsm_vte* vte;
	struct shl_pty* pty;
	struct arg_arr* args;

	pthread_mutex_t synch;
	pthread_mutex_t hold;

	pid_t child;

	_Atomic volatile bool alive;
	bool die_on_term;
	bool complete_signal;
	bool pipe;

	long last_input;

/* sockets to communicate between terminal thread and render thread */
	int dirtyfd;
	int signalfd;

} term = {
	.die_on_term = true,
	.synch = PTHREAD_MUTEX_INITIALIZER,
	.hold = PTHREAD_MUTEX_INITIALIZER
};

static inline void trace(const char* msg, ...)
{
#ifdef TRACE_ENABLE
	va_list args;
	va_start( args, msg );
		vfprintf(stderr,  msg, args );
	va_end( args);
	fprintf(stderr, "\n");
#endif
}

extern int arcan_tuiint_dirty(struct tui_context* tui);

static ssize_t flush_buffer(int fd, char dst[static 4096])
{
	ssize_t nr = read(fd, dst, 4096);
	if (-1 == nr){
		if (errno == EAGAIN || errno == EINTR)
			return -1;

		atomic_store(&term.alive, false);
		arcan_tui_set_flags(term.screen, TUI_HIDE_CURSOR);

		return -1;
	}
	return nr;
}

static void vte_forward(char* buf, size_t nb)
{
	if (term.pipe)
		fwrite(buf, nb, 1, stdout);
	tsm_vte_input(term.vte, buf, nb);
}

static bool readout_pty(int fd)
{
	char buf[4096];
	bool got_hold = false;
	ssize_t nr = flush_buffer(fd, buf);

	if (nr < 0)
		return false;

	if (0 != pthread_mutex_trylock(&term.synch)){
		pthread_mutex_lock(&term.hold);
		write(term.dirtyfd, &(char){'1'}, 1);
		pthread_mutex_lock(&term.synch);
		got_hold = true;
	}

	vte_forward(buf, nr);

/* could possibly also match against parser state, or specific total
 * timeout before breaking out and releasing the terminal */
	size_t w, h;
	arcan_tui_dimensions(term.screen, &w, &h);
	ssize_t cap = w * h * 4;
	while (nr > 0 && cap > 0 && 1 == poll(
		(struct pollfd[]){ {.fd = fd, .events = POLLIN } }, 1, 0)){
		nr = flush_buffer(fd, buf);
		if (nr > 0){
			vte_forward(buf, nr);
			cap -= nr;
		}
	}

	if (got_hold){
		pthread_mutex_unlock(&term.hold);
	}
	pthread_mutex_unlock(&term.synch);

	return true;
}

void* pump_pty()
{
	int fd = shl_pty_get_fd(term.pty);
	short pollev = POLLIN | POLLERR | POLLNVAL | POLLHUP;

	struct pollfd set[4] = {
		{.fd = fd, .events = pollev},
		{.fd = term.dirtyfd, pollev},
		{.fd = -1, .events = pollev},
		{.fd = -1, .events = POLLIN}
	};

/* with pipe-forward mode we also read from stdin and inject into the pty as
 * well as forward the pty data to stdout */
	if (term.pipe)
		set[3].fd = STDIN_FILENO;

	while (term.alive){
		set[2].fd = tsm_vte_debugfd(term.vte);
		shl_pty_dispatch(term.pty);

		if (-1 == poll(set, 4, 10))
			continue;

		if (term.pipe && set[3].revents){
			char buf[4096];
			size_t nr = fread(buf, 1, 4096, stdin);
			if (nr)
				shl_pty_write(term.pty, buf, nr);
		}

/* tty determines lifecycle */
		if (set[0].revents){
			if (!readout_pty(fd))
				return NULL;
		}

/* just flush out the signal/wakeup descriptor */
		if (set[1].revents){
			char buf[256];
			read(set[1].fd, buf, 256);
		}

		if (set[2].revents){
			tsm_vte_update_debug(term.vte);
		}
	}

	return NULL;
}

static void dump_help()
{
	fprintf(stdout, "Environment variables: \nARCAN_CONNPATH=path_to_server\n"
		"ARCAN_TERMINAL_EXEC=value : run value through /bin/sh -c instead of shell\n"
		"ARCAN_TERMINAL_ARGV : exec will route through execv instead of execvp\n"
		"ARCAN_TERMINAL_PIDFD_OUT : writes exec pid into pidfd\n"
		"ARCAN_TERMINAL_PIDFD_IN  : exec continues on incoming data\n\n"
	  "ARCAN_ARG=packed_args (key1=value:key2:key3=value)\n\n"
		"Accepted packed_args:\n"
		"    key      \t   value   \t   description\n"
		"-------------\t-----------\t-----------------\n"
		" env         \t key=val   \t override default environment (repeatable)\n"
		" chdir       \t dir       \t change working dir before spawning shell\n"
		" bgalpha     \t rv(0..255)\t background opacity (default: 255, opaque)\n"
		" bgc         \t r,g,b     \t background color \n"
		" fgc         \t r,g,b     \t foreground color \n"
		" ci          \t ind,r,g,b \t override palette at index\n"
		" cc          \t r,g,b     \t cursor color\n"
		" cl          \t r,g,b     \t cursor alternate (locked) state color\n"
		" cursor      \t name      \t set cursor (block, frame, halfblock,\n"
		"             \t           \t vline, uline)\n"
		" blink       \t ticks     \t set blink period, 0 to disable (default: 12)\n"
		" login       \t [user]    \t login (optional: user, only works for root)\n"
#ifndef FSRV_TERMINAL_NOEXEC
		" exec        \t cmd       \t allows arcan scripts to run shell commands\n"
#endif
		" keep_alive  \t           \t don't exit if the terminal or shell terminates\n"
		" pipe        \t           \t map stdin-stdout\n"
		" palette     \t name      \t use built-in palette (below)\n"
		" tpack       \t           \t use text-pack (server-side rendering) mode\n"
		" cli         \t           \t switch to non-vt cli/builtin shell mode\n"
		"Built-in palettes:\n"
		"default, solarized, solarized-black, solarized-white, srcery\n"
		"-------------\t-----------\t----------------\n\n"
		"Cli mode (pty-less) specific args:\n"
		"    key      \t   value   \t   description\n"
		"-------------\t-----------\t-----------------\n"
		" env         \t key=val   \t override default environment (repeatable)\n"
		" mode        \t exec_mode \t arcan, wayland, x11, vt100 (default: vt100)\n"
#ifndef FSRV_TERMINAL_NOEXEC
		" oneshot     \t           \t use with exec, shut down after evaluating command\n"
		"-------------\t-----------\t----------------\n"
#endif
	);
}

static void tsm_log(void* data, const char* file, int line,
	const char* func, const char* subs, unsigned int sev,
	const char* fmt, va_list arg)
{
	fprintf(stderr, "[%d] %s:%d - %s, %s()\n", sev, file, line, subs, func);
	vfprintf(stderr, fmt, arg);
}

static void sighuph(int num)
{
	if (term.pty)
		term.pty = (shl_pty_close(term.pty), NULL);
}

static bool on_subwindow(struct tui_context* c,
	arcan_tui_conn* newconn, uint32_t id, uint8_t type, void* tag)
{
	struct tui_cbcfg cbcfg = {};

/* only bind the debug type and bind it to the terminal emulator state machine */
	if (type == TUI_WND_DEBUG){
		char mark = 'a';
		bool ret = tsm_vte_debug(term.vte, newconn, c);
		write(term.signalfd, &mark, 1);
		return ret;
	}
	return false;
}

static void on_mouse_motion(struct tui_context* c,
	bool relative, int x, int y, int modifiers, void* t)
{
	trace("mouse motion(%d:%d, mods:%d, rel: %d",
		x, y, modifiers, (int) relative);

	if (!relative){
		tsm_vte_mouse_motion(term.vte, x, y, modifiers);
	}
}

static void on_mouse_button(struct tui_context* c,
	int last_x, int last_y, int button, bool active, int modifiers, void* t)
{
	trace("mouse button(%d:%d - @%d,%d (mods: %d)\n",
		button, (int)active, last_x, last_y, modifiers);
	tsm_vte_mouse_button(term.vte, button, active, modifiers);
}

static void on_key(struct tui_context* c, uint32_t keysym,
	uint8_t scancode, uint8_t mods, uint16_t subid, void* t)
{
	trace("on_key(%"PRIu32",%"PRIu8",%"PRIu16")", keysym, scancode, subid);
	tsm_vte_handle_keyboard(term.vte,
		keysym, isascii(keysym) ? keysym : 0, mods, subid);
}

static bool on_u8(struct tui_context* c, const char* u8, size_t len, void* t)
{
	uint8_t buf[5] = {0};
	trace("utf8-input: %s", u8);
	memcpy(buf, u8, len >= 5 ? 4 : len);

	int fd = shl_pty_get_fd(term.pty);
	int rv = write(fd, u8, len);

	if (rv < 0){
		atomic_store(&term.alive, false);
		arcan_tui_set_flags(c, TUI_HIDE_CURSOR);
	}

	return true;
}

static void on_utf8_paste(struct tui_context* c,
	const uint8_t* str, size_t len, bool cont, void* t)
{
	trace("utf8-paste(%s):%d", str, (int) cont);
	tsm_vte_paste(term.vte, (char*)str, len);
}

static unsigned long long last_frame;

static void on_resize(struct tui_context* c,
	size_t neww, size_t newh, size_t col, size_t row, void* t)
{
	trace("resize(%zu(%zu),%zu(%zu))", neww, col, newh, row);
	if (term.pty)
		shl_pty_resize(term.pty, col, row);
	last_frame = 0;
}

static void write_callback(struct tsm_vte* vte,
	const char* u8, size_t len, void* data)
{
	shl_pty_write(term.pty, u8, len);
}

static void str_callback(struct tsm_vte* vte, enum tsm_vte_group group,
	const char* msg, size_t len, bool crop, void* data)
{
/* parse and see if we should set title */
	if (!msg || len < 3 || crop){
		debug_log(vte,
			"bad OSC sequence, len = %zu (%s)\n", len, msg ? msg : "");
		return;
	}

/* 0, 1, 2 : set title */
	if ((msg[0] == '0' || msg[0] == '1' || msg[0] == '2') && msg[1] == ';'){
		arcan_tui_ident(term.screen, &msg[2]);
		return;
	}

	debug_log(vte,
		"%d:unhandled OSC command (PS: %d), len: %zu\n",
		vte->log_ctr++, (int)msg[0], len
	);

/* 4 : change color */
/* 5 : special color */
/* 52 : clipboard contents */
}

static char* get_shellenv()
{
	char* shell = getenv("SHELL");

	if (!getenv("PATH"))
		setenv("PATH", "/usr/local/bin:/bin:/usr/bin:/usr/local/sbin:/usr/sbin:/sbin", 1);

	const struct passwd* pass = getpwuid( getuid() );
	if (pass){
		setenv("LOGNAME", pass->pw_name, 1);
		setenv("USER", pass->pw_name, 1);
		setenv("SHELL", pass->pw_shell, 0);
		setenv("HOME", pass->pw_dir, 0);
		shell = pass->pw_shell;
	}

	/* some safe default should it be needed */
	if (!shell)
		shell = "/bin/sh";

/* will be exec:ed so don't worry to much about leak or mgmt */
	return shell;
}

static char* group_expand(struct group_ent* group, const char* in)
{
	return strdup(in);
}

static char** build_argv(char* appname, char* instr)
{
	struct group_ent groups[] = {
		{.enter = '"', .leave = '"', .expand = group_expand},
		{.enter = '\0', .leave = '\0', .expand = NULL}
	};

	struct argv_parse_opt opts = {
		.prepad = 1,
		.groups = groups,
		.sep = ' '
	};

	ssize_t err_ofs = -1;
	char** res = extract_argv(instr, opts, &err_ofs);
	if (res)
		res[0] = appname;

	return res;
}

static void setup_shell(struct arg_arr* argarr, char* const args[])
{
	static const char* unset[] = {
		"COLUMNS", "LINES", "TERMCAP",
		"ARCAN_ARG", "ARCAN_APPLPATH", "ARCAN_APPLTEMPPATH",
		"ARCAN_FRAMESERVER_LOGDIR", "ARCAN_RESOURCEPATH",
		"ARCAN_SHMKEY", "ARCAN_SOCKIN_FD", "ARCAN_STATEPATH"
	};

	int ind = 0;
	const char* val;

	for (int i=0; i < sizeof(unset)/sizeof(unset[0]); i++)
		unsetenv(unset[i]);

/* set some of the common UTF-8 default envs, shell overrides if needed */
	setenv("LANG", "en_GB.UTF-8", 0);
	setenv("LC_CTYPE", "en_GB.UTF-8", 0);

/* FIXME: check what we should do with PWD, SHELL, TMPDIR, TERM, TZ,
 * DATEMSK, LINES, LOGNAME(portable set), MSGVERB, PATH */

/* might get overridden with putenv below, or if we are exec:ing /bin/login */
#ifdef __OpenBSD__
	setenv("TERM", "wsvt25", 1);
#else
	setenv("TERM", "xterm-256color", 1);
#endif

	while (arg_lookup(argarr, "env", ind++, &val))
		putenv(strdup(val));

	if (arg_lookup(argarr, "chdir", 0, &val)){
		chdir(val);
	}

#ifndef NSIG
#define NSIG 32
#endif

/* so many different contexts and handover methods needed here and not really a
 * clean 'ok we can get away with only doing this', the arcan-launch setups
 * need argument passing in env, the afsrv_cli need re-exec with argv in argv,
 * and some specialized features like debug handover may need both */
	char* exec_arg = getenv("ARCAN_TERMINAL_EXEC");

#ifdef FSRV_TERMINAL_NOEXEC
	if (arg_lookup(argarr, "exec", 0, &val)){
		LOG("permission denied, noexec compiled in");
	}
#else
	if (arg_lookup(argarr, "exec", 0, &val)){
		exec_arg = strdup(val);
	}
#endif

	sigset_t sigset;
	sigemptyset(&sigset);
	pthread_sigmask(SIG_SETMASK, &sigset, NULL);

	for (size_t i = 1; i < NSIG; i++)
		signal(i, SIG_DFL);

/* special case, ARCAN_TERMINAL_EXEC skips the normal shell setup */
	if (exec_arg){
		char* inarg = getenv("ARCAN_TERMINAL_ARGV");
		char* args[] = {"/bin/sh", "-c" , exec_arg, NULL};

		const char* pidfd_in = getenv("ARCAN_TERMINAL_PIDFD_IN");
		const char* pidfd_out = getenv("ARCAN_TERMINAL_PIDFD_OUT");

/* forward our new child pid to the _out fd, and then blockread garbage */
		if (pidfd_in && pidfd_out){
			int infd = strtol(pidfd_in, NULL, 10);
			int outfd = strtol(pidfd_out, NULL, 10);
			pid_t pid = getpid();
			write(outfd, &pid, sizeof(pid));
			read(infd, &pid, 1);
			close(infd);
			close(outfd);
		}

/* inherit some environment, filter the things we used */
		unsetenv("ARCAN_TERMINAL_EXEC");
		unsetenv("ARCAN_TERMINAL_PIDFD_IN");
		unsetenv("ARCAN_TERMINAL_PIDFD_OUT");
		unsetenv("ARCAN_TERMINAL_ARGV");

/* two different forms of this, one uses the /bin/sh -c route with all the
 * arguments in the packed exec string, the other splits into a binary and
 * an argument, the latter matters */
		if (inarg)
			execvp(exec_arg, build_argv(exec_arg, inarg));
		else
			execv("/bin/sh", args);

		exit(EXIT_FAILURE);
	}

	execvp(args[0], args);
	exit(EXIT_FAILURE);
}

static bool on_subst(struct tui_context* tui,
	struct tui_cell* cells, size_t n_cells, size_t row, void* t)
{
	bool res = false;
	for (size_t i = 0; i < n_cells-1; i++){
/* far from an optimal shaping rule, but check for special forms of continuity,
 * 3+ of (+_-) like shapes horizontal or vertical, n- runs of whitespace or
 * vertical similarities in terms of whitespace+character
 */
		if ( (isspace(cells[i].ch) && isspace(cells[i+1].ch)) ){
			cells[i].attr.aflags |= TUI_ATTR_SHAPE_BREAK;
			res = true;
		}
	}

	return res;
}

static void on_exec_state(struct tui_context* tui, int state, void* tag)
{
	if (state == 0)
		shl_pty_signal(term.pty, SIGCONT);
	else if (state == 1)
		shl_pty_signal(term.pty, SIGSTOP);
	else if (state == 2)
		shl_pty_signal(term.pty, SIGHUP);
}

static bool setup_build_term()
{
	size_t rows = 0, cols = 0;
	arcan_tui_dimensions(term.screen, &rows, &cols);
	term.complete_signal = false;

	term.child = shl_pty_open(&term.pty, NULL, NULL, cols, rows);
	if (term.child < 0){
		arcan_tui_destroy(term.screen, "Shell process died unexpectedly");
		return false;
	}

/*
 * and lastly, spawn the pseudo-terminal
 */
/* we're inside child */
	if (term.child == 0){
		const char* val;
		char* argv[] = {get_shellenv(), "-i", NULL, NULL};

		if (arg_lookup(term.args, "cmd", 0, &val) && val){
			argv[2] = strdup(val);
		}

/* special case handling for "login", this requires root */
		if (arg_lookup(term.args, "login", 0, &val)){
			struct stat buf;
			argv[1] = "-p";
			if (stat("/bin/login", &buf) == 0 && S_ISREG(buf.st_mode))
				argv[0] = "/bin/login";
			else if (stat("/usr/bin/login", &buf) == 0 && S_ISREG(buf.st_mode))
				argv[0] = "/usr/bin/login";
			else{
				LOG("login prompt requested but none was found\n");
				return EXIT_FAILURE;
			}
		}

		setup_shell(term.args, argv);
		return EXIT_FAILURE;
	}

/* spawn a thread that deals with feeding the tsm specifically, then we run
 * our normal event look constantly in the normal process / refresh style. */
	pthread_t pth;
	pthread_attr_t pthattr;
	pthread_attr_init(&pthattr);
	pthread_attr_setdetachstate(&pthattr, PTHREAD_CREATE_DETACHED);
	atomic_store(&term.alive, true);

	if (-1 == pthread_create(&pth, &pthattr, pump_pty, NULL)){
		atomic_store(&term.alive, false);
	}

	return true;
}

static void on_reset(struct tui_context* tui, int state, void* tag)
{
/* this state needs to be verified against pledge etc. as well since some
 * of the foreplay might become impossible after privsep */

	switch (state){
/* soft, just state machine + tui */
	case 0:
		arcan_tui_reset(tui);
		tsm_vte_hard_reset(term.vte);
	break;

/* hard, try to re-execute command, send HUP if still alive then mark as dead */
	case 1:
		arcan_tui_reset(tui);
		tsm_vte_hard_reset(term.vte);
		if (atomic_load(&term.alive)){
			on_exec_state(tui, 2, tag);
			atomic_store(&term.alive, false);
		}

		if (!term.die_on_term){
			arcan_tui_progress(term.screen, TUI_PROGRESS_INTERNAL, 0.0);
		}
		setup_build_term();
	break;

/* crash, ... ? do nothing */
	default:
	break;
	}

/* reset vte state */
}

static int parse_color(const char* inv, uint8_t outv[4])
{
	return sscanf(inv, "%"SCNu8",%"SCNu8",%"SCNu8",%"SCNu8,
		&outv[0], &outv[1], &outv[2], &outv[3]);
}

int afsrv_terminal(struct arcan_shmif_cont* con, struct arg_arr* args)
{
	if (!con)
		return EXIT_FAILURE;

	if (arg_lookup(args, "pipe", 0, NULL)){
		term.pipe = true;
		setvbuf(stdout, NULL, _IONBF, 0);
		setvbuf(stdin, NULL, _IONBF, 0);
	}

/*
 * this is the first migration part we have out of the normal vt- legacy,
 * see cli.c
 */
	if (arg_lookup(args, "cli", 0, NULL)){
		return arcterm_cli_run(con, args);
	}

	const char* val;
	if (arg_lookup(args, "help", 0, &val)){
		dump_help();
		return EXIT_SUCCESS;
	}

/*
 * since it has not received enough testing yet, 'TPACK' mode where server-side
 * text-rendering is not the default - but can be enabled by setting the argument
 * here.
 */
	if (arg_lookup(args, "tpack", 0, NULL)){
		setenv("TUI_RPACK", "1", true);
	}

/*
 * this table act as both callback- entry points and a list of features that we
 * actually use. So binary chunk transfers, video/audio paste, geohint etc.
 * are all ignored and disabled
 */
	struct tui_cbcfg cbcfg = {
		.input_mouse_motion = on_mouse_motion,
		.input_mouse_button = on_mouse_button,
		.input_utf8 = on_u8,
		.input_key = on_key,
		.utf8 = on_utf8_paste,
		.resized = on_resize,
		.subwindow = on_subwindow,
		.exec_state = on_exec_state,
		.reset = on_reset
/*
 * for advanced rendering, but not that interesting
 * .substitute = on_subst
 */
	};

	term.screen = arcan_tui_setup(con, NULL, &cbcfg, sizeof(cbcfg));

	if (!term.screen){
		fprintf(stderr, "failed to setup TUI connection\n");
		return EXIT_FAILURE;
	}
	arcan_tui_reset_flags(term.screen, TUI_ALTERNATE);
	arcan_tui_refresh(term.screen);
	term.args = args;

/*
 * now we have the display server connection and the abstract screen,
 * configure the terminal state machine
 */
	if (tsm_vte_new(&term.vte, term.screen, write_callback, NULL) < 0){
		arcan_tui_destroy(term.screen, "Couldn't setup terminal emulator");
		return EXIT_FAILURE;
	}

/*
 * allow the window state to survive, terminal won't be updated but
 * other tui behaviors are still valid
 */
	if (arg_lookup(args, "keep_alive", 0, NULL)){
		term.die_on_term = false;
		arcan_tui_progress(term.screen, TUI_PROGRESS_INTERNAL, 0.0);
	}

/*
 * forward the colors defined in tui (where we only really track
 * forground and background, though tui should have a defined palette
 * for the normal groups when the other bits are in place
 */
	if (arg_lookup(args, "palette", 0, &val)){
		tsm_vte_set_palette(term.vte, val);
	}

	int ind = 0;
	uint8_t ccol[4];
	while(arg_lookup(args, "ci", ind++, &val)){
		if (4 == parse_color(val, ccol))
			tsm_vte_set_color(term.vte, ccol[0], &ccol[1]);
	}
	tsm_set_strhandler(term.vte, str_callback, 256, NULL);

	signal(SIGHUP, sighuph);

	uint8_t fgc[3], bgc[3];
	tsm_vte_get_color(term.vte, VTE_COLOR_BACKGROUND, bgc);
	tsm_vte_get_color(term.vte, VTE_COLOR_FOREGROUND, fgc);
	arcan_tui_set_color(term.screen, TUI_COL_BG, bgc);
	arcan_tui_set_color(term.screen, TUI_COL_TEXT, fgc);

/* socket pair used to signal between the threads, this will be kept
 * alive even between reset/re-execute on a terminated terminal */
	int pair[2];
	if (-1 == socketpair(AF_UNIX, SOCK_STREAM, 0, pair))
		return EXIT_FAILURE;

	term.dirtyfd = pair[0];
	term.signalfd = pair[1];

	if (!setup_build_term())
		return EXIT_FAILURE;

#ifdef __OpenBSD__
	pledge(SHMIF_PLEDGE_PREFIX " tty", NULL);
#endif

	while(atomic_load(&term.alive) || !term.die_on_term){
		pthread_mutex_lock(&term.synch);
		struct tui_process_res res =
			arcan_tui_process(&term.screen, 1, &term.signalfd, 1, -1);

		if (res.errc < TUI_ERRC_OK){
			break;
		}

/* indicate that we are finished so the user has the option to reset rather
 * than terminate, make sure this is done only once per running cycle */
		if (!term.alive && !term.die_on_term && !term.complete_signal){
			arcan_tui_progress(term.screen, TUI_PROGRESS_INTERNAL, 1.0);
			term.complete_signal = true;
		}

		arcan_tui_refresh(term.screen);

	/* flush out the signal pipe, don't care about contents, assume
	 * it is about unlocking for now */
		pthread_mutex_unlock(&term.synch);
		if (res.ok){
			char buf[256];
			read(term.signalfd, buf, 256);
			pthread_mutex_lock(&term.hold);
			pthread_mutex_unlock(&term.hold);
		}
	}

	arcan_tui_destroy(term.screen, NULL);

	return EXIT_SUCCESS;
}
