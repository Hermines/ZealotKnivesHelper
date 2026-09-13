--[[
	Main-path crash guard (game-side compatibility patch, installed at load)

	The game's main-path progress update hard-crashes when a player unit is
	replaced mid-run and its first frames find no main-path group index:
	PathTypeLinear.update_progress_on_path falls through the position query,
	the navmesh position, the previous-frame entry and the teammate fallbacks,
	then does node_index_by_nav_group_index(nil) + 1 ("attempt to perform
	arithmetic on local 'start_index'"). Vanilla never hits this (in-run
	respawns only happen at beacons on the main path), but mods that replace
	the player unit mid-run -- e.g. InstantCharacterChange hot-switching
	characters in beacon-less maps (shooting range, psykhanium), where the
	respawn flow itself logs "No respawn beacon found" -- land exactly in that
	window.

	This mod does not touch main_path; it carries the guard because it is part
	of the mod setup that triggers the race. The pcall chain-hook skips the
	single progress frame when the race fires (downstream consumers keep last
	frame's progress values; the fresh unit registers itself within a few
	frames) and logs throttled. Zero effect while no error fires. Inactive
	while the mod is disabled (DMF disable_all_hooks).
]]

local mod = get_mod("ZealotKnivesHelper")

-- Boot-time simulation modules are requirable at mod-load time; the pcall
-- keeps a future load-order change from breaking this mod's load (the guard
-- is simply not installed then, surfaced via mod:error).
local ok_path_type, PathTypeLinear = pcall(require, "scripts/managers/main_path/path_types/path_type_linear")

if ok_path_type and PathTypeLinear and PathTypeLinear.update_progress_on_path then
	local guard_call_count = 0
	local guard_last_logged_call = -1000

	mod:hook(PathTypeLinear, "update_progress_on_path", function(next_fn, self, ...)
		guard_call_count = guard_call_count + 1

		local ok_call, a, b, c = pcall(next_fn, self, ...)

		if ok_call then
			return a, b, c
		end

		if guard_call_count - guard_last_logged_call >= 600 then
			guard_last_logged_call = guard_call_count
			mod:echo("[ZealotKnivesHelper] main-path race guard: skipped one progress update for a respawning player unit (%s)", tostring(a))
		end
	end)
else
	mod:error("main-path race guard not installed: path_type_linear.lua did not load")
end
