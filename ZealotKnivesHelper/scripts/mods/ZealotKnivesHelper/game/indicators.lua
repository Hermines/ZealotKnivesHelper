--[[
	Indicator main computation (game side)

	Every fixed frame:
	  1. take the scanned enemy entries from Context (broadphase spatial query)
	  2. filter via core/target_filter (category/breed/distance/angle, incumbents get
	     edge tolerance)
	  3. solve the trajectory pitch via core/ballistics (with air drag, per-unit cache)
	     - optional lead prediction from target velocity (2 iterations)
	  4. optional visibility check (dual sample-point raycasts)
	  5. sort (specialist > elite > boss, nearest first, incumbents get a distance
	     margin), cap the count
	  6. depth stack fading (core/stack_fade): markers behind a closer marker on the
	     same sight line fade out
	  7. targets that drop off the list linger for LINGER_TIME: kept in the output and
	     faded linearly (marker_sync reuses their markers, avoiding delete/recreate
	     flicker)
	  8. output the world-space target list for draw/marker_sync to sync as engine
	     world markers (projection/frustum/distance scaling are all
	     handled by the engine)
]]

local mod = get_mod("ZealotKnivesHelper")

local Context = mod:io_dofile("ZealotKnivesHelper/scripts/mods/ZealotKnivesHelper/game/context")
local Ballistics = mod:io_dofile("ZealotKnivesHelper/scripts/mods/ZealotKnivesHelper/core/ballistics")
local TargetFilter = mod:io_dofile("ZealotKnivesHelper/scripts/mods/ZealotKnivesHelper/core/target_filter")
local BreedConfig = mod:io_dofile("ZealotKnivesHelper/scripts/mods/ZealotKnivesHelper/core/breed_config")
local StackFade = mod:io_dofile("ZealotKnivesHelper/scripts/mods/ZealotKnivesHelper/core/stack_fade")

local Managers = Managers
local ScriptUnit = ScriptUnit
local Unit = Unit
local Vector3 = Vector3
local Quaternion = Quaternion
local math_cos = math.cos
local math_sin = math.sin
local math_sqrt = math.sqrt
local math_abs = math.abs
local pairs = pairs
local table_sort = table.sort

-- Per-unit ballistic solve cache lifetime (seconds)
local SOLVE_CACHE_INTERVAL = 0.15
-- Cache hit tolerance (meters); re-solve immediately once the target moves past it
local SOLVE_CACHE_MOVE_TOLERANCE = 0.3
-- Extension margin (meters) of the aim point along the trajectory direction, keeping
-- the aim point stable
local AIM_POINT_EXTENSION = 10
-- Incumbent distance margin (meters): targets shown last frame sort within their
-- category using this effective distance; a challenger must beat it by the margin to
-- take over, preventing dot flicker at the quota boundary
local INCUMBENT_DISTANCE_MARGIN = 1.5
-- Linger time (seconds) for markers that drop off the list: the target stays in the
-- output and fades linearly over the remaining time, letting marker_sync reuse the
-- same marker (follows the enemy, no delete/recreate flicker)
local LINGER_TIME = 0.5
-- Render-frame re-solve move tolerance (meters): during render-frame refresh, re-solve
-- the pitch immediately when the target has moved more than this since the last solve,
-- removing the stair-stepping of the fixed-frame solve cache on fast-moving targets
-- (pure input-delta check, no shared clock with the fixed-frame solve cache)
local RENDER_SOLVE_MOVE_TOLERANCE = 0.1

local _solve_cache = {} -- [unit] = {pitch, flight_time, t, horizontal, height}
local _displayed = {} -- [unit] = target table, last frame's final display list (the "incumbent" state for hysteresis)
local _displayed_swap = {} -- rebuild buffer for _displayed (swapped every frame)
local _linger = {} -- [unit] = {target = target table captured at drop time, drop_t = drop moment}
local _last_debug_count = -1
-- Scratch entry for TargetFilter.should_show, rewritten per enemy in the update
-- loop. should_show consumes it synchronously and never retains it, so one shared
-- table avoids allocating a new one per enemy per fixed frame.
local _filter_entry = {}

-- Smoothness probe (debug_mode): every 5s, counts render-frame refreshes and the
-- actual head-bone position changes of the first target. head_moves ~= the
-- fixed-frame rate while refresh is far higher means bone reads are only
-- fixed-frame fresh (extrapolation needed); both matching means reads are
-- render-frame fresh.
local _probe_t, _probe_frames, _probe_moves, _probe_last = nil, 0, 0, nil

--- Read the three components of a vector object (a standalone function so pcall
--- calls do not allocate a closure each time)
local function vector_xyz(v)
	return v.x, v.y, v.z
end

-- Debug: pipeline stage tracking (with debug_mode, logs the current stage every 5s)
local _debug_stage, _debug_stage_t = nil, 0

local function debug_stage(stage, main_time)
	local settings = mod.settings

	if not settings or not settings.debug_mode then
		return
	end

	if stage == _debug_stage and main_time - _debug_stage_t < 5 then
		return
	end

	_debug_stage = stage
	_debug_stage_t = main_time
	mod:debug_print("update stage:", stage)
end

--- Clear the solve caches (session switch / mod disable)
local function clear_cache()
	for unit in pairs(_solve_cache) do
		_solve_cache[unit] = nil
	end

	for unit in pairs(_displayed) do
		_displayed[unit] = nil
	end

	for unit in pairs(_displayed_swap) do
		_displayed_swap[unit] = nil
	end

	for unit in pairs(_linger) do
		_linger[unit] = nil
	end
end

--- Ballistic solve with cache (solves directly without caching when unit is nil)
local function cached_solve(unit, horizontal, height, now)
	local cached = unit and _solve_cache[unit] or nil

	if cached and now - cached.t < SOLVE_CACHE_INTERVAL
		and math_abs(cached.horizontal - horizontal) < SOLVE_CACHE_MOVE_TOLERANCE
		and math_abs(cached.height - height) < SOLVE_CACHE_MOVE_TOLERANCE then
		return cached.pitch, cached.flight_time
	end

	local pitch, flight_time = Ballistics.solve(horizontal, height)

	if unit then
		_solve_cache[unit] = {
			pitch = pitch,
			flight_time = flight_time,
			t = now,
			horizontal = horizontal,
			height = height,
		}
	end

	return pitch, flight_time
end

--- Safely extract scalar components from a vector object (nil on invalid objects
--- or missing components)
local function extract_xyz(v)
	local ok, x, y, z = pcall(vector_xyz, v)

	if ok and type(x) == "number" and type(y) == "number" and type(z) == "number" then
		return x, y, z
	end

	return nil
end

--- Aim point of the target: head bone, falling back to the root position raised by
--- 1.5 m.
--- Always returns a freshly rebuilt Vector3 from scalars (engine userdata never
--- flows out as-is); nil when reads fail
local function get_aim_target_position(unit)
	local x, y, z

	if Unit.has_node(unit, "j_head") then
		local ok, head = pcall(Unit.world_position, unit, Unit.node(unit, "j_head"))

		if ok and head then
			x, y, z = extract_xyz(head)
		end
	end

	if not x then
		local ok, root = pcall(Unit.world_position, unit, 1)

		if ok and root then
			local rx, ry, rz = extract_xyz(root)

			if rx then
				x, y, z = rx, ry, rz + 1.5
			end
		end
	end

	if not x then
		return nil
	end

	return Vector3(x, y, z)
end

--- Get the target's current velocity (nil when not moving or the locomotion
--- extension is missing).
--- The engine current_velocity result is split into a scalar table {x,y,z} before
--- being stored on the target: the value crosses the fixed-frame -> render-frame
--- boundary, and engine vector userdata can become an object that Vector3Box.store
--- rejects the instant the unit is destroyed or reset (live logs once reported
--- "bad argument #2 to 'store' (Vector3 expected, got userdata)")
local function get_target_velocity(unit)
	local loc_ext = ScriptUnit.has_extension(unit, "locomotion_system")
		and ScriptUnit.extension(unit, "locomotion_system")

	if not loc_ext then
		return nil
	end

	local ok, vel = pcall(loc_ext.current_velocity, loc_ext)

	if not ok or not vel then
		return nil
	end

	local vx, vy, vz = extract_xyz(vel)

	if not vx then
		return nil
	end

	if vx * vx + vy * vy + vz * vz > 0.01 then
		return {
			x = vx,
			y = vy,
			z = vz,
		}
	end

	return nil
end

--[[
	Compute the aim world position (core computation seam; tests mock Vector3 with
	plain tables).

	The returned aim_position is always a freshly rebuilt Vector3 -- only numbers are
	fed to the Vector3() constructor, so downstream Vector3Box.store always receives
	a real engine Vector3.

	@return Vector3|nil aim_position world position the player crosshair should point at
	@return number|nil flight_time flight time of the final solution
	@return number|nil pitch trajectory pitch (reused by render-frame refresh; nil for point-blank aim)
	@return number|nil solve_horizontal horizontal distance of the final solve (render-frame re-solve criterion)
	@return number|nil solve_height height difference of the final solve
]]
local function compute_aim_position(unit, now, origin, target_pos, target_velocity, settings)
	local to_target = target_pos - origin

	if Vector3.length_squared(to_target) < 1e-6 then
		return nil, nil, nil, nil, nil
	end

	local aim_target = target_pos

	-- Lead: estimate the flight time from the current position, predict the future
	-- position, then re-solve (2 iterations)
	-- (target_velocity is a scalar table {x,y,z}, see get_target_velocity)
	if settings.show_lead ~= false and target_velocity then
		local multiplier = settings.lead_multiplier or 1

		for _ = 1, 2 do
			local to_aim = aim_target - origin

			if Vector3.length_squared(to_aim) < 1e-6 then
				return nil, nil, nil, nil, nil
			end

			local _, flight_time = cached_solve(unit, math_sqrt(to_aim.x * to_aim.x + to_aim.y * to_aim.y), to_aim.z, now)

			if not flight_time then
				break
			end

			local lead_dt = flight_time * multiplier

			aim_target = Vector3(
				target_pos.x + target_velocity.x * lead_dt,
				target_pos.y + target_velocity.y * lead_dt,
				target_pos.z + target_velocity.z * lead_dt
			)
		end
	end

	local to_aim = aim_target - origin
	local horizontal = math_sqrt(to_aim.x * to_aim.x + to_aim.y * to_aim.y)
	local height = to_aim.z

	-- Point-blank: aim straight at the target
	if horizontal < 0.05 then
		return Vector3(aim_target.x, aim_target.y, aim_target.z), 0, nil, nil, nil
	end

	local pitch, flight_time = cached_solve(unit, horizontal, height, now)

	if not pitch then
		return nil, nil, nil, nil, nil
	end

	-- Trajectory direction = horizontal aim * cos(pitch) + up * sin(pitch)
	local hd = Vector3.normalize(Vector3(to_aim.x, to_aim.y, 0))
	local aim_dir = hd * math_cos(pitch) + Vector3(0, 0, 1) * math_sin(pitch)
	local dist = Vector3.length(to_aim) + AIM_POINT_EXTENSION

	return Vector3(
		origin.x + aim_dir.x * dist,
		origin.y + aim_dir.y * dist,
		origin.z + aim_dir.z * dist
	), flight_time, pitch, horizontal, height
end

--[[
	Per-frame computation entry, called by the main module in
	PlayerUnitFirstPersonExtension.fixed_update.

	@param dt number
	@param t number extension-system fixed-step time (only for monotonic solve-cache timing)
	@return table {t = "main" clock time, targets = {{unit, breed_name, category,
	        aim_position, distance, color, size, visible, stack_alpha}, ...}}

	Note: t uses the "main" clock, matching the HUD draw chain. The extension fixed
	frame's t is accumulated fixed-step time on a different clock basis and must not
	be mixed with it.
]]
local function update(dt, t)
	local time_manager = Managers.time
	local main_time = time_manager and time_manager:has_timer("main") and time_manager:time("main") or t

	local result = {
		t = main_time,
		targets = {},
	}

	local settings = mod.indicator_settings

	-- (== false rather than "not": nil counts as on, same nil direction as the
	-- rebuild fallback)
	if not settings or settings.toggle_mod == false then
		debug_stage("toggle_mod=off", main_time)

		return result
	end

	-- Display gate: "Always Show" off and the force-show hold key not pressed. The
	-- empty result makes marker_sync remove all of the mod's markers (releasing the
	-- hold key or toggling back on re-runs the full pipeline immediately)
	if settings.always_show == false and not settings.force_show then
		debug_stage("always_show=off", main_time)

		return result
	end

	local player = Context.get_local_player()

	if not player then
		debug_stage("no local player", main_time)

		return result
	end

	if not Context.is_zealot(player) then
		debug_stage("archetype is not zealot", main_time)

		return result
	end

	local player_unit = player.player_unit

	if not Context.has_throwing_knives(player_unit) then
		debug_stage("throwing knives not equipped", main_time)

		return result
	end

	if settings.require_charges ~= false and Context.get_knives_count(player_unit) <= 0 then
		debug_stage("no knives remaining", main_time)

		return result
	end

	Context.update_enemies(dt)

	-- Prune solve-cache entries of dead units; killed enemies would otherwise keep
	-- their entries (and unit references) until the session switch (same hygiene as
	-- the visibility cache in context.lua)
	for unit in pairs(_solve_cache) do
		if not Unit.alive(unit) then
			_solve_cache[unit] = nil
		end
	end

	local camera = Context.get_camera(player)

	if not camera then
		debug_stage("camera unavailable", main_time)

		return result
	end

	local camera_manager = Managers.state and Managers.state.camera
	local viewport_name = player.viewport_name
	local camera_pos = camera_manager and camera_manager:camera_position(viewport_name)
	local camera_rotation = camera_manager and camera_manager:camera_rotation(viewport_name)

	if not camera_pos or not camera_rotation then
		debug_stage("camera unavailable", main_time)

		return result
	end

	local camera_fwd = Quaternion.forward(camera_rotation)
	local origin = Context.get_first_person_position(player_unit) or camera_pos
	local enemies = Context.enemies()
	local enemy_count = Context.enemy_count()
	local targets = result.targets

	for i = 1, enemy_count do
		local entry = enemies[i]
		local unit = entry and entry.unit

		if unit and Unit.alive(unit) then
			local is_incumbent = _displayed[unit] ~= nil
			local target_pos = get_aim_target_position(unit)

			-- Skip this target for the frame when position reads fail (unit destruction
			-- instant, etc.)
			if target_pos then
				local to_target = target_pos - origin
				local distance = Vector3.length(to_target)

				-- Distance/angle filtering (based on the trajectory origin; incumbents
				-- get the edge tolerance)
				local angle_dot = 0

				if distance > 1e-6 then
					angle_dot = Vector3.dot(camera_fwd, to_target) / distance
				end

				local filter_entry = _filter_entry

				filter_entry.breed_name = entry.breed_name
				filter_entry.category = entry.category
				filter_entry.distance = distance
				filter_entry.angle_dot = angle_dot

				if TargetFilter.should_show(filter_entry, settings, is_incumbent) then
					-- Optional visibility check
					local visible = true

					if settings.visibility_check ~= false then
						visible = Context.is_visible(unit, camera_pos, target_pos)
					end

					local velocity = settings.show_lead ~= false and get_target_velocity(unit) or nil
					local aim_position, flight_time, pitch, solve_horizontal, solve_height =
						compute_aim_position(unit, t, origin, target_pos, velocity, settings)

					if aim_position then
						targets[#targets + 1] = {
							unit = unit,
							breed_name = entry.breed_name,
							category = entry.category,
							aim_position = aim_position,
							-- Scalar aim point components: only scalars cross frames/phases;
							-- the engine Vector3 is built by marker_sync at the store site
							aim_x = aim_position.x,
							aim_y = aim_position.y,
							aim_z = aim_position.z,
							distance = distance,
							-- Effective sort distance for incumbent hysteresis (within the
							-- category only, category priority unchanged)
							sort_distance = is_incumbent and (distance - INCUMBENT_DISTANCE_MARGIN) or distance,
							color = BreedConfig.color(entry.breed_name, entry.category, settings.breed_config),
							size = settings.dot_size,
							visible = visible,
							-- Solve snapshot for render-frame refresh (see refresh_positions)
							pitch = pitch,
							flight_time = flight_time,
							solve_horizontal = solve_horizontal,
							solve_height = solve_height,
							-- Scalar velocity table {x,y,z} (see get_target_velocity), engine
							-- userdata is not kept
							velocity = velocity,
							lead_multiplier = settings.lead_multiplier or 1,
						}
					end
				end
			end
		end
	end

	TargetFilter.sort(targets)

	-- Cap the display count
	local max_dots = settings.max_dots or 10

	for i = #targets, max_dots + 1, -1 do
		targets[i] = nil
	end

	-- Rebuild the incumbent list (for next frame's hysteresis) and detect targets
	-- that dropped off: droppers enter a linger period where they keep being output
	-- and fade out (marker_sync reuses their markers, following the enemy)
	for unit in pairs(_displayed_swap) do
		_displayed_swap[unit] = nil
	end

	for i = 1, #targets do
		_displayed_swap[targets[i].unit] = targets[i]
	end

	for unit, target in pairs(_displayed) do
		if not _displayed_swap[unit] then
			_linger[unit] = {
				target = target,
				drop_t = main_time,
			}
		end
	end

	for unit in pairs(_displayed_swap) do
		_linger[unit] = nil
	end

	_displayed, _displayed_swap = _displayed_swap, _displayed

	-- Depth stack fading: markers behind a closer marker on the same sight line fade
	-- out (target order does not matter downstream; sorted by depth and computed in
	-- place, positions taken from scalar components)
	if #targets > 1 then
		local cam_x, cam_y, cam_z = camera_pos.x, camera_pos.y, camera_pos.z
		local fwd_x, fwd_y, fwd_z = camera_fwd.x, camera_fwd.y, camera_fwd.z

		for i = 1, #targets do
			local target = targets[i]
			local px, py, pz = target.aim_x, target.aim_y, target.aim_z

			target.px = px
			target.py = py
			target.pz = pz
			target.cx = cam_x
			target.cy = cam_y
			target.cz = cam_z
			target.depth = (px - cam_x) * fwd_x + (py - cam_y) * fwd_y + (pz - cam_z) * fwd_z
		end

		table_sort(targets, function(a, b)
			return a.depth < b.depth
		end)

		StackFade.apply(targets)
	end

	-- Lingering targets: keep being output for LINGER_TIME after dropping off, alpha
	-- fading linearly with the remaining time; render-frame refresh and position
	-- writes apply to them as well (fades out smoothly while following the enemy,
	-- marker_sync reuses the marker)
	for unit, record in pairs(_linger) do
		local linger_target = record.target
		local elapsed = main_time - record.drop_t

		if not Unit.alive(unit) or elapsed >= LINGER_TIME then
			_linger[unit] = nil
		else
			linger_target.stack_alpha = 1 - elapsed / LINGER_TIME
			linger_target.linger = true
			targets[#targets + 1] = linger_target
		end
	end

	-- debug_print checks the debug flag itself; log only on count changes to avoid
	-- spam. Guarded here so the message strings are not concatenated (and turned
	-- into garbage) on every fixed frame with debug_mode off.
	if mod.settings and mod.settings.debug_mode then
		if #targets ~= _last_debug_count then
			debug_stage("enemies=" .. enemy_count .. ", targets=" .. #targets, main_time)
			_last_debug_count = #targets
		else
			debug_stage("enemies=" .. enemy_count, main_time)
		end
	end

	return result
end

--[[
	Render-frame refresh (called at render rate by the main module's
	HudElementWorldMarkers.update hook).

	Recomputes the aim point from the latest positions so the dots follow targets at
	render rate, removing the visual lag of the fixed-frame interval. When a target
	has moved more than RENDER_SOLVE_MOVE_TOLERANCE since the last solve, the pitch
	is re-solved immediately, removing the stair-stepping of the fixed-frame solve
	cache on fast-moving targets.
	Cost: one bone read per target plus a few scalar ops (re-solves only happen past
	the move threshold).

	@param targets table the target array output by the latest update() (aim_position
	       updated in place, including lingering fading targets)
	@param origin_override Vector3|nil test seam; skips the player position query when given
	@return table the passed-in targets (refreshed)
]]
local function refresh_positions(targets, origin_override)
	local settings = mod.indicator_settings

	if not settings or settings.toggle_mod == false or not targets or #targets == 0 then
		return targets
	end

	local origin = origin_override

	if not origin then
		local player = Context.get_local_player()

		if not player or not player.player_unit then
			return targets
		end

		origin = Context.get_first_person_position(player.player_unit)

		if not origin then
			return targets
		end
	end

	local show_lead = settings.show_lead ~= false
	local probe_enabled = mod.settings ~= nil and mod.settings.debug_mode == true
	local probe_now = nil

	if probe_enabled and Managers.time and Managers.time:has_timer("main") then
		probe_now = Managers.time:time("main")
	end

	for i = 1, #targets do
		local target = targets[i]
		local unit = target.unit

		if unit and Unit.alive(unit) then
			local aim_target = get_aim_target_position(unit)

			-- Keep last frame's aim point when position reads fail (always a valid Vector3)
			if aim_target then
				-- Smoothness probe: first target only
				if probe_enabled and i == 1 then
					_probe_frames = _probe_frames + 1

					local hx, hy, hz = aim_target.x, aim_target.y, aim_target.z

					if _probe_last then
						local dx, dy, dz = hx - _probe_last[1], hy - _probe_last[2], hz - _probe_last[3]

						if dx * dx + dy * dy + dz * dz > 2.5e-7 then
							_probe_moves = _probe_moves + 1
						end
					end

					_probe_last = { hx, hy, hz }

					if probe_now then
						if not _probe_t then
							_probe_t = probe_now
						elseif probe_now - _probe_t >= 5 then
							mod:debug_print(
								"probe: refresh=",
								_probe_frames,
								"/5s, head_moves=",
								_probe_moves,
								"/5s (target should be moving)"
							)
							_probe_t, _probe_frames, _probe_moves, _probe_last = probe_now, 0, 0, nil
						end
					end
				end
				local velocity = target.velocity

				if velocity and target.flight_time and show_lead then
					local lead_dt = target.flight_time * (target.lead_multiplier or 1)

					aim_target = Vector3(
						aim_target.x + velocity.x * lead_dt,
						aim_target.y + velocity.y * lead_dt,
						aim_target.z + velocity.z * lead_dt
					)
				end

				local to_aim = aim_target - origin
				local horizontal = math_sqrt(to_aim.x * to_aim.x + to_aim.y * to_aim.y)
				local height = to_aim.z

				-- Render-frame re-solve: update the pitch when the solve inputs (horizontal
				-- distance/height) drift past the tolerance since the last solve
				if target.pitch
					and (math_abs(horizontal - (target.solve_horizontal or horizontal)) > RENDER_SOLVE_MOVE_TOLERANCE
						or math_abs(height - (target.solve_height or height)) > RENDER_SOLVE_MOVE_TOLERANCE) then
					local pitch, flight_time = Ballistics.solve(horizontal, height)

					if pitch then
						target.pitch = pitch
						target.flight_time = flight_time
					end

					target.solve_horizontal = horizontal
					target.solve_height = height
				end

				if horizontal < 0.05 or not target.pitch then
					-- Point-blank / no pitch solution: aim straight at the target
					local ax, ay, az = aim_target.x, aim_target.y, aim_target.z

					target.aim_x, target.aim_y, target.aim_z = ax, ay, az
					target.aim_position = Vector3(ax, ay, az)
				else
					local hd = Vector3.normalize(Vector3(to_aim.x, to_aim.y, 0))
					local aim_dir = hd * math_cos(target.pitch) + Vector3(0, 0, 1) * math_sin(target.pitch)
					local dist = Vector3.length(to_aim) + AIM_POINT_EXTENSION
					local ax = origin.x + aim_dir.x * dist
					local ay = origin.y + aim_dir.y * dist
					local az = origin.z + aim_dir.z * dist

					target.aim_x, target.aim_y, target.aim_z = ax, ay, az
					target.aim_position = Vector3(ax, ay, az)
				end
			end
		end
	end

	return targets
end

return {
	update = update,
	refresh_positions = refresh_positions,
	clear_cache = clear_cache,
	compute_aim_position = compute_aim_position,
}
