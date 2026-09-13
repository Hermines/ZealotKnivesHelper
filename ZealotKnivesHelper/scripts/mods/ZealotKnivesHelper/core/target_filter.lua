--[[
	Target filtering and sorting (pure functions, no engine dependency, unit-testable
	with luajit)

	Entry (built from game units by the upper layer game/context.lua):
	  breed_name      string  breed name
	  category        string  "boss" | "elite" | "special" (from classify)
	  distance        number  distance to the player (meters)
	  angle_dot       number  cosine between crosshair and target directions
	                          (Vector3.dot(fwd, dir))

	Settings (cached from DMF settings by the main module):
	  category_show       table   { boss = bool, elite = bool, special = bool }
	  breed_hidden        table   { [breed_name] = bool } (true hides that breed individually)
	  max_distance        number  meters
	  max_angle           number  degrees
	  hide_near           bool    hide enemies closer than HIDE_NEAR_DISTANCE (fixed 10 m;
	                              nil counts as on, the shipped default)
]]

local TargetFilter = {}

local CATEGORY_PRIORITY = {
	boss = 1,
	elite = 2,
	special = 3,
}

-- Display hysteresis edge tolerance: a target already shown only drops off beyond
-- (max_distance + tolerance) / (max_angle + tolerance), so boundary targets do not
-- flicker in and out of the display list on small movements or view changes
local DISPLAY_EDGE_TOLERANCE_ANGLE = 2
local DISPLAY_EDGE_TOLERANCE_DISTANCE = 2

-- Hide-nearby radius (meters): with hide_near on, enemies closer than this are not
-- indicated (fixed by design; at point-blank range the dots sit on top of the enemy)
local HIDE_NEAR_DISTANCE = 10

--- Classify breed data; returns a category name only for boss/elite/specialist, else nil
---@param breed table game breed data (is_boss / tags.elite / tags.special)
---@return string|nil
function TargetFilter.classify(breed)
	if not breed then
		return nil
	end

	if breed.is_boss then
		return "boss"
	end

	local tags = breed.tags

	if tags then
		if tags.elite then
			return "elite"
		elseif tags.special then
			return "special"
		end
	end

	return nil
end

--- Whether a single enemy passes the display conditions
---@param entry table
---@param settings table
---@param is_incumbent boolean|nil target already shown last frame (gets the edge tolerance)
---@return boolean
function TargetFilter.should_show(entry, settings, is_incumbent)
	if not entry or not entry.category then
		return false
	end

	if not settings.category_show or not settings.category_show[entry.category] then
		return false
	end

	if settings.breed_hidden and settings.breed_hidden[entry.breed_name] then
		return false
	end

	local hide_near_distance = settings.hide_near ~= false and HIDE_NEAR_DISTANCE or nil

	if hide_near_distance then
		if is_incumbent then
			-- Incumbents only drop once clearly inside the hide radius (same anti-flicker
			-- tolerance as max_distance below)
			hide_near_distance = hide_near_distance - DISPLAY_EDGE_TOLERANCE_DISTANCE
		end

		if entry.distance < hide_near_distance then
			return false
		end
	end

	local max_distance = settings.max_distance

	if is_incumbent then
		max_distance = max_distance + DISPLAY_EDGE_TOLERANCE_DISTANCE
	end

	if entry.distance > max_distance then
		return false
	end

	local max_angle = settings.max_angle

	if is_incumbent then
		max_angle = max_angle + DISPLAY_EDGE_TOLERANCE_ANGLE
	end

	local min_dot = math.cos(math.rad(max_angle))

	if entry.angle_dot < min_dot then
		return false
	end

	return true
end

--- Sort by category priority (specialist > elite > boss) then distance (nearest
--- first), in place.
--- Entries may carry sort_distance (effective distance for incumbent hysteresis);
--- falls back to distance when missing
---@param entries table
function TargetFilter.sort(entries)
	table.sort(entries, function(a, b)
		local pa = CATEGORY_PRIORITY[a.category] or 0
		local pb = CATEGORY_PRIORITY[b.category] or 0

		if pa ~= pb then
			return pa > pb
		end

		local da = a.sort_distance or a.distance
		local db = b.sort_distance or b.distance

		return da < db
	end)
end

--- Keep the first n entries
---@param entries table
---@param n number
---@return table
function TargetFilter.limit(entries, n)
	local result = {}

	for i = 1, math.min(n or #entries, #entries) do
		result[#result + 1] = entries[i]
	end

	return result
end

return TargetFilter
