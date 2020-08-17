--
-- pseudo-window manager helper script for working with wayland and
-- x-wayland clients specifically.
--
-- Returns a factory function for taking a wayland-bridge carrying a
-- single client and constructing a wm/state tracker - as well as an
-- optional connection manager that takes any primary connection that
-- identifies as 'bridge-wayland' and deals with both 1:1 and 1:*
-- cases.
--
-- local factory, connection = system_load("builtin/wayland.lua")()
-- factory(vid, segreq_table, config)
--
-- (manual mode from a handler to an established bridge-wayland):
--     if status.kind == "segment-request" then
--          wm = factory(vid, status, config)
--     end
--
-- (connection mode):
-- 	local vid = target_alloc("wayland_only", function() end)
--
-- 	connection(vid,
-- 	function(source, status)
--  	wm = factory(source, status, config)
-- 	end)
--
--  a full example can be found in tests/interactive/wltest
--
-- config contains display options and possible wm event hooks for
-- latching into an outer wm scheme.
--
-- possible methods in config table:
--
--  decorate(window, vid, width, height) => t, l, d, r:
--      attach / set decorations using vid as anchor and width/height.
--      called whenever decoration state/sizes change. If 'vid' is not
--      provided, it means existing decorations should be destroyed.
--
--      the decorator should return the number of pixels added in each
--      direction for maximize/fullscreen calculations to be correct.
--
--  destroy(window):
--      called when a window has been destroyed, just before video
--      resources are deleted.
--
--  focus(window) or focus():
--      called when a window requests focus, to acknowledge, call
--      wnd:focus() and wnd:unfocus() respectively.
--
--  move(window, x, y, dx, dy):
--      called when a window requests to be moved to x, y, return
--      x, y if permitted - or constrain coordinates and return new
--      position
--
--  configure(window, [type]):
--      request for an initial size for a toplevel window (if any)
--
--  mapped(window):
--      called when a new toplevel window is ready to be drawn
--
--  log : function(domain, message) (default: print)
--  fmt : function(string, va_args) (default: string.format)
--
--  the 'window' table passed as arguments provides the following methods:
--
--     focus(self):
--         acknowledge a focus request, raise and change pending visuals
--
--     maximize(self):
--         acknowledge a maximization request
--
--     minimize(self):
--         acknowledge a minimization request
--
--     fullscreen(self):
--         acknowledge a fullscreen request or force fullscreen
--
--     destroy(self):
--         kill window and associated resources
--
-- the returned 'wm' table exposes the following methods:
--
--  destroy():
--      drop all resources tied to this client
--
--  resize(width, height, density):
--      change the 'output' for this client, roughly equivalent to outmost
--      window resizing, changing display or display resolution - density
--      in ppcm.
--
local x11_lut =
{
	["type"] =
	function(ctx, source, typename)
		ctx.states.typed = typename
		if ctx.states.mapped then
			ctx:apply_type()
		end
	end,
	["pair"] =
	function(ctx, source, wl_id, x11_id)
		wl_id = wl_id and wl_id or "missing"
		x11_id = x11_id and x11_id or "missing"

		ctx.wm.log("wl_x11", ctx.wm.fmt("paired:wl=%s:x11=%s", wl_id, x11_id))
-- not much to do with the information
	end,
	["fullscreen"] =
	function(ctx, source, on)
		ctx.wm.state_change(ctx, "fullscreen")
	end,
}

-- this table contains hacks around some bits in wayland that does not map to
-- regular events in shmif and comes packed in 'message' events
local wl_top_lut =
{
	["move"] =
	function(ctx)
		ctx.states.moving = true
	end,
	["maximize"] =
	function(ctx)
		ctx.wm.state_change(ctx, "maximize")
	end,
	["demaximize"] =
	function(ctx)
		ctx.wm.state_change(ctx)
	end,
	["menu"] =
	function(ctx)
		ctx.wm.context_menu(ctx)
	end,
	["fullscreen"] =
	function(ctx, source, on)
		ctx.wm.state_change(ctx, "fullscreen")
	end,
	["resize"] =
	function(ctx, source, dx, dy)
		if not dx or not dy then
			return
		end

		dx = tonumber(dx)
		dy = tonumber(dy)

		if not dx or not dy then
			ctx.states.resizing = false
			return
		end

-- masks for moving, used on left,top
		local mx = 0
		local my = 0
		if dx < 0 then
			mx = 1
		end
		if dy < 0 then
			my = 1
		end

		ctx.states.resizing = {dx, dy, mx, my}
	end,
-- practically speaking there is really only xdg now, though if someone
-- adds more, any wm specific mapping should be added here
	["shell"] =
	function(ctx, shell_type)
	end,
	["scale"] =
	function(ctx, sf)
	end,
-- new window geometry
	["geom"] =
	function(ctx, x, y, w, h)
	end
}

local function wnd_input_table(wnd, iotbl)
	if not wnd.states.focused then
		return
	end

	target_input(wnd.vid, iotbl)
end

-- these just request the focus state to change, the wm has final say
local function wnd_mouse_over(wnd)
	if wnd.wm.cfg.mouse_focus and not wnd.states.focused then
		wnd.wm.focus(wnd)
	end
end

-- this is not sufficient when we have a popup grab surface as 'out'
-- may mean in on the popup
local function wnd_mouse_out(wnd)
	if wnd.wm.cfg.mouse_focus and wnd.states.focused then
		wnd.wm.focus()
	end
end

local function wnd_mouse_btn(wnd, vid, button, active, x, y)
	if not active then
		wnd.states.moving = false
		wnd.states.resizing = false

	elseif not wnd.states.focused then
		wnd.wm.focus(wnd)
	end

-- catch any popups, this will cause spurious 'release' events in
-- clients if the button mask isn't accounted for
	if wnd.dismiss_chain then
		if active then
			wnd.block_release = button
			wnd:dismiss_chain()
		end
		return
	end

-- block until focus is ack:ed
	if not wnd.states.focused then
		return
	end

	if wnd.block_release == button and not active then
		wnd.block_release = nil
		return
	end

	target_input(vid, {
		kind = "digital",
		mouse = true,
		devid = 0,
		subid = button,
		active = active,
	})
end

local function wnd_mouse_drop(wnd)
	wnd:drag_resize()
end

local function wnd_mouse_motion(wnd, vid, x, y, rx, ry)
	local tx = x - wnd.x
	local ty = y - wnd.y

	target_input(wnd.vid, {
		kind = "analog", mouse = true,
		devid = 0, subid = 0,
		samples = {tx, rx}
	})

	target_input(wnd.vid, {
		kind = "analog", mouse = true,
		devid = 0, subid = 1,
		samples = {ty, ry}
	})
end

local function wnd_mouse_drag(wnd, vid, dx, dy)
-- also need to cover 'cursor-tagging' hint here for drag and drop

	if wnd.states.moving then
		local x, y = wnd.wm.move(wnd, wnd.x + dx, wnd.y + dy, dx, dy)
		wnd.x = x
		wnd.y = y

-- for x11 we also need to message the new position
-- target_input(wnd.external, string.format("kind=move:x=%d:y=%d", rx, ry));
		move_image(wnd.vid, wnd.x, wnd.y)
		return

--w when this is set, the resizing[] mask is also set
	elseif wnd.states.resizing then
		wnd:drag_resize(dx, dy)

-- need to clamp to something
		if wnd.in_resize[1] < 32 then
			wnd.in_resize[1] = 32
		end

		if wnd.in_resize[2] < 32 then
			wnd.in_resize[2] = 32
		end

		target_displayhint(wnd.vid, wnd.in_resize[1], wnd.in_resize[2])

-- re-emit as motion
	else
		local mx, my = mouse_xy()
		wnd_mouse_motion(wnd, vid, mx, my)
	end
end

local function wnd_hint_state(wnd)
	local mask = 0
	if not wnd.states.focused then
		mask = bit.bor(mask, TD_HINT_UNFOCUSED)
	end

	if not wnd.states.visible then
		mask = bit.bor(mask, TD_HINT_INVISIBLE)
	end

	if wnd.states.maximized then
		mask = bit.bor(mask, TD_HINT_MAXIMIZED)
	end

	if wnd.states.fullscreen then
		mask = bit.bor(mask, TD_HINT_FULLSCREEN)
	end

	return mask
end

local function wnd_unfocus(wnd)
	wnd.wm.log(wnd.name, "focus=off")
	wnd.states.focused = false
	target_displayhint(wnd.vid, 0, 0, wnd_hint_state(wnd))
	wnd.wm.custom_cursor = false
	mouse_switch_cursor("default")
end

local function wnd_focus(wnd)
	wnd.wm.log(wnd.name, "focus=on")
	wnd.states.focused = true
	target_displayhint(wnd.vid, 0, 0, wnd_hint_state(wnd))
	wnd.wm.custom_cursor = wnd
	table.remove_match(wnd.wm.window_stack, wnd)
	table.insert(wnd.wm.window_stack, wnd)

-- re-order
	for i,v in ipairs(wnd.wm.window_stack) do
		order_image(v.vid, i * 10);
	end
end

local function wnd_destroy(wnd)
	wnd.wm.log(wnd.name, "destroy")
	mouse_droplistener(wnd)
	wnd.wm.windows[wnd.cookie] = nil
	table.remove_match(wnd.wm.window_stack, wnd)

	if wnd.wm.custom_cursor == wnd then
		mouse_switch_cursor("default")
	end
	if wnd.wm.cfg.destroy then
		wnd.wm.cfg.destroy(wnd)
	end
	if valid_vid(wnd.vid) then
		delete_image(wnd.vid)
	end
end

local function wnd_fullscreen(wnd)
	if wnd.states.fullscreen then
		return
	end

	wnd.states.fullscreen = {wnd.w, wnd.h, wnd.x, wnd.y}
	wnd.defer_move = {0, 0}
	target_displayhint(wnd.vid,
		wnd.wm.disptbl.width, wnd.wm.disptbl.height, wnd_hint_state(wnd))
end

local function wnd_maximize(wnd, w, h)
	if wnd.states.maximized then
		return
	end

-- drop fullscreen if we have it, but block hint
	if wnd.states.fullscreen then
		wnd:revert({no_hint = true})
	end

	wnd.states.maximized = {wnd.w, wnd.h, wnd.x, wnd.y}
	wnd.defer_move = {0, 0}

	target_displayhint(wnd.vid,
		wnd.wm.disptbl.width, wnd.wm.disptbl.height, wnd_hint_state(wnd))
end

local function wnd_revert(wnd, opts)
	local tbl

-- drop fullscreen to maximized or 'normal' (the attributes stack)
	if wnd.states.fullscreen then
		tbl = wnd.states.fullscreen
		wnd.states.fullscreen = false

	elseif wnd.states.maximized then
		tbl = wnd.states.maximized
		wnd.states.maximized = false
	else
		return
	end

-- the better way of doing this is probably to enable detailed frame
-- reporting for the surface, and have a state hook after this request
-- an edge case is where the maximized dimensions correspond to the
-- unmaximized ones which may be possible if there are no server-side
-- decorations.
	if not opts or not opts.no_hint then
		target_displayhint(wnd.vid, tbl[1], tbl[2], wnd_hint_state(wnd))
		wnd.defer_move = {tbl[3], tbl[4]}
	end

	wnd_hint_state(wnd)
end

local function tl_wnd_resized(wnd, source, status)
	if not wnd.states.mapped then
		wnd.states.mapped = true
		show_image(wnd.vid)
		wnd.wm.mapped(wnd)
	end

-- special handling for drag-resize where we request a move
	local rzmask = wnd.states.resizing
	if rzmask then
		local dw = (wnd.w - status.width)
		local dh = (wnd.h - status.height)
		local dx = dw * rzmask[3]
		local dy = dh * rzmask[4]

		local x, y = wnd.wm.move(wnd, wnd.x + dx, wnd.y + dy, dx, dy)
		wnd.x = x
		wnd.y = y
		move_image(wnd.vid, wnd.x, wnd.y)
		wnd.defer_move = nil
	end

-- special case for state changes (maximized / fullscreen)
	wnd.w = status.width
	wnd.h = status.height
	resize_image(wnd.vid, status.width, status.height)
	wnd.wm.decorate(wnd, wnd.vid, wnd.w, wnd.h)

	if wnd.defer_move then
		local x, y = wnd.wm.move(wnd, wnd.defer_move[1], wnd.defer_move[2])
		move_image(wnd.vid, x, y)
		wnd.x = x
		wnd.y = y
		wnd.defer_move = nil
	end
end

local function self_own(self, vid)
-- if we are matching or a grab exists and we hold the grab
	return self.vid == vid
end

local function x11_wnd_realize(wnd)
	if wnd.realized then
		return
	end

	if not wnd.states.mapped or not wnd.states.typed then
		hide_image(wnd.vid)
		return
	end

	show_image(wnd.vid)
	target_displayhint(wnd.vid, wnd.w, wnd.h)
	mouse_addlistener(wnd, {"motion", "drag", "drop", "button", "over", "out"})
	table.insert(wnd.wm.window_stack, 1, wnd)
	wnd.realized = true
end

local function x11_wnd_type(wnd)
	if
	wnd:realize()
end

local function x11_nudge(wnd, dx, dy)
	local x, y = wnd.wm.move(wnd, wnd.x + dx, wnd.y + dy, dx, dy)
	move_image(wnd.vid, x, y)
	wnd.x = x
	wnd.y = y

end

local function wnd_nudge(wnd, dx, dy)
	local x, y = wnd.wm.move(wnd, wnd.x + dx, wnd.y + dy, dx, dy)
	move_image(wnd.vid, x, y)
	wnd.x = x
	wnd.y = y
end

local function wnd_drag_rz(wnd, dx, dy, mx, my)
	if not dx then
		wnd.states.resizing = false
		wnd.in_resize = nil
		return
	end

	if not wnd.in_resize then
		wnd.in_resize = {wnd.w, wnd.h}
		if (mx and my) then
			wnd.states.resizing = {1, 1, mx, my}
		end
	end
-- apply direction mask, clamp against lower / upper constraints
	local tw = wnd.in_resize[1] + (dx * wnd.states.resizing[1])
	local th = wnd.in_resize[2] + (dy * wnd.states.resizing[2])

	if tw < wnd.min_w then
		tw = wnd.min_w
	end

	if th < wnd.min_h then
		th = wnd.min_h
	end

	if wnd.max_w > 0 and tw > wnd.max_w then
		tw = wnd.max_w
	end

	if wnd.max_h > 0 and tw > wnd.max_h then
		tw = wnd.max_h
	end

	wnd.in_resize = {tw, th}
	target_displayhint(wnd.vid, wnd.in_resize[1], wnd.in_resize[2])
end

-- several special considerations with x11, particularly that some
-- things are positioned based on a global 'root' anchor, a rather
-- involved type model and a number of wm messages that we need to
-- respond to.
--
-- another is that we need to decorate window contents ourselves,
-- with all the jazz that entails.
local function x11_vtable()
	return {
		name = "x11_bridge",
		own = self_own,
		x = 0,
		y = 0,
		w = 32,
		h = 32,
		min_w = 32,
		min_h = 32,
		max_w = 0,
		max_h = 0,

		states = {
			mapped = false,
			typed = false,
			fullscreen = false,
			maximized = false,
			visible = false,
			moving = false,
			resizing = false
		},

-- assumes a basic 'window' then we patch things around when we have
-- been assigned a type / mapped - default is similar to wayland toplevel
-- with added messaging about window coordinates within the space
		destroy = wnd_destroy,
		input_table = wnd_input_table,
		over = wnd_mouse_over,
		out = wnd_mouse_out,
		button = wnd_mouse_btn,
		drag = x11_mouse_dra,
		drop = wnd_mouse_drop,
		focus = wnd_focus,
		unfocus = wnd_unfocus,
		revert = wnd_revert,
		fullscreen = wnd_fullscreen,
		maximize = wnd_maximize,
		drag_resize = wnd_drag_rz,
		nudge = x11_nudge,
		apply_type = x11_wnd_type,
		realize = x11_wnd_realize
	}
end

local function tl_vtable(wm)
	return {
		name = "wl_toplevel",
		wm = wm,

-- states that need to be configurable from the WM and forwarded to the
-- client so that it can update decorations or modify its input response
		states = {
			mapped = false,
			focused = false,
			fullscreen = false,
			maximized = false,
			visible = false,
			moving = false,
			resizing = false
		},

-- wm side calls these to acknowledge state changes
		focus = wnd_focus,
		unfocus = wnd_unfocus,
		maximize = wnd_maximize,
		fullscreen = wnd_fullscreen,
		revert = wnd_revert,
		nudge = wnd_nudge,
		drag_resize = wnd_drag_rz,

-- properties that needs to be tracked for drag-resize/drag-move
		x = 0,
		y = 0,
		w = 0,
		h = 0,
		min_w = 32,
		min_h = 32,
		max_w = 0,
		max_h = 0,

-- keyboard input
		input_table = wnd_input_table,

-- touch-mouse input goes here
		over = wnd_mouse_over,
		out = wnd_mouse_out,
		drag = wnd_mouse_drag,
		drop = wnd_mouse_drop,
		button = wnd_mouse_btn,
		motion = wnd_mouse_motion,
		destroy = wnd_destroy,
		own = self_own
	}
end

local function popup_click(popup, vid, x, y)
	local tbl =
	target_input(vid, {
		kind = "digital",
		mouse = true,
		devid = 0,
		subid = 1,
		active = true,
	})
	target_input(vid, {
		kind = "digital",
		mouse = true,
		devid = 0,
		subid = 1,
		active = false,
	})
end

-- put an invisible surface at the overlay level and add a mouse-handler that
-- calls a destroy function if clicked.
local function setup_grab_surface(popup)
	local vid = null_surface(popup.wm.disptbl.width, popup.wm.disptbl.height)
	show_image(vid)
	order_image(vid, 65530)
	image_tracetag(vid, "popup_grab")
	local tbl = {
		name = "popup_grab_mh",
		own = function(ctx, tgt)
			return vid == tgt
		end,
		click = function()
			popup:destroy()
		end
	}
	mouse_addlistener(tbl, {"click"})

	return function()
		mouse_droplistener(tbl)
		delete_image(vid)
	end
end

local function popup_destroy(popup)
	if popup.grab then
		popup.grab = popup.grab()
	end
	mouse_switch_cursor("default")
	delete_image(popup.vid)
	mouse_droplistener(popup)
	popup.wm.windows[popup.cookie] = nil
end

local function popup_over(popup)
-- this might have changed with mouse_out
	if popup.wm.cursor then
		mouse_custom_cursor(popup.wm.cursor)
	else
		mouse_switch_cursor("default")
	end
end

local function popup_vtable()
	return {
		name = "popup_mh",
		own = self_own,
		motion = wnd_mouse_motion,
		click = popup_click,
		destroy = popup_destroy,
		over = popup_over,
		out = popup_out,
		states = {
		},
		x = 0,
		y = 0
	}
end

local function on_popup(popup, source, status)
	if status.kind == "create" then
		local wnd = popup

-- if we have a popup that has not been assigned to anything when we get
-- the next one already, not entirely 100% whether that is permitted, and
-- more importantly, actually used/sanctioned behaviour
		if valid_vid(wnd.pending_popup) then
			wnd.pending_popup:destroy()
		end

		local popup = popup_vtable()
		local vid, aid, cookie =
		accept_target(
			function(...)
				return on_popup(popup, ...)
			end
		)
		image_tracetag(vid, "wl_popup")

		wnd.known_surfaces[vid] = true
		wnd.pending_popup = popup
		link_image(vid, wnd.anchor)
		popup.wm = wnd
		popup.cookie = cookie
		popup.vid = vid

-- also not entirely sure if popup-drag-n-drop behavior is a thing, so just
-- map clicks and motion for the time being
		mouse_addlistener(popup, {"motion", "click", "over", "out"})

	elseif status.kind == "terminated" then
		popup:destroy()

	elseif status.kind == "resized" then

-- wait with showing the popup until it is both viewported and mapped
		if not popup.states.mapped then
			popup.states.mapped = true
			if popup.got_parent then
				show_image(popup.vid)
			end
		end
		resize_image(popup.vid, status.width, status.height)

	elseif status.kind == "viewport" then
		local pwnd = popup.wm.windows[status.parent]
		if not pwnd then
			popup.wm.log("popup", popup.wm.fmt("bad_parent=%d", status.parent))
			popup.got_parent = false
			hide_image(popup.vid)
			return
		end

		pwnd.popup = popup
		popup.parent = pwnd
		popup.got_parent = true

-- more anchoring and positioning considerations here
		link_image(popup.vid, pwnd.vid)
		move_image(popup.vid, status.rel_x, status.rel_y)

-- 'popups' can be used for tooltips and so on as well, take that into account
-- as well as enable a 'grab' layer that lives with the focused popup
		if status.focus then
			order_image(popup.vid, 65531)
			if not popup.grab then
				popup.grab = setup_grab_surface(popup)
			end
			image_mask_clear(popup.vid, MASK_UNPICKABLE)
		else
-- release any existing grab
			if popup.grab then
				popup.grab = popup.grab()
			end
			order_image(popup.vid, 1)
			image_mask_set(popup.vid, MASK_UNPICKABLE)
		end

-- this needs to be synched if the window is moved through code/wm
		local props = image_surface_resolve(popup.vid)
		popup.x = props.x
		popup.y = props.y

-- possible animation hook
		if popup.states.mapped then
			show_image(popup.vid)
		end

		if popup.wm.pending_popup == popup then
			popup.wm.pending_popup = nil
		end
	end
end

local function on_toplevel(wnd, source, status)
	if status.kind == "create" then
		local new = tl_vtable()
		new.wm = wnd

-- request dimensions from wm
		local w, h = wnd.configure(new, "toplevel")
		local vid, aid, cookie =
		accept_target(w, h,
			function(...)
				return on_toplevel(new, ...)
			end
		)
		new.vid = vid
		new.cookie = cookie
		wnd.known_surfaces[vid] = true
		table.insert(wnd.window_stack, new)

-- tie to bridge as visibility / clipping anchor
		image_tracetag(vid, "wl_toplevel")
		new.vid = vid
		image_inherit_order(vid, true)
		link_image(vid, wnd.anchor)

-- register mouse handler
		mouse_addlistener(new, {"over", "out", "drag", "button", "motion", "drop"})

		return new, cookie

	elseif status.kind == "terminated" then
		wnd:destroy()

-- might need to add frame delivery notification so that we can track/clear
-- parts that have 'double buffered' state

	elseif status.kind == "resized" then
-- first time showing
		tl_wnd_resized(wnd, source, status)

-- viewport is used here to define another window as the current toplevel,
-- i.e. that should cause this window to hide or otherwise be masked, and
-- the parent set to order above it (until unset)
	elseif status.kind == "viewport" then
		wnd.wm.log("wl_toplevel", "viewport incomplete, swap toplevels")

-- wl specific wm hacks
	elseif status.kind == "message" then
		wnd.wm.log("wl_toplevel", wnd.wm.fmt("message=%s", status.message))
		local opts = string.split(status.message, ':')
		if not opts or not opts[1] then
			return
		end

		if
			opts[1] == "shell" and
			opts[2] == "xdg_top" and
			opts[3] and wl_top_lut[opts[3]] then
			wl_top_lut[opts[3]](wnd, source, unpack(opts, 4))
		end
	end
end

local function on_cursor(ctx, source, status)
	if status.kind == "create" then
		local cursor = accept_target(
		function(...)
			return on_cursor(ctx, ...)
		end)

		ctx.cursor.vid = cursor
		link_image(ctx.bridge, cursor)
		ctx.known_surfaces[cursor] = true

	elseif status.kind == "resized" then
		ctx.cursor.width = status.width
		ctx.cursor.height = status.height
		resize_image(ctx.cursor.vid, status.width, status.height)

		if ctx.custom_cursor then
			mouse_custom_cursor(ctx.cursor)
		end

	elseif status.kind == "message" then
-- hot-spot modification?
		if ctx.custom_cursor then
			mouse_custom_cursor(ctx.cursor)
		end

	elseif status.kind == "terminated" then
		delete_image(source)
		ctx.known_surfaces[source] = nil
	end
end

-- fixme: incomplete, input routing, attachments etc. needed
local function on_subsurface(ctx, source, status)
	if status.kind == "create" then
		local subwnd = {
			name = "tl_subsurface"
		}
		local vid, aid, cookie =
		accept_target(
			function(...)
				return on_subsurface(subwnd, ...)
			end
		)
		subwnd.vid = vid
		subwnd.wm = ctx
		subwnd.cookie = cookie

-- subsurfaces need a parent to attach to and 'extend',
-- input should be translated into its coordinate space as well
		return subwnd, cookie
	elseif status.kind == "resized" then

	elseif status.kind == "viewport" then
		link_image(source, parent.vid)

	elseif status.kind == "terminated" then
		delete_image(source)
		ctx.wm.windows[ctx.cookie] = nil
	end
end

local function on_x11(wnd, source, status)
-- most involved here as the meta-WM forwards a lot of information
	if status.kind == "create" then
		local x11 = x11_vtable()

		local vid, aid, cookie =
		accept_target(640, 480,
		function(...)
			return on_x11(x11, ...)
		end)

		wnd.known_surfaces[vid] = true
		move_image(vid, 100, 100)
		show_image(vid)
		x11.wm = wnd
		x11.vid = vid
		x11.cookie = cookie
		image_tracetag(vid, "x11_unknown_type")
		image_inherit_order(vid, true)
		link_image(vid, wnd.anchor)

		return x11, cookie

	elseif status.kind == "resized" then
		tl_wnd_resized(wnd, source, status)
		wnd:realize()

-- let the caller decide how we deal with decoration
		if wnd.realized then
			wnd.wm.decorate(wnd, wnd.vid, wnd.w, wnd.h)
		end

	elseif status.kind == "message" then
		wnd.wm.log("wl_x11", wnd.wm.fmt("message=%s", status.message))
		local opts = string.split(status.message, ':')
		if not opts or not opts[1] or not x11_lut[opts[1]] then
			return
		end
		return x11_lut[opts[1]](wnd, source, unpack(opts, 2))

	elseif status.kind == "registered" then
		wnd.guid = status.guid

	elseif status.kind == "viewport" then
-- special case as it refers to positioning

	elseif status.kind == "terminated" then
		wnd:destroy()
	end
end

local function bridge_handler(ctx, source, status)
	if status.kind == "terminated" then
		ctx:destroy()
		return

	elseif status.kind ~= "segment_request" then
		return
	end

	local permitted = {
		cursor = on_cursor,
		application = on_toplevel,
		popup = on_popup,
		multimedia = on_subsurface, -- fixme: still missing
		["bridge-x11"] = on_x11
	}

	local handler = permitted[status.segkind]
	if not handler then
		warning("unhandled segment type: " .. status.segkind)
		return
	end

-- actual allocation is deferred to the specific handler, some might need to
-- call back into the outer WM to get suggested default size/position - x11
-- clients need world-space coordinates and so on
	local wnd, cookie = handler(ctx, source, {kind = "create"})
	if wnd then
		ctx.windows[cookie] = wnd
	end
end

local function set_rate(ctx, period, delay)
	message_target(ctx.bridge,
		string.format("seat:rate:%d,%d", period, delay))
end

-- first wayland node, limited handler that can only absorb meta info,
-- act as clipboard and allocation proxy
local function set_bridge(ctx, source)
	local w = ctx.cfg.width and ctx.cfg.width or VRESW
	local h = ctx.cfg.width and ctx.cfg.width or VRESH

-- dtbl can be either a compliant monitor table or a render-target
	local dtbl = ctx.cfg.display and ctx.cfg.display or WORLDID
	target_displayhint(source, w, h, 0, dtbl)

-- wl_drm need to be able to authenticate against the GPU, which may
-- have security implications for some people - low risk enough for
-- opt-out rather than in
	if not ctx.cfg.block_gpu then
		target_flags(source, TARGET_ALLOWGPU)
	end

	target_updatehandler(source,
		function(...)
			return bridge_handler(ctx, ...)
		end
	)

	ctx.bridge = source
	ctx.anchor = null_surface(w, h)
	image_tracetag(ctx.anchor, "wl_bridge_anchor")
	show_image(ctx.anchor)
	ctx.mh = {
		name = "wl_bg",
		own = self_own,
		vid = ctx.anchor,
		click = function()
			ctx.focus()
		end,
	}
	mouse_addlistener(ctx.mh, {"click"})

--	ctx:repeat_rate(ctx.cfg.repeat, ctx.cfg.delay)
end

local function resize_output(ctx, neww, newh, density, refresh)
	if density then
		ctx.disptbl.vppcm = density
		ctx.disptbl.hppcm = density
	end

	if refresh then
		ctx.disptbl.refresh = refresh
	end

-- tell all windows that some of their display parameters have changed,
-- if the window is in fullscreen/maximized state - the surface should
-- be resized as well
	for _, v in pairs(ctx.windows) do
-- this will fetch the refreshed display table
		if v.reconfigure then
			if v.states.fullscreen or v.states.maximized then
				v:reconfigure(neww, newh)
			else
				v:reconfigure(v.w, v.h)
			end
		end

	end
end

local function bridge_table(cfg)
	local res = {
-- vid to the client bridge
		control = BADID,

-- key indexed on window identifier cookie
		windows = {},

-- alias of windows in order of focus, used to refocus/reorder
		window_stack = {},

-- tracks all externally allocated VIDs
		known_surfaces = {},

-- currently active cursor on seat
		cursor = {
			vid = BADID,
			hotspot_x = 0,
			hotspot_y = 0,
			width = 1,
			height = 1
		},

-- user table of settings
		cfg = cfg,

-- last known 'output' properties (vppcm, refresh also possible)
		disptbl = {
			width = VRESW,
			height = VRESH,
		},

-- call when output properties have changed
		resize = resize_output,

-- call to update keyboard state knowledge
		repeat_rate = set_rate,

-- swap out for logging / tracing function
		log = print,
		fmt = string.format
	}

-- let client config override some defaults
	if cfg.width then
		res.disptbl.width = cfg.width
	end

	if cfg.height then
		res.disptbl.height = cfg.height
	end

	if cfg.fmt then
		res.fmt = cfg.fmt
	end

	if cfg.log then
		res.log = cfg.log
	end

-- add client defined event handlers, provide default inplementations if missing
	if type(cfg.move) == "function" then
		res.log("wlwm", "override_handler=move")
		res.move = cfg.move
	else
		res.log("wlwm", "default_handler=move")
		res.move =
		function(wnd, x, y, dx, dy)
			return x, y
		end
	end

	if type(cfg.context_menu) == "function" then
		res.log("wlwm", "override_handler=context_menu")
		res.context_menu = cfg.context_menu
	else
		res.context_menu = function()
		end
	end

	if type(cfg.configure) == "function" then
		res.log("wlwm", "override_handler=configure")
		res.configure = cfg.configure
	else
		res.log("wlwm", "default_handler=configure")
		res.configure =
		function()
			return res.disptbl.width * 0.3, res.disptbl.height * 0.3
		end
	end

	if type(cfg.focus) == "function" then
		res.log("wlwm", "override_handler=focus")
		res.focus = cfg.focus
	else
		res.log("wlwm", "default_handler=focus")
		res.focus =
		function()
			return true
		end
	end

	if type(cfg.decorate) == "function" then
		res.log("wlwm", "override_handler=decorate")
		res.decorate = cfg.decorate
	else
		res.log("wlwm", "default_handler=decorate")
		res.decorate =
		function()
		end
	end

	if type(cfg.mapped) == "function" then
		res.log("wlwm", "override_handler=mapped")
		res.mapped = cfg.mapped
	else
		res.log("wlwm", "default_handler=mapped")
		res.mapped =
		function()
		end
	end

	if type(cfg.state_change) == "function" then
		res.log("wlwm", "override_handler=state_change")
		res.state_change = cfg.state_change
	else
		res.state_change =
		function(wnd, state)
			if not state then
				wnd:revert()
			end

		end
	end

	if (cfg.resize_request) == "function" then
		res.log("wlwm", "override_handler=resize_request")
		res.resize_request = cfg.resize_request
	else
		res.log("wlwm", "default_handler=resize_request")
		res.resize_request =
		function(wnd, new_w, new_h)
			if new_w > VRESW then
				new_w = VRESW
			end

			if new_h > VRESH then
				new_h = VRESH
			end

			return new_w, new_h
		end
	end

-- destroy always has a builtin handler and then cfg is optionally pulled in
	res.destroy =
	function()
		local rmlist = {}

-- convert to in-order and destroy all windows first
		for k,v in pairs(res.windows) do
			table.insert(rmlist, v)
		end
		for i,v in ipairs(rmlist) do
			if v.destroy then
				v:destroy()
				if cfg.destroy then
					cfg.destroy(v)
				end
			end
		end

		if cfg.destroy then
			cfg.destroy(res)
		end
		if valid_vid(res.bridge) then
			delete_image(res.bridge)
		end
		if valid_vid(res.anchor) then
			delete_image(res.anchor)
		end

		mouse_droplistener(res)
		local keys = {}
		for k,v in pairs(res) do
			table.insert(keys, v)
		end
		for _,k in ipairs(keys) do
			res[k] = nil
		end
	end

	return res
end

local function client_handler(nested, trigger, source, status)
	if status.kind == "registered" then

		if status.segkind ~= "bridge-wayland" then
			delete_image(source)
			return
		end

-- we have a wayland bridge, and need to know if it is used to bootstrap other
-- clients or not - we see that if it requests a non-bridge-wayland type on its
-- next segment request
	elseif status.kind == "segment_request" then

-- nested, only allow one 'level'
		if status.segkind == "bridge-wayland" then
			if nested then
				return false
			end

-- next one will be the one to ask for 'real' windows
			accept_target(32, 32,
			function(...)
				return client_handler(true, trigger, ...)
			end)

-- and those we just forward to the wayland factory
		else
			trigger(source, status)
		end
	end
end

local function connection_mgmt(source, trigger)
	target_updatehandler(source,
		function(source, status)
			client_handler(false, trigger, source, status)
		end
	)
end

-- factory function is intended to be used when a bridge-wayland segment
-- requests something that is not a bridge-wayland, then the bridge (ref
-- by [vid]) will have its handler overridden and treated as a client.
return
function(vid, segreq, cfg)
	local ctx = bridge_table(cfg)
	set_bridge(ctx, vid)
	bridge_handler(ctx, vid, segreq)
	return ctx
end, connection_mgmt