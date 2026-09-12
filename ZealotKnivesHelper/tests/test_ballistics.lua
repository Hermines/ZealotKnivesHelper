--[[
	Tests: core/ballistics
	- drag constant matches the game formula
	- correctness of the vacuum solution as the initial guess
	- the solved pitch makes the trajectory actually hit the target (cross-validated
	  with the independent replica integrator)
	- sane flight times
	- determinism
]]

local H = require("tests.helpers") or dofile("tests/helpers.lua")
local Ballistics = H.load("scripts/mods/ZealotKnivesHelper/core/ballistics")

print("[test_ballistics]")

-- Independent integrator parameters (derived from the default ballistic parameters)
local P = {
	k = Ballistics.drag_constant(),
	gravity = 17.5,
	dt = 1 / 52, -- matches the game fixed frame / the solver's dt
	speed = 75,
}

H.case("drag constant k = 0.5*Cd*(pi*r^2)*rho/m", function()
	-- 0.5 * 0.2 * (pi * 0.2^2) * 0.7 / 0.8
	H.assert_near(P.k, 0.010995574, 1e-8, "default drag constant")
	H.assert_equal(Ballistics.drag_constant({}), 0, "k = 0 when parameter fields are missing (conservatively drag-free)")
	H.assert_equal(Ballistics.drag_constant({ mass = 0 }), 0, "k = 0 when mass is 0")
end)

H.case("vacuum low-arc solution", function()
	local vacuum_pitch = Ballistics.vacuum_low_pitch(20, 0, {
		speed = 75,
		gravity = 17.5,
	})
	-- tan(theta) = (v^2 - sqrt(v^4 - g^2*d^2)) / (g*d)
	local v, g, d = 75, 17.5, 20
	local expected = math.atan2(v * v - math.sqrt(v * v * v * v - g * g * d * d), g * d)

	H.assert_near(vacuum_pitch, expected, 1e-9)
	H.assert_nil(Ballistics.vacuum_low_pitch(400, 0, { speed = 75, gravity = 17.5 }), "nil beyond vacuum range")
	H.assert_near(
		Ballistics.vacuum_low_pitch(10, 10, { speed = 75, gravity = 17.5 }),
		math.atan2(75 * 75 - math.sqrt(75 ^ 4 - 17.5 * (17.5 * 100 + 2 * 10 * 75 * 75)), 17.5 * 10),
		1e-9,
		"vacuum solution for 10 m up")
end)

local function verify_hit(d, dz, label)
	local pitch, flight_time = Ballistics.solve(d, dz)

	if not pitch then
		H.fail(label .. ": solve failed (should be reachable)")
		return
	end

	-- Replay the trajectory with the independent integrator and check that the height
	-- at d hits dz
	local points = H.integrate_flat(P, pitch)
	local z_at_d = H.height_at_distance(points, d)

	H.assert_near(z_at_d, dz, 0.1, label .. ": hit height error < 0.1 m")

	-- Flight time: interpolate the moment the trajectory passes d
	local flight_from_points

	for i = 2, #points do
		if points[i].h >= d then
			flight_from_points = points[i].t
			break
		end
	end

	H.assert_near(flight_time, flight_from_points, 0.05, label .. ": flight time matches the integration")
	H.assert_true(flight_time > 0 and flight_time < 10, label .. ": flight time in a sane range")
end

H.case("flat shot (dz = 0)", function()
	verify_hit(5, 0, "5 m")
	verify_hit(20, 0, "20 m")
	verify_hit(40, 0, "40 m")
end)

H.case("upward and downward shots", function()
	verify_hit(15, 5, "15 m, 5 m up")
	verify_hit(25, -4, "25 m, 4 m down")
	verify_hit(30, 8, "30 m, 8 m up (close-range upward)")
	verify_hit(35, -10, "35 m, 10 m down (downward)")
end)

H.case("long range", function()
	verify_hit(60, 0, "60 m")
	verify_hit(90, 0, "90 m")
end)

H.case("point-blank direct aim", function()
	local pitch, flight = Ballistics.solve(0.02, 0.5)

	H.assert_near(pitch, math.atan2(0.5, 0.02), 1e-6, "point-blank pitch = atan2(dz, d)")
	H.assert_equal(flight, 0, "point-blank flight time is 0")
end)

H.case("determinism: same input, same output", function()
	local a1, f1 = Ballistics.solve(25, 3)
	local a2, f2 = Ballistics.solve(25, 3)

	H.assert_equal(a1, a2)
	H.assert_equal(f1, f2)
end)

H.case("physical sanity: drag makes flight time longer than vacuum", function()
	local d = 30
	local pitch, flight_time = Ballistics.solve(d, 0)

	-- Vacuum flat shot: t = d / (v * cos(pitch_vacuum)); loose upper bound using the
	-- vacuum muzzle speed
	local vacuum_flight = d / P.speed

	H.assert_true(flight_time > vacuum_flight, "with drag, flight time should exceed the vacuum straight-line time")
end)

H.case("custom parameters (zero drag vs vacuum solution)", function()
	-- With zero drag, the solution should match the vacuum one (within integration
	-- discretization error)
	local no_drag = {
		speed = 75,
		gravity = 17.5,
		drag_coefficient = 0,
		dt = 1 / 52,
		max_steps = 420,
	}
	local d, dz = 20, 1
	local pitch = Ballistics.solve(d, dz, no_drag)
	local expected = Ballistics.vacuum_low_pitch(d, dz, no_drag)

	H.assert_near(pitch, expected, 5e-3, "zero-drag solution ~= vacuum solution (within discretization error)")
end)

print("")
