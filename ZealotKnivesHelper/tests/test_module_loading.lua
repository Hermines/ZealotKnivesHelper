--[[
	Test: every mod file loads for real in a stub environment

	Game-side files (context/indicators/main file etc.) depend on game globals and the
	mod object. This test executes each file with minimal stubs, catching
	"references an undefined global/module at load time" errors (e.g. a missing local
	declaration causing attempt to index global), and asserts each file returned a
	module table.

	Beyond loading, the captured main-file hook handlers are driven directly to lock
	behavioral contracts: keybind callback conventions and the render-frame freshness
	guard (stale result + despawned player must reclaim the mod's markers).
]]

local H = dofile("tests/helpers.lua")

print("[test_module_loading]")

-- ---------------------------------------------------------------------------
-- Stub environment
-- ---------------------------------------------------------------------------

-- Load counter (ensures the files are actually executed)
local loaded_files = {}

local mock_mod = {}
-- Hook handlers captured at load time (keyed "Class.method") so behavioral cases
-- can drive the main file's fixed-frame/render-frame handlers directly
mock_mod._hooks = { safe = {}, pre = {} }

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

function mock_mod:hook_safe(obj, method, fn)
	-- tostring(obj): string-form hooks keep their readable keys, table-form
	-- hooks (compat guards on game modules) get a unique stable key
	self._hooks.safe[tostring(obj) .. "." .. method] = fn
end

function mock_mod:hook(obj, method, fn)
	self._hooks.pre[tostring(obj) .. "." .. method] = fn
end

function mock_mod:echo(_, _)
end

-- Surfaced as a test failure: the main file's render refresh must run silently
function mock_mod:error(_, msg)
	H.fail("main file logged an error: " .. tostring(msg))
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
	-- Boot-time game module required by compat/main_path_guard (the pcall'd
	-- require must succeed so the guard installs against this stub)
	["scripts/managers/main_path/path_types/path_type_linear"] = {
		update_progress_on_path = function()
		end,
	},
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
	{ name = "compat/main_path_guard", returns_table = false },
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
		"scripts/mods/ZealotKnivesHelper/compat/main_path_guard",
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
		"always_show",
		"always_show_key",
		"force_show_key",
		"hide_near",
		"use_custom_color",
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

H.case("keybind callbacks: toggle flips always_show via set(..., notify), hold key drives force_show", function()
	local mod = get_mod("ZealotKnivesHelper")

	H.assert_true(type(mod.on_always_show_key) == "function", "on_always_show_key should be defined")
	H.assert_true(type(mod.on_force_show_key) == "function", "on_force_show_key should be defined")

	-- Hold key: press/release drive the runtime flag on indicator_settings.
	-- DMF calls the handler WITHOUT self (safe_call_nr passes only the flag), so
	-- keybind_is_pressed is the first argument -- lock that convention here
	mod.on_force_show_key(true)
	H.assert_true(mod.indicator_settings.force_show == true, "press sets force_show")

	mod.on_force_show_key(false)
	H.assert_true(mod.indicator_settings.force_show == false, "release clears force_show")

	-- Toggle key: flips the persisted setting through mod:set(..., true) so the
	-- change routes through on_setting_changed like a manual options-view change
	local saved_get, saved_set = mod.get, mod.set
	local stored = { always_show = false }
	local set_calls = {}

	function mod.get(_, id)
		return stored[id]
	end

	function mod.set(_, id, value, notify)
		stored[id] = value
		set_calls[#set_calls + 1] = { id = id, value = value, notify = notify }
	end

	mod.on_always_show_key(true)
	H.assert_true(stored.always_show == true, "toggle flips false -> true")
	H.assert_equal(set_calls[1].id, "always_show", "set targets the always_show setting")
	H.assert_true(set_calls[1].notify == true, "set uses notify = true (on_setting_changed must fire)")

	mod.on_always_show_key(true)
	H.assert_true(stored.always_show == false, "toggle flips true -> false")

	mod.get, mod.set = saved_get, saved_set
end)

-- ---------------------------------------------------------------------------
-- Per-breed "use custom color": unchecking it makes that breed follow its
-- category's dot color (the category color pickers were dead settings before --
-- the per-breed color default always won). The two cases below run with the
-- breeds stub populated, so the data file generates real breed widgets and the
-- main file's rebuild loop has breeds to iterate; stubs restored afterwards.
-- ---------------------------------------------------------------------------

local saved_breed_util = require_stubs["scripts/utilities/breed"]
local saved_breeds = require_stubs["scripts/settings/breed/breeds"]

require_stubs["scripts/utilities/breed"] = {
	is_minion = function()
		return true
	end,
}
require_stubs["scripts/settings/breed/breeds"] = {
	zkh_test_bulwark = { unit_template_name = "minion", faction_name = "renegade", tags = { elite = true } },
	zkh_test_raider = { unit_template_name = "minion", faction_name = "chaos", tags = { elite = true } },
}

H.case("data file: breed widgets nest use_custom_color (default true) above the color picker", function()
	local data = H.load("scripts/mods/ZealotKnivesHelper/ZealotKnivesHelper_data")

	local function find_widget(widgets, setting_id)
		for _, widget in ipairs(widgets or {}) do
			if widget.setting_id == setting_id then
				return widget
			end
		end

		return nil
	end

	local enemy_group = find_widget(data.options.widgets, "enemy_settings")
	H.assert_true(enemy_group ~= nil, "enemy_settings group exists")

	local elite_toggle = find_widget(enemy_group and enemy_group.sub_widgets, "show_elite")
	H.assert_true(elite_toggle ~= nil, "show_elite toggle exists")

	-- Category color picker stays directly under the category toggle
	local elite_color = find_widget(elite_toggle and elite_toggle.sub_widgets, "color_elite")
	H.assert_true(elite_color ~= nil, "category color picker still directly under the category toggle")

	-- Breed widget: show toggle -> use_custom_color toggle -> color picker
	local breed_widget = find_widget(elite_toggle and elite_toggle.sub_widgets, "breed_show_zkh_test_bulwark")
	H.assert_true(breed_widget ~= nil, "breed widget generated for the stub breed")

	local use_custom = find_widget(breed_widget and breed_widget.sub_widgets, "use_custom_color_zkh_test_bulwark")
	H.assert_true(use_custom ~= nil, "use_custom_color widget nested under the breed show toggle")
	H.assert_equal(use_custom and use_custom.type, "checkbox", "use_custom_color is a checkbox")
	H.assert_true(use_custom and use_custom.default_value == true, "use_custom_color defaults to true (upgraders keep their per-breed colors)")

	local breed_color = find_widget(use_custom and use_custom.sub_widgets, "breed_color_zkh_test_bulwark")
	H.assert_true(breed_color ~= nil, "color picker nested under use_custom_color")
	H.assert_equal(breed_color and breed_color.default_value, mock_mod.category_default_colors.elite, "breed color default is the category default color")
end)

H.case("main file rebuild: use_custom_color off -> nil breed color -> BreedConfig follows the category color", function()
	local mod = get_mod("ZealotKnivesHelper")
	local saved_get = mock_mod.get
	local stored = {
		color_elite = { 255, 1, 2, 3 },
		breed_show_zkh_test_raider = true,
		use_custom_color_zkh_test_raider = false, -- follows the category color
		breed_color_zkh_test_raider = { 255, 9, 8, 7 },
		breed_show_zkh_test_bulwark = true,
		use_custom_color_zkh_test_bulwark = true, -- keeps its custom color
		breed_color_zkh_test_bulwark = { 255, 4, 5, 6 },
	}

	function mock_mod.get(_, id)
		return stored[id]
	end

	-- Fresh main-file load: its BreedList closure collects the stub breeds, and
	-- the settings snapshot picks up the stored category color
	H.load("scripts/mods/ZealotKnivesHelper/ZealotKnivesHelper")
	mod.on_setting_changed("use_custom_color_zkh_test_raider")

	local breed_config = mod.indicator_settings.breed_config

	H.assert_nil(breed_config.breed_color.zkh_test_raider, "use_custom_color off -> nil breed color (category fallback)")
	H.assert_equal(breed_config.breed_color.zkh_test_bulwark, stored.breed_color_zkh_test_bulwark, "use_custom_color on -> custom color kept")
	H.assert_equal(breed_config.category_color.elite, stored.color_elite, "category color cached from the settings snapshot")

	-- End-to-end resolution through the pure config module
	local BreedConfig = H.load("scripts/mods/ZealotKnivesHelper/core/breed_config")

	H.assert_equal(BreedConfig.color("zkh_test_raider", "elite", breed_config), stored.color_elite, "BreedConfig: follows the category color when custom is off")
	H.assert_equal(BreedConfig.color("zkh_test_bulwark", "elite", breed_config), stored.breed_color_zkh_test_bulwark, "BreedConfig: custom color wins when on")

	mock_mod.get = saved_get
end)

require_stubs["scripts/utilities/breed"] = saved_breed_util
require_stubs["scripts/settings/breed/breeds"] = saved_breeds

-- ---------------------------------------------------------------------------
-- Main-file render refresh (death-freeze fix): when the fixed frame stops
-- updating because the local player unit was despawned (death despawns the
-- corpse while GameplayStateRun continues), the render-frame stale guard must
-- reclaim the mod's markers once; a present-but-stale player (hitch) must leave
-- them untouched
-- ---------------------------------------------------------------------------

H.case("main file: stale frame_result reclaims markers only when the player unit is gone", function()
	-- Fresh game-global mocks; the main file is re-loaded below so it captures them
	local Vector3 = H.make_vector3_mock()
	_G.Vector3 = Vector3

	_G.Unit = {
		alive = function(unit)
			return unit.__alive
		end,
		has_node = function(_, node)
			return node == "j_head"
		end,
		node = function()
			return 1
		end,
		world_position = function(unit)
			return unit.__head
		end,
	}

	local function make_data_ext(breed)
		return {
			archetype_name = function()
				return "zealot"
			end,
			breed = function()
				return breed
			end,
			read_component = function(_, component)
				if component == "first_person" then
					return { position = Vector3(0, 0, 1.7) }
				end
			end,
		}
	end

	_G.ScriptUnit = {
		has_extension = function(unit, system)
			if system == "unit_data_system" then
				return unit.__data ~= nil
			end

			if system == "weapon_system" then
				return unit.__weapons ~= nil
			end

			if system == "ability_system" then
				return unit.__charges ~= nil
			end

			if system == "health_system" then
				return unit.__alive ~= nil
			end

			return false
		end,
		extension = function(unit, system)
			if system == "unit_data_system" then
				return unit.__data
			end

			if system == "weapon_system" then
				return { _weapons = unit.__weapons }
			end

			if system == "ability_system" then
				return {
					remaining_ability_charges = function()
						return unit.__charges
					end,
				}
			end

			if system == "health_system" then
				return {
					is_alive = function()
						return unit.__alive
					end,
				}
			end
		end,
	}

	_G.Quaternion = {
		forward = function()
			return Vector3(0, 1, 0)
		end,
	}

	local main_time = 0
	local local_player = nil
	local player_unit = {
		__alive = true,
		__data = make_data_ext(nil),
		__weapons = {
			slot_grenade_ability = {
				weapon_template = { name = "zealot_throwing_knives" },
			},
		},
		__charges = 3,
		__head = Vector3(0, 0, 1.7),
	}

	local function make_player()
		return {
			player_unit = player_unit,
			viewport_name = "player1",
			unit_is_alive = function()
				return true
			end,
			_profile = { archetype = { name = "zealot" } },
		}
	end

	local broadphase_units = {}
	local added_ids, removed_ids = {}, {}
	local next_marker_id = 0
	local fake_element = { _marker_templates = {}, _markers_by_id = {} }

	_G.Managers = {
		time = {
			has_timer = function()
				return true
			end,
			time = function()
				return main_time
			end,
		},
		player = {
			local_player = function()
				return local_player
			end,
		},
		state = {
			camera = {
				camera = function()
					return {}
				end,
				camera_position = function()
					return Vector3(0, 0, 1.7)
				end,
				camera_rotation = function()
					return { __rot = true }
				end,
			},
			extension = {
				system = function(_, name)
					if name == "broadphase_system" then
						return {
							broadphase = {
								query = function(_, pos, dist, results, names)
									for i, unit in ipairs(broadphase_units) do
										results[i] = unit
									end

									return #broadphase_units
								end,
							},
						}
					end

					if name == "side_system" then
						return {
							side_by_unit = {
								[player_unit] = {
									relation_side_names = function()
										return { "enemy" }
									end,
								},
							},
						}
					end

					return nil
				end,
			},
		},
		world = nil, -- no physics world: LOS fails open without raycasts
		event = {
			trigger = function(_, event_name, arg1, arg2, arg3, arg4)
				if event_name == "add_world_marker_position" then
					next_marker_id = next_marker_id + 1

					local cloned = {}
					local registered = fake_element._marker_templates[arg1]

					if registered then
						for key, value in pairs(registered) do
							cloned[key] = value
						end
					end

					fake_element._markers_by_id[next_marker_id] = {
						world_position = {
							store = function() end,
						},
						template = cloned,
						data = arg4,
					}
					added_ids[#added_ids + 1] = next_marker_id

					if arg3 then
						arg3(next_marker_id)
					end
				elseif event_name == "remove_world_marker" then
					removed_ids[#removed_ids + 1] = arg1
					fake_element._markers_by_id[arg1] = nil
				end
			end,
		},
		ui = {
			get_hud = function()
				return {
					element = function()
						return fake_element
					end,
				}
			end,
		},
	}

	_G.Vector3Box = {
		store = function() end,
	}

	-- Re-load the main file so it captures the mocks above (the loop load ran with
	-- nil globals; its captured handlers are replaced by this fresh load)
	H.load("scripts/mods/ZealotKnivesHelper/ZealotKnivesHelper")

	local fixed_fn = mock_mod._hooks.safe["PlayerUnitFirstPersonExtension.fixed_update"]
	local render_fn = mock_mod._hooks.pre["HudElementWorldMarkers.update"]

	H.assert_true(type(fixed_fn) == "function", "fixed_update hook handler captured")
	H.assert_true(type(render_fn) == "function", "render update hook handler captured")

	local enemy = {
		__alive = true,
		__head = Vector3(0, 20, 1.7),
		__data = make_data_ext({ name = "chaos_shock_trooper", tags = { elite = true } }),
	}
	broadphase_units = { enemy }

	-- Fixed frame computes a target and syncs one marker
	local_player = make_player()
	main_time = 100
	fixed_fn(nil, player_unit, 0.019, 100, 0)

	H.assert_equal(#added_ids, 1, "target shown: one marker created")
	H.assert_equal(#removed_ids, 0)

	-- Fresh result + player alive: refresh runs, nothing removed
	render_fn(function() end, nil, 0.016, 100)
	H.assert_equal(#removed_ids, 0, "fresh result: no removal")

	-- Stale result (hitch > 0.25 s) + player still alive: markers untouched
	main_time = 100.4
	render_fn(function() end, nil, 0.016, 100.4)
	H.assert_equal(#removed_ids, 0, "stale result with the player present: no removal")

	-- Stale result + player unit despawned (death): markers reclaimed once
	local_player = nil
	main_time = 100.8
	render_fn(function() end, nil, 0.016, 100.8)

	H.assert_equal(#removed_ids, 1, "despawned player: stale markers reclaimed")
	H.assert_nil(fake_element._markers_by_id[1], "marker removed from the element")
	H.assert_nil(mock_mod.frame_result, "stale frame_result cleared")

	-- Further render frames with no result: no repeated removals, no errors
	render_fn(function() end, nil, 0.016, 100.9)
	H.assert_equal(#removed_ids, 1, "cleanup runs exactly once")

	-- Respawn: the fixed frame resumes and recreates the marker
	local_player = make_player()
	main_time = 101
	fixed_fn(nil, player_unit, 0.019, 101, 0)

	H.assert_equal(#added_ids, 2, "respawn: the pipeline recreates the marker")
	H.assert_true(fake_element._markers_by_id[2] ~= nil, "new marker lives on the element")
end)

-- ---------------------------------------------------------------------------
-- compat/main_path_guard: the game's update_progress_on_path crashes on a
-- fresh mid-run player unit (ICC character switch in beacon-less maps, e.g.
-- the shooting range). The guard's pcall chain-hook must swallow that race
-- error (skip the frame), pass clean calls through with their return values,
-- and log throttled (echo stubbed silent here).
-- ---------------------------------------------------------------------------

H.case("main-path race guard: swallows the game's start_index race, passes clean calls through", function()
	local path_stub = require_stubs["scripts/managers/main_path/path_types/path_type_linear"]
	local handler = mock_mod._hooks.pre[tostring(path_stub) .. ".update_progress_on_path"]

	H.assert_true(type(handler) == "function", "guard hook handler captured")

	-- Clean call: passthrough with the original arguments and return values
	local passed_self, passed_t
	local returned = { handler(function(self, t)
		passed_self, passed_t = self, t

		return "a", "b"
	end, "self1", 33) }

	H.assert_equal(passed_self, "self1", "original self forwarded")
	H.assert_equal(passed_t, 33, "original t forwarded")
	H.assert_equal(returned[1], "a", "first return value forwarded")
	H.assert_equal(returned[2], "b", "second return value forwarded")

	-- The game's race error must be swallowed: no propagation to the caller
	local race_fn = function()
		error("scripts/managers/main_path/path_types/path_type_linear.lua:263: attempt to perform arithmetic on local 'start_index' (a nil value)")
	end

	H.assert_true(pcall(handler, race_fn, "self2", 33), "race error swallowed, no propagation")
	H.assert_equal(select("#", handler(race_fn, "self2", 33)), 0, "no return values on the skipped frame")
end)

print("")
