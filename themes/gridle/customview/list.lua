--
-- simplisting list + icons view
--  

local restbl = {};
restbl.name = "list";

restbl.create = function(self, constr)
	self.clipregion = fill_surface(constr.width, constr.height, 0, 255, 0);
	self.selector   = fill_surface(constr.width, settings.colourtable.font_size + 2, 0, 40, 200);

-- center-pointed used to calculate origo offset
	self.cpx = math.floor(constr.width  * 0.5);
	self.cpy = math.floor(constr.height * 0.5);
	
	move_image(self.clipregion, constr.x, constr.y);
	rotate_image(self.clipregion, constr.ang);
	
-- icon collections etc. for mame and friends.
	local tmp = glob_resource("icons/*.ico", ALL_RESOURCES);
	self.icons = {};
	for ind,val in ipairs(tmp) do
		self.icons[val] = true;
	end

-- use the requested constraints as a clipping region
	link_image(self.selector, self.clipregion);
	image_clip_on(self.selector);
	image_mask_clear(self.selector, MASK_OPACITY);

-- switch to default font if we don't have an override
	self.constr = constr;
	if not (self.constr.font_size and self.constr.font) then
		self.constr.font = settings.colourtable.font;
		self.constr.font_size = settings.colourtable.font_size;
	end

	blend_image(self.clipregion, 0.5);
	show_image(self.selector);
	return nil;
end

restbl.escape = function(self) return true; end
restbl.up     = function(self, step) restbl:step(-1 * step); end
restbl.down   = function(self, step) restbl:step(step); end
restbl.left   = function(self, step) restbl:step(self.page_size * -1 * step); end
restbl.right  = function(self, step) restbl:step(self.page_size * step); end
restbl.current_item = function(self)
	return self.list[self.cursor];
end

restbl.move_cursor = function(self)
	local page_beg, page_ofs, page_end = self:curpage();

	instant_image_transform(self.selector);
	move_image(self.selector, 0, self.menu_lines[page_ofs], 10);
end

restbl.select_random = function(self, fv)
	self.cursor = math.random(1, #data.games);
	self:redraw();
end

restbl.get_linestr = function(self, gametbl)
	local res = gametbl.title;
	local fs = tostring(settings.colourtable.font_size);
	
	if self.icons[gametbl.setname .. ".ico"] then
		res = "\\P" .. fs .. "," .. fs ..",icons/" .. gametbl.setname .. ".ico," .. res;
	elseif self.icons[gametbl.target .. ".ico"] then
		res = "\\P" .. fs .. "," .. fs ..",icons/" .. gametbl.target .. ".ico," .. res;
	end

	return res;	
end

restbl.redraw = function(self)
	if (valid_vid(self.menu)) then
		delete_image(self.menu);
	end
	
	local page_beg, page_ofs, page_end = self:curpage(); 
	local renderstr = settings.colourtable.data_fontstr;

-- self.linestr is responsible for padding with icons etc.
	for ind = page_beg, page_end do
		renderstr = renderstr .. self:get_linestr(self.list[ind]) .. [[\n\r]];
	end

	local menu, lines = render_text( renderstr, 2 );
	self.menu = menu;
	self.menu_lines = lines;
	
	local props = image_surface_properties(menu);
	delete_image(menu);
	menu = fill_surface(props.width, props.height, 255, 0, 0);
	self.menu = menu;
	local pcx = props.width  * 0.5;
	local pcy = props.height * 0.5;
	local dpx = pcx - self.cpx;
	local dpy = pcy - self.cpy;
	image_origo_offset(menu, dpx, dpy, 0);

	link_image(self.menu, self.clipregion);
	image_mask_clear(self.menu, MASK_OPACITY);
--	image_clip_on(self.menu);

	order_image(self.menu, max_current_image_order());
	blend_image(self.menu, 0.5);

	self:move_cursor();
	return nil;
end

restbl.drawable = function(self) return self.menu; end

restbl.calc_page = function(self, number, size, limit)
	local page_start = math.floor( (number - 1) / size) * size;
	local offset     = (number - 1) % size;
	local page_end   = page_start + size;
	
	if (page_end > limit) then
		page_end = limit;
	end

	return page_start + 1, offset + 1, page_end;
end

restbl.curpage = function(self)
	return self:calc_page(self.cursor, self.page_size, #self.list);
end

restbl.step = function(self, stepv)
	local curpg, ign, ign2 = self:curpage();

	local ngn = self.cursor + stepv;
	ngn = ngn < 1 and #self.list or ngn;
	ngn = ngn > #self.list and 1 or ngn;

	self.cursor = ngn;
	local newpg, ign, ign2 = self:curpage();

	if (newpg ~= curpg) then
		self:redraw();	
	else
		self:move_cursor();
	end
end

restbl.update_list = function(self, gamelist)
	print("update list", #gamelist);
	self.list   = gamelist;
	self.cursor = 1;
	self.page_size = math.floor( self.constr.height / ( self.constr.font_size + 4 ));
	self:redraw();
end

restbl.trigger_selected = function(self) return self.list[ self.cursor ]; end

return restbl;
