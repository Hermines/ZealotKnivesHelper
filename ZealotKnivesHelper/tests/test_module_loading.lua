--[[
	Tests: every mod file loads for real in a stub environment

	Game-side files (context/indicators/main file etc.) depend on game globals and the
	mod object. This test executes each file with minimal stubs, catching
	"references an undefined global/module at load time" errors (e.g. a missing local
	declaration causing attempt to index global), and asserts each file returned a
	module table.
]]

local H = dofile("tests/helpers.lua")

print("[test_module_loading]")

-- ---------------------------------------------------------------------------
-- Stub environment
-- ---------------------------------------------------------------------------

-- Load counter (ensures the files are actually executed)
local loaded_files = {}

local mock_mod = {}

function mock_mod.io_dofile(_, path)
	local rel = path:gsub("^ZealotKnivesHelper/", "")
	loaded_files[rel] = true

	return H.load(rel)
end

function mock_mod.localize(_, key)
	return key
end

function mock_mod.get(_, key)
	return nil
end

function mock_mod:hook_safe(_, _, _)
end

function mock_mod:hook(_, _, _)
end

function mock_mod:echo(_, _)
end

_G.get_mod = function(name)
	assert(name == "ZealotKnivesHelper", "unexpected get_mod: " .. tostring(name))

	return mock_mod
end

-- Game require stub: only known paths allowed, anything else errors (surfaces
-- missing dependencies)
local require_stubs = {
	["scripts/managers/ui/ui_widget"] = {
		create_definition = function()
			return { style = {} }
		end,
		draw = function()
		end,
	},
	["scripts/utilities/breed"] = {
		is_minion = function()
			return false
		end,
	},
	["scripts/settings/breed/breeds"] = {},
}

local real_require = require

_G.require = function(path)
	local stub = require_stubs[path]

	if stub then
		return stub
	end

	error("test_module_loading: unexpected require path: " .. tostring(path), 2)
end

-- Game globals are captured into locals at load time (nil is fine), no real
-- implementation needed; any code that indexes/calls a nil global errors at load
-- time and is caught by the test.
_G.Managers = nil

-- ---------------------------------------------------------------------------
-- Load every mod file one by one
-- ---------------------------------------------------------------------------

-- "module"-type files must return a module table; mod_script / data / localization
-- return values are unconstrained
local MODULES = {
	{ name = "core/ballistics", returns_table = true },
	{ name = "core/target_filter", returns_table = true },
	{ name = "core/breed_config", returns_table = true },
	{ name = "core/stack_fade", returns_table = true },
	{ name = "draw/marker_template", returns_table = true },
	{ name = "draw/marker_sync", returns_table = true },
	{ name = "game/breed_list", returns_table = true },
	{ name = "game/context", returns_table = true },
	{ name = "game/indicators", returns_table = true },
	{ name = "ZealotKnivesHelper", returns_table = false },
	{ name = "ZealotKnivesHelper_data", returns_table = false },
	{ name = "ZealotKnivesHelper_localization", returns_table = false },
}

for _, module in ipairs(MODULES) do
	H.case("load " .. module.name, function()
		local ok, result = pcall(H.load, "scripts/mods/ZealotKnivesHelper/" .. module.name)

		if not ok then
			H.fail(module.name .. " failed to load: " .. tostring(result))
			return
		end

		if module.returns_table then
			H.assert_true(type(result) == "table", module.name .. " should return a module table")
		end
	end)
end

H.case("io_dofile dependencies all really loaded", function()
	-- The main file should trigger the loading of these submodules via io_dofile
	for _, dep in ipairs({
		"scripts/mods/ZealotKnivesHelper/game/breed_list",
		"scripts/mods/ZealotKnivesHelper/game/context",
		"scripts/mods/ZealotKnivesHelper/game/indicators",
		"scripts/mods/ZealotKnivesHelper/draw/marker_sync",
	}) do
		H.assert_true(loaded_files[dep] == true, dep .. " should have been loaded")
	end
end)

H.case("localization: tooltips use the DMF _description suffix (auto-lookup key)", function()
	local localization = H.load("scripts/mods/ZealotKnivesHelper/ZealotKnivesHelper_localization")

	for _, setting_id in ipairs({
		"max_distance",
		"max_angle",
		"max_dots",
		"scale_by_distance",
		"show_lead",
		"lead_multiplier",
		"require_charges",
		"visibility_check",
	}) do
		H.assert_true(localization[setting_id .. "_description"] ~= nil,
			setting_id .. "_description should exist (DMF looks up <setting_id>_description)")
		H.assert_nil(localization[setting_id .. "_tooltip"],
			setting_id .. "_tooltip must not exist (DMF never reads the _tooltip suffix)")
	end
end)

H.case("on_setting_changed clears frame_result (render refresh must not consume stale targets)", function()
	local mod = get_mod("ZealotKnivesHelper")

	mod.frame_result = { t = 0, targets = { { unit = "fake_unit" } } }
	mod.on_setting_changed("max_dots")

	H.assert_nil(mod.frame_result, "frame_result must be nil after a setting change")
end)

print("")
