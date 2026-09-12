--[[
	Ballistic solver (pure functions, no engine dependency, unit-testable with luajit)

	Replicates the semi-implicit Verlet integration (with air drag) of the game source
	scripts/extension_systems/locomotion/utilities/projectile_integration.lua, reduced
	to scalars in the vertical plane containing the origin and the target:

	  - h: horizontal distance, z: height
	  - drag acceleration a = -k * |v| * v, with k = 0.5 * Cd * (pi * r^2) * rho / m
	    (source: projectile_integration_data.lua fill_integration_data)
	  - gravity is a constant -g

	Solves the launch pitch such that the trajectory passes exactly through the target
	point at horizontal distance d and height dz. Returns that pitch and the flight
	time; callers build the "world position the player should point at" from them.
]]

local Ballistics = {}

-- Default ballistic parameters of the Zealot throwing knife
-- Source: scripts/settings/projectile_locomotion/templates/grenade_projectile_locomotion_templates.lua
--   zealot_throwing_knife_projectile:
--     spawn_projectile_parameters.initial_speed = 75
--     integrator_parameters.gravity = 17.5, drag_coefficient = 0.2,
--     air_density = 0.7, mass = 0.8, radius = 0.2
local DEFAULT_PARAMS = {
	speed = 75,
	gravity = 17.5,
	drag_coefficient = 0.2,
	air_density = 0.7,
	mass = 0.8,
	radius = 0.2,
	dt = 1 / 52, -- simulation step, matches the game fixed frame (tick_rate = 52,
	             -- default_game_parameters.lua; fixed_time_step = 1/tick_rate in
	             -- state_gameplay.lua drives projectile integration one step per frame)
	max_steps = 420, -- max steps per simulation (about 7 seconds)
}

local atan2 = math.atan2 or math.atan
local sqrt = math.sqrt
local abs = math.abs
local pi = math.pi

--- Compute the air drag constant k (acceleration = -k*|v|*v)
---@param params table|nil
---@return number
function Ballistics.drag_constant(params)
	params = params or DEFAULT_PARAMS

	local cd = params.drag_coefficient
	local radius = params.radius
	local density = params.air_density
	local mass = params.mass

	if not cd or not radius or not density or not mass or mass == 0 then
		return 0
	end

	return 0.5 * cd * (pi * radius * radius) * density / mass
end

--- Vacuum (drag-free) low-arc pitch, used as the initial guess for the numeric solve
---@return number|nil pitch vacuum low-arc pitch, nil when unreachable
function Ballistics.vacuum_low_pitch(d, dz, params)
	params = params or DEFAULT_PARAMS

	local v = params.speed
	local g = params.gravity

	if d <= 0 then
		return nil
	end

	local discriminant = v * v * v * v - g * (g * d * d + 2 * dz * v * v)

	if discriminant < 0 then
		return nil
	end

	return atan2(v * v - sqrt(discriminant), g * d)
end

--[[
	Integrate one step (mirrors the game projectile_integration.lua line by line, 2D):

		new_position += dt * velocity
		new_position += dt^2 * 0.5 * acceleration          -- previous-frame acceleration
		air_drag_acceleration = -k * |velocity| * velocity -- velocity not yet updated here
		new_acceleration = air_drag + (0, -gravity)
		velocity += dt * 0.5 * (old_acceleration + new_acceleration)

	state = { h, z, vh, vz, ah, az }  (ah/az start at 0, matching the game's Vector3.zero())
]]
local function integrate_step(state, k, g, dt)
	local old_ah = state.ah
	local old_az = state.az

	state.h = state.h + dt * state.vh
	state.h = state.h + dt * dt * 0.5 * state.ah
	state.z = state.z + dt * state.vz
	state.z = state.z + dt * dt * 0.5 * state.az

	local speed = sqrt(state.vh * state.vh + state.vz * state.vz)
	state.ah = -k * speed * state.vh
	state.az = -k * speed * state.vz - g

	state.vh = state.vh + dt * 0.5 * (old_ah + state.ah)
	state.vz = state.vz + dt * 0.5 * (old_az + state.az)
end

--[[
	Launch from (0, 0) at the given pitch and simulate until the horizontal distance
	passes d. Returns the interpolated height at d and the flight time; nil when d
	is unreachable.
]]
local function simulate_height_at_distance(pitch, d, k, params)
	local dt = params.dt
	local g = params.gravity
	local v = params.speed
	local max_steps = params.max_steps

	local state = {
		h = 0,
		z = 0,
		vh = v * math.cos(pitch),
		vz = v * math.sin(pitch),
		ah = 0,
		az = 0,
	}

	local t = 0

	for _ = 1, max_steps do
		local prev_h = state.h
		local prev_z = state.z

		integrate_step(state, k, g, dt)
		t = t + dt

		if state.h >= d then
			-- Interpolate the height linearly between the previous and current point by horizontal distance
			local span = state.h - prev_h
			local alpha = span > 0 and (d - prev_h) / span or 0

			return prev_z + (state.z - prev_z) * alpha, t
		end

		-- Fell far below the launch point without reaching d, terminate early
		if state.z < -60 then
			return nil, t
		end
	end

	return nil, t
end

--[[
	Solve the hitting pitch (low arc, i.e. the solution with the smaller |pitch|).

	@param d number horizontal distance (> 0)
	@param dz number target height relative to the origin
	@param params table|nil ballistic parameters (defaults to the Zealot knife)
	@return number|nil pitch in radians, nil on failure (out of range etc.)
	@return number|nil flight_time in seconds
]]
function Ballistics.solve(d, dz, params)
	params = params or DEFAULT_PARAMS

	if not d or d <= 0.05 then
		-- Point-blank: aim straight at the target height
		local pitch_direct = d and dz and atan2(dz, math.max(d, 0.001)) or nil

		return pitch_direct, 0
	end

	local k = Ballistics.drag_constant(params)

	-- Height error of a trajectory at horizontal distance d; math.huge when unreachable
	local function evaluate(pitch)
		local z_at_d, t = simulate_height_at_distance(pitch, d, k, params)

		if z_at_d then
			return z_at_d - dz, t
		end

		return math.huge, t
	end

	-- Secant iteration seeded with the vacuum low-arc solution (usually converges in 3-6 steps)
	local x0 = Ballistics.vacuum_low_pitch(d, dz, params)

	if not x0 then
		return nil, nil
	end

	local f0, t0 = evaluate(x0)

	if f0 <= 0.02 and f0 >= -0.02 then
		return x0, t0
	end

	-- Initial step scaled roughly by the error, avoiding overshoot to the high arc
	local x1 = x0 + (f0 > 0 and -0.05 or 0.05)
	local f1, t1 = evaluate(x1)

	for _ = 1, 8 do
		if f1 <= 0.02 and f1 >= -0.02 then
			return x1, t1
		end

		-- Unreachable (math.huge) or diverging: fall through to the scan fallback
		if f1 == f0 or abs(x1 - x0) < 1e-5 then
			break
		end

		local denom = f1 - f0
		local x2

		if denom == 0 or abs(denom) == math.huge then
			break
		else
			x2 = x1 - f1 * (x1 - x0) / denom
		end

		-- A step landing outside [-pi/2 + 0.05, pi/2 - 0.05] is treated as divergence
		if x2 <= -pi / 2 + 0.05 or x2 >= pi / 2 - 0.05 then
			break
		end

		x0, f0 = x1, f1
		x1 = x2
		f1, t1 = evaluate(x1)
	end

	-- Secant did not converge: scan the low arc for a sign change, then bisect
	-- (deterministic fallback)
	local scan_low, scan_high, scan_step = -0.35, 1.25, 0.1
	local prev_x = scan_low
	local prev_f, prev_t = evaluate(prev_x)

	if prev_f == 0 then
		return prev_x, prev_t
	end

	for x = scan_low + scan_step, scan_high, scan_step do
		local f, t = evaluate(x)

		if f == 0 then
			return x, t
		end

		if prev_f * f < 0 then
			-- Take the bracket with the smaller |pitch| (low arc)
			local lo, hi = prev_x, x
			local flo, fhi = prev_f, f

			for _ = 1, 24 do
				local mid = (lo + hi) * 0.5
				local f_mid, t_mid = evaluate(mid)

				if abs(f_mid) <= 1e-4 then
					return mid, t_mid
				end

				if flo * f_mid <= 0 then
					hi = mid
					fhi = f_mid
				else
					lo = mid
					flo = f_mid
				end
			end

			if abs(flo) < abs(fhi) then
				return lo, select(2, evaluate(lo))
			end

			return hi, select(2, evaluate(hi))
		end

		prev_x = x
		prev_f = f
		prev_t = t
	end

	return nil, nil
end

return Ballistics
