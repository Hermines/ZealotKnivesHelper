--[[
	Tests: draw/marker_template + draw/marker_sync
	- update_function writes the breed color RGB into the widget (regression: writing
	  only alpha once made everything red)
	- alpha channel computation (opacity/stack fade/visibility) and the write threshold
	- marker_sync exports register_templates/sync/clear (regression: a missing export
	  once broke the init hook)
]]

local H = dofile("tests/helpers.lua")

print("[test_marker_drawing]")

-- get_mod stub: marker_template reads mod.indicator_settings at runtime
local mock_settings = {
	dot_size = 6,
	dot_opacity = 1,
}

local mock_mod = {
	indicator_settings = mock_settings,
}

function mock_mod.io_dofile(_, path)
	-- In-game paths look like "ZealotKnivesHelper/scripts/mods/...", strip the mod name prefix
	local rel = path:gsub("^ZealotKnivesHelper/", "")

	return H.load(rel)
end

_G.get_mod = function(name)
	assert(name == "ZealotKnivesHelper", "unexpected get_mod: " .. tostring(name))

	return mock_mod
end

-- UIWidget.create_definition stub: returns a minimal clonable definition
_G.require = function(path)
	assert(path == "scripts/managers/ui/ui_widget", "unexpected require: " .. tostring(path))

	return {
		create_definition = function(passes, scenegraph_id)
			return {
				content = {},
				style = {
					dot = {
						size = { 6, 6 },
						color = { 255, 255, 80, 80 },
					},
				},
			}
		end,
	}
end

local template = H.load("scripts/mods/ZealotKnivesHelper/draw/marker_template")

H.case("template base fields", function()
	H.assert_equal(template.name, "zealot_knives_helper_dot")
	H.assert_false(template.check_line_of_sight, "LOS handled by the mod itself")
	H.assert_false(template.screen_clamp)
end)

H.case("create_widget_defintion sets default_size (for engine distance scaling)", function()
	local definition = template.create_widget_defintion(template, "pivot")
	local dot_style = definition.style.dot

	H.assert_true(dot_style.default_size ~= nil, "default_size should exist")
	H.assert_equal(dot_style.default_size[1], 6)
	H.assert_equal(dot_style.default_size[2], 6)
end)

-- Build a widget + marker and run update_function once
local function run_update(marker_data)
	local widget = {
		style = {
			dot = {
				size = { 6, 6 },
				default_size = { 6, 6 },
				color = { 255, 255, 80, 80 },
			},
		},
	}

	local marker = {
		data = marker_data,
		template = template,
	}

	template.update_function(nil, nil, widget, marker, template, 0, 0)

	return widget.style.dot
end

H.case("update_function writes breed color RGB (regression)", function()
	local style = run_update({
		color = { 255, 90, 200, 255 },
		size = 6,
		stack_alpha = 1,
		visible = true,
	})

	H.assert_equal(style.color[2], 90, "R channel = breed color")
	H.assert_equal(style.color[3], 200, "G channel = breed color")
	H.assert_equal(style.color[4], 255, "B channel = breed color")
end)

H.case("update_function computes alpha (opacity/stack/visibility)", function()
	-- Opacity 0.5, stack 0.8: alpha = 255*0.5*0.8 = 102
	mock_settings.dot_opacity = 0.5

	local style = run_update({
		color = { 255, 90, 200, 255 },
		size = 6,
		stack_alpha = 0.8,
		visible = true,
	})

	mock_settings.dot_opacity = 1

	H.assert_near(style.color[1], 102, 0.01, "alpha = 255 x opacity x stack")

	-- Not visible: alpha = 0
	local hidden = run_update({
		color = { 255, 90, 200, 255 },
		size = 6,
		stack_alpha = 1,
		visible = false,
	})

	H.assert_near(hidden.color[1], 0, 0.01, "alpha = 0 when not visible")
end)

H.case("update_function size: writes size directly without scaling", function()
	local style = run_update({
		color = { 255, 0, 0, 0 },
		size = 9,
	})

	H.assert_equal(style.size[1], 9)
	H.assert_equal(style.size[2], 9)
	H.assert_equal(style.default_size[1], 9, "default_size syncs the setting value")
end)

H.case("marker_sync exports the public interface (regression)", function()
	local saved_get_mod = _G.get_mod

	-- marker_sync loads marker_template via io_dofile
	local mock_sync_mod = {
		io_dofile = function(_, path)
			local rel = path:gsub("^ZealotKnivesHelper/", "")

			return H.load(rel)
		end,
	}

	_G.get_mod = function()
		return mock_sync_mod
	end

	local MarkerSync = H.load("scripts/mods/ZealotKnivesHelper/draw/marker_sync")

	_G.get_mod = saved_get_mod

	H.assert_true(type(MarkerSync.register_templates) == "function", "register_templates should be exported (called by the init hook)")
	H.assert_true(type(MarkerSync.sync) == "function")
	H.assert_true(type(MarkerSync.clear) == "function")
	H.assert_true(type(MarkerSync.count) == "function")
end)

-- ---------------------------------------------------------------------------
-- marker_sync interaction with lingering targets (the linger period is owned by
-- indicators, sync handles reuse/removal)
-- ---------------------------------------------------------------------------

local sync_time = 0
local next_marker_id = 0
local removed_ids = {}
local added_ids = {}
local last_added_data = nil
local last_added_pos = nil
local last_stored_pos = nil
local fake_element = nil

local function setup_marker_env()
	sync_time = 0
	next_marker_id = 0
	removed_ids = {}
	added_ids = {}
	last_added_data = nil
	last_added_pos = nil
	last_stored_pos = nil
	fake_element = {
		_marker_templates = {},
		_markers_by_id = {},
	}

	_G.Vector3 = function(x, y, z)
		return { x = x, y = y, z = z }
	end

	_G.Managers = {
		time = {
			has_timer = function()
				return true
			end,
			time = function()
				return sync_time
			end,
		},
		event = {
			trigger = function(_, event_name, arg1, arg2, arg3, arg4)
				if event_name == "add_world_marker_position" then
					next_marker_id = next_marker_id + 1

					-- Faithful to the engine: marker.template is a clone of the registered
					-- template (the mod template is flat, so a shallow copy equals the
					-- engine's table.clone here)
					local registered = fake_element._marker_templates[arg1]
					local cloned = {}

					if registered then
						for key, value in pairs(registered) do
							cloned[key] = value
						end
					end

					fake_element._markers_by_id[next_marker_id] = {
						world_position = {
							store = function(_, v)
								last_stored_pos = v
							end,
						},
						template = cloned,
					}
					last_added_data = arg4
					last_added_pos = arg2
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
		store = function(_, v)
			last_stored_pos = v
		end,
	}

	return H.load("scripts/mods/ZealotKnivesHelper/draw/marker_sync")
end

local function make_sync_target(unit, linger, stack_alpha)
	return {
		unit = unit,
		aim_position = { x = 0, y = 30, z = 1.7 },
		aim_x = 0,
		aim_y = 30,
		aim_z = 1.7,
		color = { 255, 90, 200, 255 },
		size = 6,
		stack_alpha = stack_alpha,
		visible = true,
		linger = linger,
	}
end

H.case("sync: lingering target reuses the existing marker (no delete/recreate), fade alpha written", function()
	local MarkerSync = setup_marker_env()
	local unit = { __alive = true }

	MarkerSync.sync({ make_sync_target(unit) })

	H.assert_equal(MarkerSync.count(), 1, "shown: marker created")

	MarkerSync.sync({ make_sync_target(unit, true, 0.5) })

	H.assert_equal(MarkerSync.count(), 1, "lingering target reuses the marker")
	H.assert_equal(#removed_ids, 0, "no removal triggered")
	H.assert_equal(#added_ids, 1, "no recreation triggered")
	H.assert_near(last_added_data.stack_alpha, 0.5, 0.001, "fade alpha written into data")
end)

H.case("sync/update_positions: aim point built from scalars on site (scalar-only regression)", function()
	local MarkerSync = setup_marker_env()
	local unit = { __alive = true }

	-- Creation: the position received by the add event is built from aim_x/y/z
	MarkerSync.sync({ make_sync_target(unit) })

	H.assert_equal(last_added_pos.x, 0, "creation position x")
	H.assert_equal(last_added_pos.y, 30, "creation position y")
	H.assert_equal(last_added_pos.z, 1.7, "creation position z")

	-- Render-frame write-back: store receives a vector built from scalars
	local new_target = make_sync_target(unit)
	new_target.aim_x, new_target.aim_y, new_target.aim_z = 1.5, 32, 2.1

	MarkerSync.update_positions({ new_target })

	H.assert_near(last_stored_pos.x, 1.5, 1e-9, "render-frame store position x")
	H.assert_near(last_stored_pos.y, 32, 1e-9, "render-frame store position y")
	H.assert_near(last_stored_pos.z, 2.1, 1e-9, "render-frame store position z")

	-- Regression: even with a bad aim_position field (dangling userdata scenario),
	-- store only relies on the scalar components and never touches it
	new_target.aim_position = setmetatable({}, {})
	new_target.aim_x, new_target.aim_y, new_target.aim_z = 2, 33, 2.2

	MarkerSync.update_positions({ new_target })

	H.assert_near(last_stored_pos.x, 2, 1e-9, "bad aim_position does not affect the scalar store")
end)

H.case("sync: target without scalar components skips the position write (no crash)", function()
	local MarkerSync = setup_marker_env()
	local unit = { __alive = true }

	MarkerSync.sync({ make_sync_target(unit) })

	H.assert_equal(MarkerSync.count(), 1)

	-- Missing scalar components (defensive path): skip the store, no error, marker kept
	local broken = make_sync_target(unit)
	broken.aim_x, broken.aim_y, broken.aim_z = nil, nil, nil

	MarkerSync.sync({ broken })

	H.assert_equal(MarkerSync.count(), 1, "marker kept")
end)

H.case("sync: no recreation when a lingering target's marker is lost (avoids flashing mid-fade)", function()
	local MarkerSync = setup_marker_env()
	local unit = { __alive = true }

	MarkerSync.sync({ make_sync_target(unit) })

	-- Simulate engine reclamation (HUD rebuild)
	for id in pairs(fake_element._markers_by_id) do
		fake_element._markers_by_id[id] = nil
	end

	MarkerSync.sync({ make_sync_target(unit, true, 0.4) })

	H.assert_equal(MarkerSync.count(), 0, "lingering marker not recreated")
	H.assert_equal(#added_ids, 1, "no add events")
end)

H.case("sync: non-lingering target dropping off is removed immediately (linger owned by indicators)", function()
	local MarkerSync = setup_marker_env()
	local unit = { __alive = true }

	MarkerSync.sync({ make_sync_target(unit) })

	H.assert_equal(MarkerSync.count(), 1)

	MarkerSync.sync({})

	H.assert_equal(MarkerSync.count(), 0, "removed immediately")
	H.assert_equal(#removed_ids, 1, "one removal event")
end)

H.case("sync: engine clone gets max_distance/scale_settings, never fade_settings (distance fade intentionally removed)", function()
	local MarkerSync = setup_marker_env()
	local unit = { __alive = true }

	mock_settings.max_distance = 37
	mock_settings.scale_by_distance = true

	MarkerSync.sync({ make_sync_target(unit) })

	local marker = fake_element._markers_by_id[1]

	H.assert_equal(marker.template.max_distance, 37, "clone refreshes max_distance from settings")
	H.assert_true(marker.template.scale_settings ~= nil, "clone gets scale_settings when scaling is on")
	H.assert_nil(marker.template.fade_settings, "no fade_settings: max_distance is a hard cutoff, engine distance fade is not configured")

	mock_settings.max_distance = nil
	mock_settings.scale_by_distance = nil
end)

print("")
