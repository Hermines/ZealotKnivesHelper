--[[
	Localization (en / zh-cn)

	Breed names reuse the game's own display names (Localize(breed_data.display_name)).
]]

local Breed = require("scripts/utilities/breed")
local Breeds = require("scripts/settings/breed/breeds")

local localization = {
	mod_name = {
		en = "Zealot Knives Helper",
		["zh-cn"] = "狂信徒飞刀助手",
	},
	mod_description = {
		en = "Shows extra dot crosshairs indicating where to move your crosshair to hit enemies with Zealot throwing knives (gravity & drag compensated, lead prediction optional)",
		["zh-cn"] = "狂信徒装备飞刀投掷物时，显示额外的点状准星，指示要命中该敌人需要将游戏准星移动到的位置（已补偿重力下坠与空气阻力，可选提前量预测）",
	},

	-- mod_settings
	mod_settings = {
		en = "Mod Settings",
		["zh-cn"] = "模组设置",
	},
	toggle_mod = {
		en = "Enable Mod",
		["zh-cn"] = "启用模组",
	},
	debug_mode = {
		en = "Debug Mode",
		["zh-cn"] = "调试模式",
	},

	-- display_settings
	display_settings = {
		en = "Display Toggle",
		["zh-cn"] = "显示开关",
	},
	always_show = {
		en = "Always Show",
		["zh-cn"] = "始终显示",
	},
	always_show_description = {
		en = "When off, no extra crosshairs are shown. The key below toggles this setting in game.",
		["zh-cn"] = "关闭后不显示额外准星。可用下方绑定的按键在游戏中随时切换本开关。",
	},
	always_show_key = {
		en = "Toggle Key (Press)",
		["zh-cn"] = "切换按键（按下）",
	},
	always_show_key_description = {
		en = "Pressing this key toggles Always Show on/off.",
		["zh-cn"] = "按下后切换“始终显示”的开关。",
	},
	force_show_key = {
		en = "Force Show Key (Hold)",
		["zh-cn"] = "强制显示按键（按住）",
	},
	force_show_key_description = {
		en = "While Always Show is off, holding this key temporarily shows the extra crosshairs; release to hide them again.",
		["zh-cn"] = "在“始终显示”关闭时，按住该按键期间临时显示额外准星，松开后恢复隐藏。",
	},

	-- indicator_settings
	indicator_settings = {
		en = "Indicator Settings",
		["zh-cn"] = "指示器设置",
	},
	max_distance = {
		en = "Max Distance",
		["zh-cn"] = "最大距离",
	},
	-- Tooltip keys: DMF auto-looks up "<setting_id>_description" when a widget has no
	-- explicit tooltip field (DMF options.lua, localize_generic_widget_data)
	max_distance_description = {
		en = "Only enemies within this distance (from you) are indicated.",
		["zh-cn"] = "只指示该距离（与你相距）范围内的敌人。",
	},
	hide_near = {
		en = "Hide Nearby Enemies",
		["zh-cn"] = "近距离不显示",
	},
	hide_near_description = {
		en = "Do not show extra crosshairs for enemies closer than 10 m.",
		["zh-cn"] = "开启后，与你相距小于 10 米的敌人不显示额外准星。",
	},
	max_angle = {
		en = "Max Angle",
		["zh-cn"] = "最大角度",
	},
	max_angle_description = {
		en = "Only enemies within this angle from your crosshair direction are indicated.",
		["zh-cn"] = "只指示与准星方向夹角在该角度以内的敌人。",
	},
	max_dots = {
		en = "Max Dots",
		["zh-cn"] = "最大指示数量",
	},
	max_dots_description = {
		en = "Maximum number of extra crosshairs shown at once. When more enemies qualify, priority is Specialist > Elite > Boss, then nearest.",
		["zh-cn"] = "同时显示的最大额外准星数量。敌人过多时按 专家 > 精英 > Boss、再按距离由近到远取舍。",
	},
	dot_size = {
		en = "Dot Size",
		["zh-cn"] = "准星点大小",
	},
	dot_opacity = {
		en = "Dot Opacity",
		["zh-cn"] = "准星点不透明度",
	},
	scale_by_distance = {
		en = "Scale by Distance",
		["zh-cn"] = "按距离缩放",
	},
	scale_by_distance_description = {
		en = "Shrink the dot as the enemy gets farther away (0.5x at 50m).",
		["zh-cn"] = "敌人越远准星点越小（50 米处缩小到 0.5 倍）。",
	},
	show_lead = {
		en = "Lead Prediction",
		["zh-cn"] = "提前量预测",
	},
	show_lead_description = {
		en = "Lead moving enemies by predicting their future position at the knife's flight time.",
		["zh-cn"] = "按飞刀飞行时间预测移动敌人的未来位置，指示提前量。",
	},
	lead_multiplier = {
		en = "Lead Multiplier",
		["zh-cn"] = "提前量倍率",
	},
	lead_multiplier_description = {
		en = "Scales the predicted lead. 100% = full lead.",
		["zh-cn"] = "缩放预测的提前量。100% = 完整提前量。",
	},
	require_charges = {
		en = "Hide When Out of Knives",
		["zh-cn"] = "无飞刀余量时隐藏",
	},
	require_charges_description = {
		en = "Hide all extra crosshairs when no throwing knives remain.",
		["zh-cn"] = "飞刀余量为零时隐藏全部额外准星。",
	},
	visibility_check = {
		en = "Line of Sight Check",
		["zh-cn"] = "视线检查",
	},
	visibility_check_description = {
		en = "Hide crosshairs for enemies blocked by walls. Costs extra raycasts, slightly lower performance.",
		["zh-cn"] = "被墙壁阻挡的敌人不显示准星。需要额外的射线检测，性能略有下降。",
	},

	-- enemy_settings
	enemy_settings = {
		en = "Enemy Categories",
		["zh-cn"] = "敌人类别",
	},
	show_boss = {
		en = "Boss",
		["zh-cn"] = "Boss",
	},
	show_elite = {
		en = "Elite",
		["zh-cn"] = "精英",
	},
	show_special = {
		en = "Specialist",
		["zh-cn"] = "专家",
	},
	dot_color = {
		en = "Dot Color",
		["zh-cn"] = "准星颜色",
	},
	use_custom_color = {
		en = "Use Custom Color",
		["zh-cn"] = "使用自定义颜色",
	},
	use_custom_color_description = {
		en = "When off, this enemy type uses its category's dot color instead.",
		["zh-cn"] = "关闭后，该敌人类型改用所属类别的准星颜色。",
	},

	-- unit texts
	meter = {
		en = "m",
		["zh-cn"] = "米",
	},
	percent = {
		en = "%%",
	},
	degree = {
		en = "°",
	},
}

local function is_localization_valid(text)
	return not string.find(text, "unlocalized")
end

-- Breed name localization: reuse the game display names
for breed_name, breed_data in pairs(Breeds) do
	if Breed.is_minion(breed_data) and breed_data.unit_template_name == "minion" and breed_data.faction_name ~= "imperium" then
		local display_name = breed_data.is_boss and type(breed_data.boss_display_name) == "string" and breed_data.boss_display_name or breed_data.display_name
		local ok, text = pcall(Localize, display_name)

		if ok and type(text) == "string" and is_localization_valid(text) then
			localization[breed_name] = { en = text }
		else
			localization[breed_name] = { en = breed_name }
		end
	end
end

return localization
