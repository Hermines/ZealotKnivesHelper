--[[
	DMF settings definitions

	Breed widgets under the boss/elite/specialist categories (show toggle + dot color)
	are generated dynamically from the game's breeds settings.
]]

local mod = get_mod("ZealotKnivesHelper")

local BreedList = mod:io_dofile("ZealotKnivesHelper/scripts/mods/ZealotKnivesHelper/game/breed_list")

-- Category default colors (DMF color format {a, r, g, b}, 0-255)
local CATEGORY_DEFAULT_COLORS = {
	boss = { 255, 255, 70, 70 },
	elite = { 255, 255, 165, 40 },
	special = { 255, 90, 200, 255 },
}

mod.category_default_colors = CATEGORY_DEFAULT_COLORS

--- Build one breed's setting widgets: show toggle (sub-widget: "use custom
--- color" toggle, whose sub-widget is the dot color). DMF shows a checkbox's
--- sub-widgets only while it is checked, so unchecking "use custom color"
--- hides the color picker and makes the dot follow the category color.
local function create_breed_widgets(breed_name, category)
	return {
		setting_id = "breed_show_" .. breed_name,
		type = "checkbox",
		title = breed_name,
		default_value = true,
		sub_widgets = {
			{
				setting_id = "use_custom_color_" .. breed_name,
				type = "checkbox",
				title = "use_custom_color",
				default_value = true,
				sub_widgets = {
					{
						setting_id = "breed_color_" .. breed_name,
						type = "color",
						title = "dot_color",
						default_value = CATEGORY_DEFAULT_COLORS[category],
						has_alpha = false,
					},
				},
			},
		},
	}
end

--- Build one category's setting widget group: show toggle (sub-widgets: dot color + per-breed widgets)
local function create_category_widgets(category)
	local sub_widgets = {
		{
			setting_id = "color_" .. category,
			type = "color",
			title = "dot_color",
			default_value = CATEGORY_DEFAULT_COLORS[category],
			has_alpha = false,
		},
	}

	for _, breed_name in ipairs(BreedList.categories[category]) do
		sub_widgets[#sub_widgets + 1] = create_breed_widgets(breed_name, category)
	end

	return {
		setting_id = "show_" .. category,
		type = "checkbox",
		default_value = true,
		sub_widgets = sub_widgets,
	}
end

local widgets = {
	{
		setting_id = "mod_settings",
		type = "group",
		sub_widgets = {
			{
				setting_id = "toggle_mod",
				type = "checkbox",
				default_value = true,
			},
			{
				setting_id = "debug_mode",
				type = "checkbox",
				default_value = false,
			},
		},
	},
	{
		setting_id = "display_settings",
		type = "group",
		sub_widgets = {
			{
				setting_id = "always_show",
				type = "checkbox",
				default_value = true,
			},
			{
				setting_id = "always_show_key",
				type = "keybind",
				default_value = {},
				keybind_global = false,
				keybind_trigger = "pressed",
				keybind_type = "function_call",
				function_name = "on_always_show_key",
			},
			{
				setting_id = "force_show_key",
				type = "keybind",
				default_value = {},
				keybind_global = false,
				keybind_trigger = "held",
				keybind_type = "function_call",
				function_name = "on_force_show_key",
			},
		},
	},
	{
		setting_id = "indicator_settings",
		type = "group",
		sub_widgets = {
			{
				setting_id = "max_distance",
				type = "numeric",
				default_value = 50,
				range = { 5, 100 },
				unit_text = "meter",
				decimals_number = 0,
			},
			{
				setting_id = "hide_near",
				type = "checkbox",
				default_value = true,
				sub_widgets = {
					{
						setting_id = "hide_near_distance",
						type = "numeric",
						default_value = 10,
						range = { 5, 50 },
						unit_text = "meter",
						decimals_number = 0,
					},
				},
			},
			{
				setting_id = "max_angle",
				type = "numeric",
				default_value = 15,
				range = { 5, 90 },
				unit_text = "degree",
				decimals_number = 0,
			},
			{
				setting_id = "max_dots",
				type = "numeric",
				default_value = 10,
				range = { 1, 10 },
				decimals_number = 0,
			},
			{
				setting_id = "dot_size",
				type = "numeric",
				default_value = 6,
				range = { 2, 16 },
				decimals_number = 0,
			},
			{
				setting_id = "dot_opacity",
				type = "numeric",
				default_value = 1,
				range = { 0, 1 },
				decimals_number = 2,
			},
			{
				setting_id = "scale_by_distance",
				type = "checkbox",
				default_value = false,
			},
			{
				setting_id = "show_lead",
				type = "checkbox",
				default_value = true,
				sub_widgets = {
					{
						setting_id = "lead_multiplier",
						type = "numeric",
						default_value = 100,
						range = { 50, 150 },
						unit_text = "percent",
						decimals_number = 0,
					},
				},
			},
			{
				setting_id = "require_charges",
				type = "checkbox",
				default_value = true,
			},
			{
				setting_id = "visibility_check",
				type = "checkbox",
				default_value = true,
			},
		},
	},
	{
		setting_id = "enemy_settings",
		type = "group",
		sub_widgets = {
			create_category_widgets("boss"),
			create_category_widgets("elite"),
			create_category_widgets("special"),
		},
	},
}

return {
	name         = mod:localize("mod_name"),
	description  = mod:localize("mod_description"),
	is_togglable = true,
	options      = {
		widgets = widgets,
	},
}
