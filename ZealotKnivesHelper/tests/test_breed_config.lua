--[[
	Tests: core/breed_config
	- shown = category toggle AND breed toggle
	- color = breed color > category color > fallback white
]]

local H = dofile("tests/helpers.lua")
local BreedConfig = H.load("scripts/mods/ZealotKnivesHelper/core/breed_config")

print("[test_breed_config]")

local config = {
	category_show = { boss = true, elite = true, special = false },
	category_color = {
		boss = { 255, 255, 70, 70 },
		elite = { 255, 255, 165, 40 },
		special = { 255, 90, 200, 255 },
	},
	breed_show = {
		chaos_hound = false,
	},
	breed_color = {
		cultist_gunner = { 255, 10, 20, 30 },
	},
}

H.case("is_shown", function()
	H.assert_true(BreedConfig.is_shown("chaos_spawn", "boss", config), "category enabled and breed not individually disabled")
	H.assert_true(BreedConfig.is_shown("cultist_gunner", "elite", config), "elite category enabled")
	H.assert_false(BreedConfig.is_shown("cultist_flamer", "special", config), "special category disabled")
	H.assert_false(BreedConfig.is_shown("chaos_hound", "special", config), "breed individually disabled")
	H.assert_false(BreedConfig.is_shown("chaos_hound", "boss", config), "breed disable overrides category enable")
	H.assert_false(BreedConfig.is_shown("chaos_spawn", "boss", nil), "no config means not shown")
end)

H.case("color fallback chain", function()
	H.assert_equal(BreedConfig.color("cultist_gunner", "elite", config)[2], 10, "breed color takes priority")
	H.assert_equal(BreedConfig.color("chaos_spawn", "boss", config)[2], 255, "no breed color falls back to the category color")
	H.assert_equal(BreedConfig.color("chaos_spawn", "boss", config)[3], 70, "category color g component")
	H.assert_equal(BreedConfig.color("anything", "unknown", nil)[1], 255, "no config falls back to white (alpha=255)")
end)

H.case("color: use-custom-color off (nil breed color entry) follows the category color", function()
	local cfg = {
		category_color = { elite = { 255, 1, 2, 3 } },
		breed_color = { renegade_sniper = nil },
	}

	H.assert_equal(BreedConfig.color("renegade_sniper", "elite", cfg)[2], 1, "nil breed color entry follows the category color")
end)

print("")
