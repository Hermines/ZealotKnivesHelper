--[[
	Tests: core/stack_fade
	- single entry / non-occluding pair: no fade
	- same line of sight, the nearer occludes the farther: the farther fades by depth
	  difference
	- no fade when the depth difference is too large (past MAX_DEPTH_STACK)
	- marker pairs far apart in the world do not affect each other
]]

local H = dofile("tests/helpers.lua")
local StackFade = H.load("scripts/mods/ZealotKnivesHelper/core/stack_fade")

print("[test_stack_fade]")

--- Build test entries: camera at the origin, forward +y
local function make_entries(list)
	local entries = {}

	for i, spec in ipairs(list) do
		entries[i] = {
			px = spec.px or 0,
			py = spec.py or 0,
			pz = spec.pz or 0,
			depth = spec.depth or (spec.py or 0),
			cx = 0,
			cy = 0,
			cz = 0,
		}
	end

	return entries
end

H.case("single entry: no fade", function()
	local entries = make_entries({ { py = 10 } })

	StackFade.apply(entries)

	H.assert_near(entries[1].stack_alpha, 1, 1e-6)
end)

H.case("non-occluding pair (not on the same sight line): no fade", function()
	-- Two enemies both at 20 m but 10 m apart laterally: no overlap on screen
	local entries = make_entries({
		{ py = 20, px = -5 },
		{ py = 20, px = 5 },
	})

	StackFade.apply(entries)

	H.assert_near(entries[1].stack_alpha, 1, 1e-6)
	H.assert_near(entries[2].stack_alpha, 1, 1e-6)
end)

H.case("marker behind on the same sight line fades", function()
	-- Two enemies on the same sight line: front at 20 m, back at 20.5 m (depth delta
	-- 0.5 m, below MAX_DEPTH_STACK)
	local entries = make_entries({
		{ py = 20 },
		{ py = 20.5 },
	})

	StackFade.apply(entries)

	H.assert_near(entries[1].stack_alpha, 1, 1e-6, "front marker unaffected")
	H.assert_true(entries[2].stack_alpha < 1 and entries[2].stack_alpha >= 0.89, "back marker faded (near the 0.9 factor)")

	-- Expected formula: scaled = 1 - 0.1*(1-t)^2, t = delta/100
	local t = 0.5 / 100
	local expected = 1 - 0.1 * (1 - t) * (1 - t)

	H.assert_near(entries[2].stack_alpha, expected, 1e-9, "fade factor matches the expected formula")
end)

H.case("no fade when the depth delta exceeds the cap", function()
	-- A marker 150 m behind does not stack with the front one at 20 m
	local entries = make_entries({
		{ py = 20 },
		{ py = 170 },
	})

	StackFade.apply(entries)

	H.assert_near(entries[2].stack_alpha, 1, 1e-6)
end)

H.case("markers far apart in the world do not affect each other", function()
	-- Small depth delta but world lateral distance exceeds sqrt(MAX_PAIR_DIST_SQ) (10 m)
	local entries = make_entries({
		{ py = 20 },
		{ py = 20.5, px = 50 },
	})

	StackFade.apply(entries)

	H.assert_near(entries[2].stack_alpha, 1, 1e-6)
end)

H.case("multi-level stack fade multiplies", function()
	-- Three enemies in a line, 0.5 m apart; the third is occluded by both ahead, factors multiply
	local entries = make_entries({
		{ py = 20 },
		{ py = 20.5 },
		{ py = 21 },
	})

	StackFade.apply(entries)

	local function factor(delta)
		local t = delta / 100

		return 1 - 0.1 * (1 - t) * (1 - t)
	end

	H.assert_near(entries[2].stack_alpha, factor(0.5), 1e-9, "second: occluded by the first only")
	H.assert_near(entries[3].stack_alpha, factor(1.0) * factor(0.5), 1e-9, "third: occluded by both ahead, factors multiply")
end)

H.case("stack_alpha reset before repeated calls", function()
	local entries = make_entries({
		{ py = 20 },
		{ py = 20.5 },
	})

	StackFade.apply(entries)

	H.assert_true(entries[2].stack_alpha < 1)

	-- Move the second one to a non-occluding position and recompute: should return to 1
	entries[2].py = 20
	entries[2].depth = 20

	StackFade.apply(entries)

	H.assert_near(entries[2].stack_alpha, 1, 1e-6, "stack_alpha is reset before each apply round")
end)

print("")
