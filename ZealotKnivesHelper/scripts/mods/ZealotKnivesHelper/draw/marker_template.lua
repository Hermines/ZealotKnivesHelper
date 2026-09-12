--[[
	Dot crosshair world_marker template (game side)

	Once registered into HudElementWorldMarkers, projection/frustum culling/screen
	clamping/distance scaling are all handled by the engine's world
	marker system.

	This module only provides:
	  - the widget definition (dot texture, with default_size for the engine's
	    _apply_scale scaling)
	  - update_function: writes color/size/visibility into the style every frame
	    (alpha = base color alpha x opacity x stack fade x visibility, with a write
	    threshold)

Note: the engine clones the template per marker, so the engine-side fields
(max_distance/scale_settings) are refreshed onto each clone by
marker_sync during sync; this table only seeds new markers.
]]

local mod = get_mod("ZealotKnivesHelper")

local UIWidget = require("scripts/managers/ui/ui_widget")

-- Same material as the game's default crosshair center dot (always loaded, no
-- extra package needed)
local DOT_MATERIAL = "content/ui/materials/hud/crosshairs/center_dot"
local DEFAULT_DOT_SIZE = 6

-- Alpha write threshold (on a 0-255 scale, about 0.02) to avoid ineffective style writes
local ALPHA_WRITE_THRESHOLD = 5

local template = {
	name = "zealot_knives_helper_dot",
	screen_clamp = false,
	check_line_of_sight = false,
}

template.create_widget_defintion = function(template, scenegraph_id)
	local definition = UIWidget.create_definition({
		{
			pass_type = "texture",
			style_id = "dot",
			value = DOT_MATERIAL,
			style = {
				horizontal_alignment = "center",
				vertical_alignment = "center",
				offset = { 0, 0, 10 },
				size = { DEFAULT_DOT_SIZE, DEFAULT_DOT_SIZE },
				color = { 255, 255, 80, 80 },
			},
		},
	}, scenegraph_id)

	local dot_style = definition.style and definition.style.dot

	if dot_style then
		-- The engine's _apply_scale uses default_size for distance scaling
		dot_style.default_size = { DEFAULT_DOT_SIZE, DEFAULT_DOT_SIZE }
	end

	return definition
end

template.on_enter = function(widget, marker, template)
	return
end

template.update_function = function(parent, ui_renderer, widget, marker, template, dt, t)
	local data = marker.data
	local style = widget.style and widget.style.dot

	if not data or not style then
		return
	end

	local settings = mod.indicator_settings or {}
	local size = data.size or settings.dot_size or DEFAULT_DOT_SIZE

	-- Size: default_size is used by the engine for distance scaling; without scaling,
	-- write size directly
	if style.default_size then
		style.default_size[1] = size
		style.default_size[2] = size
	end

	if not template.scale_settings and style.size then
		style.size[1] = size
		style.size[2] = size
	end

	-- Color = breed/category color, alpha = base alpha x global opacity x stack fade x visibility
	local color = data.color

	if color and style.color then
		local opacity = settings.dot_opacity or 1
		local stack_alpha = data.stack_alpha or 1
		local visibility = data.visible == false and 0 or 1
		local alpha = color[1] * opacity * stack_alpha * visibility
		local current = style.color[1]

		if math.abs(current - alpha) >= ALPHA_WRITE_THRESHOLD then
			style.color[1] = alpha
		end

		-- RGB channels (breed/category color)
		if style.color[2] ~= color[2] then
			style.color[2] = color[2]
		end

		if style.color[3] ~= color[3] then
			style.color[3] = color[3]
		end

		if style.color[4] ~= color[4] then
			style.color[4] = color[4]
		end
	end
end

return template
