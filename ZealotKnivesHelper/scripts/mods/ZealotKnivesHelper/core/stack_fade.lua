--[[
	Depth stack fading (pure functions, scalar math, unit-testable with luajit)

	When multiple markers line up along the same line of sight, markers hidden
	behind a closer marker fade out by depth difference, keeping the on-screen
	dots from overlapping into one blob.

	Input entries (sorted by ascending depth by the caller):
	  px, py, pz   marker world position
	  depth        view depth relative to the camera (dot of position and camera forward)
	  cx, cy, cz   camera position (shared by all entries)

	Output: writes entry.stack_alpha in place (0..1 multiplier).
]]

local StackFade = {}

local STACK_FADE_FACTOR = 0.9
local DEPTH_THRESHOLD = 0.05
local MAX_DEPTH_STACK = 100
local MAX_PAIR_DIST_SQ = 100
local ALIGNMENT_NEAR = 0.96
local ALIGNMENT_FAR = 0.96

local math_sqrt = math.sqrt
local math_abs = math.abs

---@param entries table entries sorted by ascending depth
function StackFade.apply(entries)
	local num = #entries

	for i = 1, num do
		entries[i].stack_alpha = 1
	end

	for i = 2, num do
		local data = entries[i]
		local depth_fade = 1

		for j = 1, i - 1 do
			local front = entries[j]

			local dx = front.px - data.px
			local dy = front.py - data.py
			local dz = front.pz - data.pz
			local dist_sq_between = dx * dx + dy * dy + dz * dz

			if dist_sq_between < MAX_PAIR_DIST_SQ then
				-- Directions of both markers relative to the camera
				local ftx = front.px - data.cx
				local fty = front.py - data.cy
				local ftz = front.pz - data.cz

				local dtx = data.px - data.cx
				local dty = data.py - data.cy
				local dtz = data.pz - data.cz

				local front_len_sq = ftx * ftx + fty * fty + ftz * ftz
				local data_len_sq = dtx * dtx + dty * dty + dtz * dtz

				if front_len_sq > 0 and data_len_sq > 0 then
					local inv_front_len = 1 / math_sqrt(front_len_sq)
					local inv_data_len = 1 / math_sqrt(data_len_sq)

					local alignment = (ftx * dtx + fty * dty + ftz * dtz)
						* (inv_front_len * inv_data_len)

					local depth_delta = data.depth - front.depth

					if depth_delta > DEPTH_THRESHOLD and depth_delta < MAX_DEPTH_STACK then
						local t = depth_delta / MAX_DEPTH_STACK
						local required_alignment = ALIGNMENT_NEAR
							+ (ALIGNMENT_FAR - ALIGNMENT_NEAR) * t

						if alignment > required_alignment then
							local scaled = 1 - (1 - STACK_FADE_FACTOR)
								* (1 - t) * (1 - t)

							depth_fade = depth_fade * scaled
						end
					end
				end
			end
		end

		if math_abs(depth_fade - 1) > 1e-4 then
			data.stack_alpha = depth_fade
		end
	end

	return entries
end

return StackFade
