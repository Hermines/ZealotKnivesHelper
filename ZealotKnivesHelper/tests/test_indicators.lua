--[[
	Tests: game/indicators.compute_aim_position (end-to-end)

	Loads the game-side module with a mocked Vector3 and verifies:
	  - the computed "world position the crosshair should point at" actually makes the
	    knife (per the game integrator) hit the target
	  - lead prediction behavior (multiplier 0 = no lead; laterally moving targets
	    shift toward the velocity direction)
	  - handling of unreachable / zero distance
]]

local H = dofile("tests/helpers.lua")
local Ballistics = H.load("scripts/mods/ZealotKnivesHelper/core/ballistics")

-- Inject the mock environment before loading the game-side module
_G.Vector3 = H.make_vector3_mock()

-- Unit mock: units simulate alive state and head position via __alive/__head fields
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

-- ScriptUnit mock: extensions provided from the unit table's __breed/__weapons/__alive fields
_G.ScriptUnit = {
	has_extension = function(unit, system)
		if system == "unit_data_system" then
			return unit.__breed ~= nil
		end

		if system == "weapon_system" then
			return unit.__weapons ~= nil
		end

		if system == "health_system" then
			return unit.__alive ~= nil
		end

		return false
	end,
	extension = function(unit, system)
		if system == "unit_data_system" then
			return {
				breed = function()
					return unit.__breed
				end,
			}
		end

		if system == "weapon_system" then
			return { _weapons = unit.__weapons }
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

-- Camera forward fixed to +y (the crosshair points at targets in the +y direction)
_G.Quaternion = {
	forward = function()
		return Vector3(0, 1, 0)
	end,
}

-- Managers stub: time returns a controllable main clock (for linger timing);
-- player/state are added in the case sections
local test_time = 0

_G.Managers = {
	time = {
		has_timer = function()
			return true
		end,
		time = function()
			return test_time
		end,
	},
}

local mock_mod = {
	-- Settings view read at runtime by refresh_positions / update
	indicator_settings = {
		toggle_mod = true,
		show_lead = true,
		lead_multiplier = 1,
		dot_size = 6,
		dot_opacity = 1,
		category_show = { boss = true, elite = true, special = true },
		breed_hidden = {},
	},
}

function mock_mod.io_dofile(_, path)
	-- In-game paths look like "ZealotKnivesHelper/scripts/mods/...", strip the mod name prefix
	local rel = path:gsub("^ZealotKnivesHelper/", "")

	return H.load(rel)
end

_G.get_mod = function()
	return mock_mod
end

local Indicators = H.load("scripts/mods/ZealotKnivesHelper/game/indicators")

print("[test_indicators]")

local P = {
	k = Ballistics.drag_constant(),
	gravity = 17.5,
	dt = 1 / 52, -- matches the game fixed frame / the solver's dt
	speed = 75,
}

local settings = {
	toggle_mod = true,
	show_lead = false,
	lead_multiplier = 1,
}

local function elevation_of(aim_position, origin)
	local d = aim_position - origin
	local horizontal = math.sqrt(d.x * d.x + d.y * d.y)

	return math.atan2(d.z, horizontal)
end

H.case("static targets: the trajectory actually hits", function()
	local origin = Vector3(0, 0, 1.7)
	local targets = {
		{ pos = Vector3(0, 20, 1.7), label = "20 m flat" },
		{ pos = Vector3(3, 30, 6.7), label = "30 m, 5 m up" },
		{ pos = Vector3(-2, 15, -2.3), label = "15 m, 4 m down" },
		{ pos = Vector3(0, 60, 1.7), label = "60 m, long range" },
	}

	for _, target in ipairs(targets) do
		local aim_position = Indicators.compute_aim_position(nil, 0, origin, target.pos, nil, settings)

		if not aim_position then
			H.fail(target.label .. ": computation failed")
		else
			-- The aim point should extend along the trajectory direction (distance + 10 m margin)
			local to_aim = aim_position - origin
			local dist = Vector3.length(target.pos - origin)

			H.assert_near(Vector3.length(to_aim), dist + 10, 0.5, target.label .. ": aim point distance = target distance + margin")

			-- Verify with the independent integrator: throwing from the origin along the
			-- aim direction hits the target height at the target's horizontal distance
			local elevation = elevation_of(aim_position, origin)
			local points = H.integrate_flat(P, elevation)
			local d_horizontal = math.sqrt((target.pos.x - origin.x) ^ 2 + (target.pos.y - origin.y) ^ 2)
			local z_at_d = H.height_at_distance(points, d_horizontal)

			H.assert_near(z_at_d, target.pos.z - origin.z, 0.1, target.label .. ": hit height error < 0.1 m")
		end
	end
end)

H.case("lead: multiplier 0 equals no prediction", function()
	local origin = Vector3(0, 0, 1.7)
	local target = Vector3(0, 20, 1.7)
	local velocity = Vector3(3, 0, 0)

	local with_lead_zero = Indicators.compute_aim_position(nil, 0, origin, target, velocity, {
		show_lead = true,
		lead_multiplier = 0,
	})
	local no_lead = Indicators.compute_aim_position(nil, 0, origin, target, nil, settings)

	H.assert_near(with_lead_zero.x, no_lead.x, 1e-6)
	H.assert_near(with_lead_zero.y, no_lead.y, 1e-6)
	H.assert_near(with_lead_zero.z, no_lead.z, 1e-6)
end)

H.case("lead: laterally moving target shifts toward the velocity", function()
	local origin = Vector3(0, 0, 1.7)
	local target = Vector3(0, 20, 1.7)
	local velocity = Vector3(5, 0, 0)

	local no_lead = Indicators.compute_aim_position(nil, 0, origin, target, nil, settings)
	local with_lead = Indicators.compute_aim_position(nil, 0, origin, target, velocity, {
		show_lead = true,
		lead_multiplier = 1,
	})

	H.assert_true(with_lead.x > no_lead.x + 0.1, "target moving along +x: the aim point should shift toward +x")

	-- Moving the other way should shift the aim point the other way
	local with_lead_neg = Indicators.compute_aim_position(nil, 0, origin, target, Vector3(-5, 0, 0), {
		show_lead = true,
		lead_multiplier = 1,
	})

	H.assert_true(with_lead_neg.x < no_lead.x - 0.1, "target moving along -x: the aim point should shift toward -x")

	-- The led aim point points at the "predicted position": its horizontal distance
	-- should be greater than the original target distance
	local lead_horizontal = math.sqrt((with_lead - origin).x ^ 2 + (with_lead - origin).y ^ 2)
	local no_lead_horizontal = math.sqrt((no_lead - origin).x ^ 2 + (no_lead - origin).y ^ 2)

	H.assert_true(lead_horizontal > no_lead_horizontal, "the led aim point sits farther out in the trajectory plane")
end)

H.case("unreachable target returns nil", function()
	local origin = Vector3(0, 0, 1.7)
	local aim_position = Indicators.compute_aim_position(nil, 0, origin, Vector3(0, 500, 1.7), nil, settings)

	H.assert_nil(aim_position, "500 m is beyond vacuum range, no solution")
end)

H.case("zero distance / coincident position returns nil", function()
	local origin = Vector3(1, 2, 3)
	local aim_position = Indicators.compute_aim_position(nil, 0, origin, Vector3(1, 2, 3), nil, settings)

	H.assert_nil(aim_position)
end)

H.case("refresh_positions: re-solves past the move tolerance, keeps the pitch within it", function()
	local origin = Vector3(0, 0, 1.7)
	local unit = {
		__alive = true,
		__head = Vector3(0, 20, 1.7),
	}

	-- Fixed frame: solve the current target
	local aim_position, flight_time, pitch = Indicators.compute_aim_position(nil, 0, origin, unit.__head, nil, settings)

	H.assert_true(pitch ~= nil, "should have a trajectory pitch")

	local targets = {
		{
			unit = unit,
			pitch = pitch,
			flight_time = flight_time,
			solve_horizontal = 20,
			solve_height = 0,
			velocity = nil,
			aim_position = aim_position,
		},
	}

	-- Render frame: the target moves 2 m forward (> 0.1 m tolerance) -> re-solve the
	-- pitch at the new position
	unit.__head = Vector3(0, 22, 1.7)

	Indicators.refresh_positions(targets, origin)

	local refreshed = targets[1].aim_position
	local to_aim = refreshed - origin
	local horizontal = math.sqrt(to_aim.x * to_aim.x + to_aim.y * to_aim.y)
	local elevation = math.atan2(to_aim.z, horizontal)
	local expected_pitch = Ballistics.solve(22, 0)

	H.assert_near(elevation, expected_pitch, 1e-6, "refreshed pitch = fresh solution at the new position")
	H.assert_near(horizontal, (22 + 10) * math.cos(expected_pitch), 0.01, "horizontal distance = target distance + margin projected on the trajectory")

	-- Tiny move (< 0.1 m tolerance) -> no re-solve, keep the current pitch
	unit.__head = Vector3(0, 22.05, 1.7)

	Indicators.refresh_positions(targets, origin)

	H.assert_near(targets[1].pitch, expected_pitch, 1e-9, "no re-solve within the tolerance")
end)

H.case("refresh_positions: lead shifts with the target velocity", function()
	local origin = Vector3(0, 0, 1.7)
	local unit = {
		__alive = true,
		__head = Vector3(0, 20, 1.7),
	}
	local velocity = Vector3(3, 0, 0)

	-- Flat-shot pitch 0 (approximate test: vertical drop has no horizontal effect)
	local no_lead = {
		unit = unit,
		pitch = 0,
		flight_time = 0.3,
		velocity = nil,
		aim_position = Vector3(0, 30, 1.7),
	}

	Indicators.refresh_positions({ no_lead }, origin)

	local with_lead = {
		unit = unit,
		pitch = 0,
		flight_time = 0.3,
		velocity = velocity,
		lead_multiplier = 1,
		aim_position = Vector3(0, 30, 1.7),
	}

	Indicators.refresh_positions({ with_lead }, origin)

	H.assert_near(no_lead.aim_position.x, 0, 0.01, "no lead: aims along the target direction")
	H.assert_true(with_lead.aim_position.x > 0.5, "target moving along +x: refreshed aim point shifts toward +x (3 m/s x 0.3 s)")
end)

H.case("refresh_positions: dead units skipped, point-blank aims straight", function()
	local origin = Vector3(0, 0, 1.7)
	local dead_unit = {
		__alive = false,
		__head = Vector3(0, 20, 1.7),
	}
	local unchanged = Vector3(1, 1, 1)
	local targets = {
		{ unit = dead_unit, pitch = 0, flight_time = 0.3, aim_position = unchanged },
	}

	Indicators.refresh_positions(targets, origin)

	H.assert_equal(targets[1].aim_position, unchanged, "dead unit is not refreshed")

	-- Point-blank (pitch is nil): aim straight at the target
	local close_unit = {
		__alive = true,
		__head = Vector3(0, 0.3, 1.7),
	}
	local close_targets = {
		{ unit = close_unit, pitch = nil, flight_time = 0, velocity = nil, aim_position = Vector3(0, 0, 0) },
	}

	Indicators.refresh_positions(close_targets, origin)

	H.assert_near(close_targets[1].aim_position.x, 0, 1e-6)
	H.assert_near(close_targets[1].aim_position.y, 0.3, 1e-6, "point-blank aim = target position")
end)

-- Regression: live logs once reported "Vector3 expected, got userdata" at
-- Vector3Box.store because engine velocity userdata was consumed across frames.
-- Fixed: target.velocity is a scalar table and aim_position is always rebuilt via
-- Vector3(x,y,z); engine/mock objects must never flow out as-is.
H.case("scalar velocity table {x,y,z} equals the mock Vector3", function()
	local origin = Vector3(0, 0, 1.7)
	local target = Vector3(0, 20, 1.7)
	local lead_settings = {
		show_lead = true,
		lead_multiplier = 1,
	}

	local with_vector = Indicators.compute_aim_position(nil, 0, origin, target, Vector3(5, 0, 0), lead_settings)
	local with_table = Indicators.compute_aim_position(nil, 0, origin, target, { x = 5, y = 0, z = 0 }, lead_settings)

	H.assert_near(with_table.x, with_vector.x, 1e-9, "scalar table lead = vector lead")
	H.assert_near(with_table.y, with_vector.y, 1e-9)
	H.assert_near(with_table.z, with_vector.z, 1e-9)

	local unit = {
		__alive = true,
		__head = Vector3(0, 20, 1.7),
	}
	local targets = {
		{
			unit = unit,
			pitch = 0,
			flight_time = 0.3,
			velocity = { x = 3, y = 0, z = 0 },
			lead_multiplier = 1,
			aim_position = Vector3(0, 30, 1.7),
		},
	}

	Indicators.refresh_positions(targets, origin)

	H.assert_true(targets[1].aim_position.x > 0.5, "scalar velocity table: render-frame refresh also shifts toward +x")
end)

H.case("invalid engine position object: refresh skipped without crash, old aim point kept", function()
	local origin = Vector3(0, 0, 1.7)
	local bad_pos = setmetatable({}, {}) -- a "bad" object without x/y/z components
	local unit = {
		__alive = true,
		__head = bad_pos,
	}
	local kept = Vector3(0, 31, 1.7)
	local targets = {
		{ unit = unit, pitch = 0, flight_time = 0.3, velocity = nil, aim_position = kept },
	}

	Indicators.refresh_positions(targets, origin)

	H.assert_equal(targets[1].aim_position, kept, "last frame's aim point kept when the position read fails")
	H.assert_true(targets[1].aim_position ~= bad_pos, "the invalid object must not be written into aim_position")
end)

-- ---------------------------------------------------------------------------
-- update() end-to-end: incumbent hysteresis (displayed set + sort margin + edge tolerance)
-- ---------------------------------------------------------------------------

local player_unit = {
	-- Weapon template read by has_throwing_knives
	__weapons = {
		slot_grenade_ability = {
			weapon_template = { name = "zealot_throwing_knives" },
		},
	},
	__head = Vector3(0, 0, 1.7), -- broadphase query origin
}

Managers.player = {
	local_player = function()
		return {
			player_unit = player_unit,
			viewport_name = "player1",
			unit_is_alive = function()
				return true
			end,
			-- is_zealot fallback path: reads the profile when the unit_data extension is absent
			_profile = { archetype = { name = "zealot" } },
		}
	end,
}

-- Unit list returned by the broadphase scan (rewritten per case)
local broadphase_units = {}

Managers.state = {
	camera = {
		camera = function()
			return { __camera = true }
		end,
		camera_position = function()
			return Vector3(0, 0, 1.7)
		end,
		camera_rotation = function()
			return { __rotation = true }
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
}

local function make_enemy(head_pos)
	return {
		__alive = true,
		__head = head_pos,
		__breed = { name = "chaos_shock_trooper", tags = { elite = true } },
	}
end

local function with_update_settings(fn)
	local settings = mock_mod.indicator_settings
	local saved = {
		max_dots = settings.max_dots,
		show_lead = settings.show_lead,
		require_charges = settings.require_charges,
		visibility_check = settings.visibility_check,
		max_distance = settings.max_distance,
		max_angle = settings.max_angle,
	}

	settings.max_dots = 1
	settings.show_lead = false
	settings.require_charges = false
	settings.visibility_check = false
	settings.max_distance = 40
	settings.max_angle = 30

	fn()

	settings.max_dots = saved.max_dots
	settings.show_lead = saved.show_lead
	settings.require_charges = saved.require_charges
	settings.visibility_check = saved.visibility_check
	settings.max_distance = saved.max_distance
	settings.max_angle = saved.max_angle
end

H.case("update: incumbent hysteresis -- no flicker at the quota boundary", function()
	with_update_settings(function()
		Indicators.clear_cache()

		local unit_a = make_enemy(Vector3(0, 12, 1.7))
		local unit_b = make_enemy(Vector3(0, 11, 1.7))
		local unit_c = make_enemy(Vector3(0, 8, 1.7))

		-- Frame 1: only A (12 m) -> shown
		broadphase_units = { unit_a }

		local result = Indicators.update(0.11, 100)

		H.assert_equal(#result.targets, 1, "A selected")
		H.assert_equal(result.targets[1].unit, unit_a)

		-- Frame 2: B (11 m) challenges the incumbent A (effective distance 12-1.5=10.5 m)
		-- -> A keeps the slot
		broadphase_units = { unit_a, unit_b }
		result = Indicators.update(0.11, 100.11)

		H.assert_equal(result.targets[1].unit, unit_a, "gap below the incumbent margin, A keeps the slot (no flicker)")

		-- Frame 3: C (8 m) has a clear advantage -> normal takeover
		broadphase_units = { unit_a, unit_b, unit_c }
		result = Indicators.update(0.11, 100.22)

		H.assert_equal(result.targets[1].unit, unit_c, "clear challenger advantage: normal takeover")
	end)
end)

H.case("update: incumbent edge tolerance -- out-of-bounds incumbent kept, new out-of-bounds target filtered", function()
	with_update_settings(function()
		Indicators.clear_cache()

		local unit_a = make_enemy(Vector3(0, 20, 1.7))

		broadphase_units = { unit_a }

		local result = Indicators.update(0.11, 200)

		H.assert_equal(#result.targets, 1, "A is shown")

		-- A retreats to 41.5 m (> 40 m limit, within the incumbent tolerance of +2 m) -> kept
		unit_a.__head = Vector3(0, 41.5, 1.7)
		broadphase_units = { unit_a }
		result = Indicators.update(0.11, 200.11)

		H.assert_equal(#result.targets, 1, "out-of-bounds incumbent kept within tolerance")

		-- New target at 41.5 m -> filtered by the hard threshold (only the lingering A remains)
		local unit_b = make_enemy(Vector3(0, 41.5, 1.7))
		broadphase_units = { unit_b }
		result = Indicators.update(0.11, 200.22)

		H.assert_equal(#result.targets, 1, "only the lingering A remains")
		H.assert_true(result.targets[1].linger == true, "A is lingering and fading")
		H.assert_equal(result.targets[1].unit, unit_a, "new target B is not shown")
	end)
end)

H.case("update: dropping off enters linger -- faded output, recovery on reappearance, removal on expiry", function()
	with_update_settings(function()
		Indicators.clear_cache()

		local unit_a = make_enemy(Vector3(0, 20, 1.7))

		-- Shown
		test_time = 300
		broadphase_units = { unit_a }

		local result = Indicators.update(0.11, 300)

		H.assert_equal(#result.targets, 1, "A is shown")
		H.assert_nil(result.targets[1].linger, "no linger flag while shown")

		-- Drops off (moved out of scan range) -> lingered output (elapsed=0 on the drop
		-- frame, alpha still 1)
		test_time = 300.11
		broadphase_units = {}
		result = Indicators.update(0.11, 300.11)

		H.assert_equal(#result.targets, 1, "still output during the linger")
		H.assert_equal(result.targets[1].unit, unit_a)
		H.assert_true(result.targets[1].linger == true, "linger flag set")

		-- Mid-linger: alpha decays linearly with the remaining time
		test_time = 300.35
		result = Indicators.update(0.11, 300.35)

		H.assert_equal(#result.targets, 1, "still within the linger period")
		H.assert_true(result.targets[1].stack_alpha > 0.1 and result.targets[1].stack_alpha < 0.9, "fading")

		-- Reappears during the linger -> back to normal display
		test_time = 300.4
		broadphase_units = { unit_a }
		result = Indicators.update(0.11, 300.4)

		H.assert_equal(#result.targets, 1)
		H.assert_nil(result.targets[1].linger, "linger flag cleared on reappearance")

		-- Drops off again and the linger expires -> no longer output
		test_time = 300.45
		broadphase_units = {}
		result = Indicators.update(0.11, 300.45)

		H.assert_equal(#result.targets, 1, "drops off again into linger")

		test_time = 301.1
		result = Indicators.update(0.11, 301.1)

		H.assert_equal(#result.targets, 0, "no longer output after the linger expires")
	end)
end)

-- Regression: _solve_cache entries were only cleared on session switch, so dead
-- units kept their entries (and unit references) for a whole mission. update() now
-- prunes dead units every frame.
H.case("update: solve cache prunes dead units every frame", function()
	with_update_settings(function()
		Indicators.clear_cache()

		local solve_cache

		for i = 1, 50 do
			local name, value = debug.getupvalue(Indicators.clear_cache, i)

			if not name then
				break
			end

			if name == "_solve_cache" then
				solve_cache = value
				break
			end
		end

		H.assert_true(solve_cache ~= nil, "solve cache found via upvalue (test seam)")

		local unit_a = make_enemy(Vector3(0, 20, 1.7))
		broadphase_units = { unit_a }
		Indicators.update(0.11, 400)

		H.assert_true(solve_cache[unit_a] ~= nil, "live target gets a cache entry")

		unit_a.__alive = false
		broadphase_units = {}
		Indicators.update(0.11, 400.11)

		H.assert_nil(solve_cache[unit_a], "dead unit's entry pruned on the next update")
	end)
end)

print("")
