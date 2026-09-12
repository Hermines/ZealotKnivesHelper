--[[
	Test helpers: assertions, a vector mock, and an independent replica of the game
	integrator (for cross-validation).

	Multiple test files dofile this file; a global singleton shares the counter state.
]]

local M = _G.__ZKH_TEST_HELPERS

if M then
	return M
end

M = {}
_G.__ZKH_TEST_HELPERS = M

-- ============================================================================
-- Path utilities
-- ============================================================================
local here = arg and arg[0] or "tests/run.lua"
M.test_root = string.match(here, "^(.*)[/\\][^/\\]*$") or "."
M.mod_root = M.test_root .. "/.."

--- Load a module by its in-mod relative path (same path convention as the game's
--- io_dofile, relative to the repo root)
function M.load(path)
	local file = M.mod_root .. "/" .. path .. ".lua"
	local chunk, err = loadfile(file)

	if not chunk then
		error("failed to load module: " .. file .. " (" .. tostring(err) .. ")", 2)
	end

	return chunk()
end

-- ============================================================================
-- Counters and assertions
-- ============================================================================
local passed, failed = 0, 0

function M.report()
	return passed, failed
end

local function ok()
	passed = passed + 1
end

function M.fail(msg)
	failed = failed + 1
	print("  [FAIL] " .. tostring(msg))
end

function M.assert_true(value, msg)
	if value then
		ok()
	else
		M.fail(msg or "expected true, got " .. tostring(value))
	end
end

function M.assert_false(value, msg)
	if not value then
		ok()
	else
		M.fail(msg or "expected false, got " .. tostring(value))
	end
end

function M.assert_nil(value, msg)
	if value == nil then
		ok()
	else
		M.fail(msg or "expected nil, got " .. tostring(value))
	end
end

function M.assert_equal(actual, expected, msg)
	if actual == expected then
		ok()
	else
		M.fail(msg or string.format("expected %s, got %s", tostring(expected), tostring(actual)))
	end
end

function M.assert_near(actual, expected, eps, msg)
	if type(actual) ~= "number" then
		M.fail(msg or "expected a number, got " .. tostring(actual))
		return
	end

	if math.abs(actual - expected) <= eps then
		ok()
	else
		M.fail(msg or string.format("expected %s +/- %s, got %s", tostring(expected), tostring(eps), tostring(actual)))
	end
end

--- Run a batch of assertions under one case description, easing output triage
function M.case(name, fn)
	print("  - " .. name)
	local before_failed = failed
	fn()

	if failed == before_failed then
		passed = passed + 1
	end
end

-- ============================================================================
-- Vector3 mock (plain tables + metamethods, matching the engine Vector3 call surface)
-- ============================================================================
local vmt

local function new_vector3(x, y, z)
	return setmetatable({ x = x or 0, y = y or 0, z = z or 0 }, vmt)
end

vmt = {
	__add = function(a, b)
		return new_vector3(a.x + b.x, a.y + b.y, a.z + b.z)
	end,
	__sub = function(a, b)
		return new_vector3(a.x - b.x, a.y - b.y, a.z - b.z)
	end,
	__mul = function(a, b)
		if type(a) == "number" then
			return new_vector3(a * b.x, a * b.y, a * b.z)
		end

		return new_vector3(a.x * b, a.y * b, a.z * b)
	end,
	__unm = function(a)
		return new_vector3(-a.x, -a.y, -a.z)
	end,
}

function M.make_vector3_mock()
	-- Callable table: Vector3(x, y, z) construction plus static methods (the engine
	-- Vector3 call surface)
	local Vector3 = setmetatable({}, {
		__call = function(_, x, y, z)
			return new_vector3(x, y, z)
		end,
	})

	Vector3.zero = function()
		return new_vector3(0, 0, 0)
	end
	Vector3.length = function(v)
		return math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)
	end
	Vector3.length_squared = function(v)
		return v.x * v.x + v.y * v.y + v.z * v.z
	end
	Vector3.normalize = function(v)
		local len = math.sqrt(v.x * v.x + v.y * v.y + v.z * v.z)

		if len < 1e-9 then
			return new_vector3(0, 0, 0)
		end

		return new_vector3(v.x / len, v.y / len, v.z / len)
	end
	Vector3.dot = function(a, b)
		return a.x * b.x + a.y * b.y + a.z * b.z
	end

	return Vector3
end

-- ============================================================================
-- Independent replica of the game ballistic integrator (cross-validates
-- core/ballistics)
-- 2D reduction mirroring the Darktide source projectile_integration.lua
-- integrate_position step by step
-- ============================================================================
function M.integrate_flat(params, pitch, max_time)
	local k = params.k
	local g = params.gravity
	local dt = params.dt
	local v = params.speed

	local h, z = 0, 0
	local vh, vz = v * math.cos(pitch), v * math.sin(pitch)
	local ah, az = 0, 0
	local t = 0

	local points = {
		{ h = 0, z = 0, t = 0 },
	}

	local steps = max_time and math.ceil(max_time / dt) or 1000

	for _ = 1, steps do
		local old_ah, old_az = ah, az

		h = h + dt * vh
		h = h + dt * dt * 0.5 * ah
		z = z + dt * vz
		z = z + dt * dt * 0.5 * az

		local speed = math.sqrt(vh * vh + vz * vz)
		ah = -k * speed * vh
		az = -k * speed * vz - g

		vh = vh + dt * 0.5 * (old_ah + ah)
		vz = vz + dt * 0.5 * (old_az + az)
		t = t + dt

		points[#points + 1] = {
			h = h,
			z = z,
			t = t,
		}
	end

	return points
end

--- Trajectory height at horizontal distance d (linear interpolation)
function M.height_at_distance(points, d)
	for i = 2, #points do
		local prev, curr = points[i - 1], points[i]

		if curr.h >= d then
			local span = curr.h - prev.h

			if span <= 0 then
				return curr.z
			end

			return prev.z + (curr.z - prev.z) * ((d - prev.h) / span)
		end
	end

	return nil
end

return M
