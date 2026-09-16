--[[
	Tests: core/target_filter
	- classification matches the game breeds data (is_boss / tags.elite / tags.special)
	- display conditions (category toggle / breed toggle / distance / angle)
	- sorting and limiting
]]

local H = dofile("tests/helpers.lua")
local TargetFilter = H.load("scripts/mods/ZealotKnivesHelper/core/target_filter")

print("[test_target_filter]")

H.case("classify: matches the game breed fields", function()
	H.assert_equal(TargetFilter.classify({ is_boss = true }), "boss", "is_boss -> boss")
	H.assert_equal(TargetFilter.classify({ tags = { elite = true } }), "elite", "tags.elite -> elite")
	H.assert_equal(TargetFilter.classify({ tags = { special = true } }), "special", "tags.special -> special")
	H.assert_equal(TargetFilter.classify({ tags = { minion = true } }), nil, "plain minion -> nil")
	H.assert_equal(TargetFilter.classify({}), nil, "no tags -> nil")
	H.assert_equal(TargetFilter.classify(nil), nil, "nil breed -> nil")
	-- Boss takes priority over other tags (e.g. chaos_plague_ogryn is also is_boss)
	H.assert_equal(TargetFilter.classify({ is_boss = true, tags = { elite = true } }), "boss")
end)

local base_settings = {
	category_show = { boss = true, elite = true, special = true },
	breed_hidden = {},
	max_distance = 40,
	max_angle = 30,
	hide_near = false, -- explicit: nil now counts as on (the shipped default)
}

local function make_entry(overrides)
	local entry = {
		breed_name = "cultist_gunner",
		category = "elite",
		distance = 20,
		angle_dot = 1,
	}

	for k, v in pairs(overrides or {}) do
		entry[k] = v
	end

	return entry
end

H.case("should_show: basic pass", function()
	H.assert_true(TargetFilter.should_show(make_entry(), base_settings))
end)

H.case("should_show: category toggles", function()
	local s = {
		category_show = { boss = true, elite = false, special = true },
		max_distance = base_settings.max_distance,
		max_angle = base_settings.max_angle,
	}

	H.assert_false(TargetFilter.should_show(make_entry({ category = "elite" }), s), "not shown when elite is off")
	H.assert_true(TargetFilter.should_show(make_entry({ category = "boss" }), s), "shown when boss is on")
	H.assert_false(TargetFilter.should_show(make_entry({ category = nil }), s), "no category means not shown")
end)

H.case("should_show: breed individually disabled", function()
	local s = {
		category_show = { boss = true, elite = true, special = true },
		breed_hidden = { chaos_hound = true },
		max_distance = base_settings.max_distance,
		max_angle = base_settings.max_angle,
	}

	H.assert_false(TargetFilter.should_show(make_entry({ breed_name = "chaos_hound", category = "special" }), s), "individually disabled breed is not shown")
	H.assert_true(TargetFilter.should_show(make_entry(), s), "other breeds unaffected")
end)

H.case("should_show: distance and angle", function()
	H.assert_false(TargetFilter.should_show(make_entry({ distance = 41 }), base_settings), "beyond max distance")
	H.assert_true(TargetFilter.should_show(make_entry({ distance = 40 }), base_settings), "within the boundary distance")
	H.assert_false(TargetFilter.should_show(make_entry({ angle_dot = math.cos(math.rad(31)) }), base_settings), "beyond max angle")
	H.assert_true(TargetFilter.should_show(make_entry({ angle_dot = math.cos(math.rad(30)) }), base_settings), "within the boundary angle")
	H.assert_false(TargetFilter.should_show(make_entry({ angle_dot = 0 }), base_settings), "90 degrees off the crosshair: not shown")
	H.assert_false(TargetFilter.should_show(make_entry({ angle_dot = -1 }), base_settings), "behind: not shown")
end)

H.case("should_show: incumbent edge tolerance", function()
	-- Non-incumbent: filtered out once out of bounds
	H.assert_false(TargetFilter.should_show(make_entry({ distance = 42 }), base_settings), "new target at 42 m out of bounds: not shown")
	H.assert_false(TargetFilter.should_show(make_entry({ angle_dot = math.cos(math.rad(32)) }), base_settings), "new target at 32 degrees out of bounds: not shown")
	-- Incumbent: kept within tolerance (distance +2 m / angle +2 degrees)
	H.assert_true(TargetFilter.should_show(make_entry({ distance = 42 }), base_settings, true), "incumbent at 42 m kept within tolerance")
	H.assert_false(TargetFilter.should_show(make_entry({ distance = 43 }), base_settings, true), "incumbent at 43 m beyond tolerance")
	H.assert_true(TargetFilter.should_show(make_entry({ angle_dot = math.cos(math.rad(32)) }), base_settings, true), "incumbent at 32 degrees kept within tolerance")
	H.assert_false(TargetFilter.should_show(make_entry({ angle_dot = math.cos(math.rad(34)) }), base_settings, true), "incumbent at 34 degrees beyond tolerance")
end)

H.case("should_show: hide nearby enemies (hide_near, default 10 m radius)", function()
	local s = {
		category_show = { boss = true, elite = true, special = true },
		breed_hidden = {},
		max_distance = 40,
		max_angle = 30,
		hide_near = true,
	}

	-- Feature off (base_settings sets hide_near = false): close enemies shown as before
	H.assert_true(TargetFilter.should_show(make_entry({ distance = 5 }), base_settings), "feature off: close enemy shown")
	-- Feature on, no explicit distance (nil -> default 10): inside the radius hidden,
	-- at/beyond it shown
	H.assert_false(TargetFilter.should_show(make_entry({ distance = 9.9 }), s), "inside the hide radius: not shown")
	H.assert_true(TargetFilter.should_show(make_entry({ distance = 10 }), s), "at the hide radius boundary: shown")
	H.assert_true(TargetFilter.should_show(make_entry({ distance = 12 }), s), "outside the hide radius: shown")
	-- Incumbents get the same 2 m edge tolerance as max_distance (mirrored):
	-- kept until clearly inside the radius, non-incumbents are hidden immediately
	H.assert_true(TargetFilter.should_show(make_entry({ distance = 8.5 }), s, true), "incumbent kept within tolerance")
	H.assert_false(TargetFilter.should_show(make_entry({ distance = 7.9 }), s, true), "incumbent beyond tolerance: dropped")
	H.assert_false(TargetFilter.should_show(make_entry({ distance = 8.5 }), s), "non-incumbent inside the radius: hidden")
end)

H.case("should_show: hide radius follows hide_near_distance", function()
	local s = {
		category_show = { boss = true, elite = true, special = true },
		breed_hidden = {},
		max_distance = 100,
		max_angle = 30,
		hide_near = true,
		hide_near_distance = 5,
	}

	-- Custom 5 m radius: an 8 m enemy (inside the default 10 m) is shown
	H.assert_true(TargetFilter.should_show(make_entry({ distance = 8 }), s), "outside the custom 5 m radius: shown")
	H.assert_false(TargetFilter.should_show(make_entry({ distance = 4.9 }), s), "inside the custom 5 m radius: not shown")
	H.assert_true(TargetFilter.should_show(make_entry({ distance = 5 }), s), "at the custom radius boundary: shown")
	-- Incumbent tolerance mirrors the custom radius (5 - 2 = 3 m)
	H.assert_true(TargetFilter.should_show(make_entry({ distance = 3.5 }), s, true), "incumbent kept within the mirrored tolerance")
	H.assert_false(TargetFilter.should_show(make_entry({ distance = 2.9 }), s, true), "incumbent beyond the mirrored tolerance: dropped")

	-- A wider radius hides enemies the default would show
	s.hide_near_distance = 20

	H.assert_false(TargetFilter.should_show(make_entry({ distance = 12 }), s), "inside the custom 20 m radius: not shown")
	H.assert_true(TargetFilter.should_show(make_entry({ distance = 20 }), s), "at the custom 20 m boundary: shown")
end)

H.case("sort: sort_distance takes priority over distance (incumbent margin)", function()
	local entries = {
		{ category = "elite", distance = 11 },
		{ category = "elite", distance = 12, sort_distance = 10.5 },
	}

	TargetFilter.sort(entries)

	H.assert_equal(entries[1].distance, 12, "incumbent margin (12-1.5) puts the originally farther target first")

	-- Category priority is unaffected by the margin
	local mixed = {
		{ category = "elite", distance = 20, sort_distance = 0 },
		{ category = "special", distance = 30 },
	}

	TargetFilter.sort(mixed)

	H.assert_equal(mixed[1].category, "special", "specialist priority beats any distance margin")
end)

H.case("sort: category priority and distance", function()
	local entries = {
		{ category = "special", distance = 5 },
		{ category = "elite", distance = 30 },
		{ category = "boss", distance = 40 },
		{ category = "elite", distance = 10 },
	}

	TargetFilter.sort(entries)

	H.assert_equal(entries[1].category, "special", "specialist first")
	H.assert_equal(entries[2].distance, 10, "nearest first within a category")
	H.assert_equal(entries[3].distance, 30)
	H.assert_equal(entries[4].category, "boss", "boss last")
end)

H.case("limit: caps the count", function()
	local entries = { { category = "boss" }, { category = "elite" }, { category = "special" } }

	H.assert_equal(#TargetFilter.limit(entries, 2), 2)
	H.assert_equal(#TargetFilter.limit(entries, 10), 3)
	H.assert_equal(#TargetFilter.limit(entries, 0), 0)
end)

print("")
