--[[
	Game state context (depends on game engine APIs)

	Responsibilities:
	  - local player / zealot archetype checks
	  - throwing knife equipment and remaining charges
	  - enemy enumeration with category pre-classification (throttled cache)
	  - access to camera / trajectory origin / visibility raycasts and other game resources
]]

local mod = get_mod("ZealotKnivesHelper")

local Context = {}

-- Global references (performance)
local Managers = Managers
local ScriptUnit = ScriptUnit
local Unit = Unit
local World = World
local Vector3 = Vector3
local Actor = Actor
local string_find = string.find
local pairs = pairs

-- Knife weapon template name (weapon template "name" field in slot_grenade_ability)
local KNIVES_PATTERN = "zealot_throwing_knives"

-- Enemy scan interval (seconds)
local ENEMY_SCAN_INTERVAL = 0.1
-- Adaptive throttle threshold: doubles the scan interval when a scan finds more
-- enemies than this
local ADAPTIVE_THROTTLE_THRESHOLD = 30

-- Line-of-sight check throttle (seconds per unit)
local VISIBILITY_INTERVAL = 0.15
-- Max LOS raycasts per frame (up to 2 per enemy: head + spine)
local VISIBILITY_RAYCAST_BUDGET = 8
-- Collision filter for LOS checks (dedicated AI line-of-sight filter: passes through
-- minion collision bodies, blocked by terrain/buildings only)
local LOS_COLLISION_FILTER = "filter_minion_line_of_sight_check"

local table_clear = table.clear or function(t)
	for k in pairs(t) do
		t[k] = nil
	end
end

-- State
local state = {
	scan_timer = 0,
	enemies = {}, -- { {unit, breed, breed_name, category}, ... }
	enemy_count = 0,
	visibility_cache = {}, -- [unit] = {visible = bool, timer = number}
	raycast_frame_budget = 0,
	broadphase_results = {},
}

--- Reset per-session caches (releases unit references)
function Context.clear_session()
	state.scan_timer = 0
	table_clear(state.enemies)
	state.enemy_count = 0
	table_clear(state.visibility_cache)
end

--- Get the local player (nil when invalid)
function Context.get_local_player()
	local player = Managers.player and Managers.player:local_player(1)

	if player and player.player_unit and player:unit_is_alive() then
		return player
	end

	return nil
end

--- Whether the player is a Zealot (archetype name "zealot")
---@param player table
---@return boolean
function Context.is_zealot(player)
	local player_unit = player and player.player_unit

	if not player_unit then
		return false
	end

	local data_ext = ScriptUnit.has_extension(player_unit, "unit_data_system")
		and ScriptUnit.extension(player_unit, "unit_data_system")

	if data_ext and data_ext.archetype_name then
		return data_ext:archetype_name() == "zealot"
	end

	-- Fallback: read the player profile directly
	local profile = player._profile
	local archetype = profile and profile.archetype

	return archetype ~= nil and archetype.name == "zealot"
end

--- Weapon template of the grenade slot (slot_grenade_ability), nil when not equipped
---@param player_unit userdata
---@return table|nil
function Context.get_grenade_weapon_template(player_unit)
	local weapon_ext = ScriptUnit.has_extension(player_unit, "weapon_system")
		and ScriptUnit.extension(player_unit, "weapon_system")

	local weapons = weapon_ext and weapon_ext._weapons
	local grenade_weapon = weapons and weapons["slot_grenade_ability"]

	return grenade_weapon and grenade_weapon.weapon_template or nil
end

--- Whether the grenade slot weapon is the Zealot throwing knives
---@param player_unit userdata
---@return boolean
function Context.has_throwing_knives(player_unit)
	local weapon_template = Context.get_grenade_weapon_template(player_unit)

	if not weapon_template or not weapon_template.name then
		return false
	end

	return string_find(weapon_template.name, KNIVES_PATTERN) ~= nil
end

--- Remaining knife charges (0 when the ability extension is missing or reads fail)
---@param player_unit userdata
---@return number
function Context.get_knives_count(player_unit)
	local ability_ext = ScriptUnit.has_extension(player_unit, "ability_system")
		and ScriptUnit.extension(player_unit, "ability_system")

	if not ability_ext then
		return 0
	end

	local ok, charges = pcall(ability_ext.remaining_ability_charges, ability_ext, "grenade_ability")

	return (ok and charges) or 0
end

--- First-person position (trajectory origin, matching the game's spawn_projectile
--- behavior), nil on failure
---@param player_unit userdata
---@return Vector3|nil
function Context.get_first_person_position(player_unit)
	local data_ext = ScriptUnit.has_extension(player_unit, "unit_data_system")
		and ScriptUnit.extension(player_unit, "unit_data_system")
	local first_person = data_ext and data_ext:read_component("first_person")

	return first_person and first_person.position or nil
end

--- Local player camera
---@param player table
---@return userdata|nil
function Context.get_camera(player)
	local camera_manager = Managers.state and Managers.state.camera
	local viewport_name = player and player.viewport_name

	if not camera_manager or not viewport_name then
		return nil
	end

	return camera_manager:camera(viewport_name)
end

--- Physics world
---@return userdata|nil
function Context.get_physics_world()
	if Managers.world and Managers.world:has_world("level_world") then
		local level_world = Managers.world:world("level_world")

		if level_world then
			return World.physics_world(level_world)
		end
	end

	return nil
end

--- Whether a LOS raycast result is "unblocked": no hit is clear; a hit on the target
--- unit itself also counts as clear (the hit table stores the actor at index 4)
local function los_path_clear(hit, target_unit)
	if not hit then
		return true
	end

	if type(hit) == "table" then
		local actor = hit[4]
		local hit_unit = actor and Actor.unit(actor)

		return hit_unit == target_unit
	end

	return false
end

--- Whether the line of sight from from_position to point is clear
local function los_to_point(physics_world, from_position, target_unit, point)
	local to_point = point - from_position
	local distance = Vector3.length(to_point)

	if distance <= 0.01 then
		return true
	end

	local ok, hit = pcall(PhysicsWorld.raycast, physics_world, from_position,
		Vector3.normalize(to_point), distance, "closest",
		"collision_filter", LOS_COLLISION_FILTER)

	-- Fail-open: treat raycast failures as visible
	return not ok or los_path_clear(hit, target_unit)
end

--- Spine sample point of the target (j_spine1 -> j_spine -> root node), a second
--- probe for when the head is blocked by thin cover
local function get_spine_point(unit, head_point)
	if Unit.has_node(unit, "j_spine1") then
		return Unit.world_position(unit, Unit.node(unit, "j_spine1"))
	end

	if Unit.has_node(unit, "j_spine") then
		return Unit.world_position(unit, Unit.node(unit, "j_spine"))
	end

	local root = Unit.world_position(unit, 1)

	if root ~= head_point then
		return root
	end

	return nil
end

--- Check whether the target is visible (throttled cache and per-frame budget)
--- Rule: visible if either the head or the spine sample point has a clear line of
--- sight; a ray hitting only the target's own collision body counts as unblocked.
---@param unit userdata
---@param from_position Vector3
---@param target_position Vector3 target head sample point (same as the aim point)
---@return boolean visible (defaults to true when raycasts are unavailable, never blocks display)
function Context.is_visible(unit, from_position, target_position)
	local cached = state.visibility_cache[unit]

	if cached then
		if cached.timer > 0 then
			return cached.visible
		end
	else
		cached = {
			visible = true,
			timer = 0,
		}
		state.visibility_cache[unit] = cached
	end

	cached.timer = VISIBILITY_INTERVAL

	if state.raycast_frame_budget <= 0 then
		return cached.visible
	end

	local physics_world = Context.get_physics_world()

	if not physics_world then
		return true
	end

	state.raycast_frame_budget = state.raycast_frame_budget - 1

	local visible = false

	if los_to_point(physics_world, from_position, unit, target_position) then
		visible = true
	else
		-- Head blocked: retry with the spine point (low cover / thin occluders)
		local spine_point = get_spine_point(unit, target_position)

		if spine_point and los_to_point(physics_world, from_position, unit, spine_point) then
			visible = true
		end
	end

	cached.visible = visible

	return visible
end

--- Number of enemy entries in the scan cache
function Context.enemy_count()
	return state.enemy_count
end

--- Get the cached enemy entries (for read-only iteration)
---@return table
function Context.enemies()
	return state.enemies
end

--- Classify and store an enemy entry (same rules as core/target_filter.classify)
---@return number the new count
local function classify_and_store(unit, count)
	local data_ext = ScriptUnit.has_extension(unit, "unit_data_system")
		and ScriptUnit.extension(unit, "unit_data_system")
	local breed = data_ext and data_ext:breed()

	if not breed or not breed.name or breed.name == "human" then
		return count
	end

	local category
	if breed.is_boss then
		category = "boss"
	elseif breed.tags then
		if breed.tags.elite then
			category = "elite"
		elseif breed.tags.special then
			category = "special"
		end
	end

	if not category then
		return count
	end

	count = count + 1
	local entry = state.enemies[count] or {}

	entry.unit = unit
	entry.breed = breed
	entry.breed_name = breed.name
	entry.category = category
	state.enemies[count] = entry

	return count
end

--- Enumerate and pre-classify enemies (throttled)
-- Prefers the broadphase spatial query, which only returns enemy units within the
-- indicator range, avoiding a full traversal of all health-extension units;
-- falls back to a full health_system scan when the broadphase/side systems are
-- unavailable.
function Context.update_enemies(dt)
	state.raycast_frame_budget = VISIBILITY_RAYCAST_BUDGET

	-- Expire stale visibility cache entries
	for unit, cached in pairs(state.visibility_cache) do
		cached.timer = cached.timer - dt

		if not Unit.alive(unit) or cached.timer < -VISIBILITY_INTERVAL * 4 then
			state.visibility_cache[unit] = nil
		end
	end

	state.scan_timer = state.scan_timer - dt

	if state.scan_timer > 0 then
		return
	end

	local player = Context.get_local_player()
	local player_unit = player and player.player_unit
	local ext_mgr = Managers.state and Managers.state.extension
	local scan_interval = ENEMY_SCAN_INTERVAL
	local count = 0
	local used_broadphase = false

	if player_unit and ext_mgr then
		local broadphase_system = ext_mgr:system("broadphase_system")
		local side_system = ext_mgr:system("side_system")

		if broadphase_system and side_system then
			local side = side_system.side_by_unit[player_unit]

			if side then
				local broadphase = broadphase_system.broadphase
				local enemy_side_names = side and side:relation_side_names("enemy")

				if broadphase and enemy_side_names then
					used_broadphase = true

					local from_pos = Unit.world_position(player_unit, 1)
					local max_distance = mod.indicator_settings and mod.indicator_settings.max_distance or 50
					local results = state.broadphase_results

					table_clear(results)

					local num_hits = broadphase.query(broadphase, from_pos, max_distance + 5, results, enemy_side_names)

					-- Adaptive throttle: widen the scan interval when many enemies are cached
					if num_hits > ADAPTIVE_THROTTLE_THRESHOLD then
						scan_interval = ENEMY_SCAN_INTERVAL * 2
					end

					for i = 1, num_hits do
						local unit = results[i]

						if Unit.alive(unit) then
							local health_ext = ScriptUnit.has_extension(unit, "health_system")
								and ScriptUnit.extension(unit, "health_system")

							if health_ext and health_ext:is_alive() then
								count = classify_and_store(unit, count)
							end
						end
					end
				end
			end
		end
	end

	if not used_broadphase then
		local health_system = ext_mgr and ext_mgr:system("health_system")
		local unit_map = health_system and health_system:unit_to_extension_map()

		if unit_map then
			for unit, health_ext in pairs(unit_map) do
				if unit ~= player_unit and Unit.alive(unit) and health_ext:is_alive() then
					count = classify_and_store(unit, count)
				end
			end
		end
	end

	for i = count + 1, #state.enemies do
		state.enemies[i] = nil
	end

	state.enemy_count = count
	state.scan_timer = scan_interval
end

return Context
