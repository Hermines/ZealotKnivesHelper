--[[
	Game state context (depends on game engine APIs)

	Responsibilities:
	  - local player archetype checks and supported knife-throw state
	    (Zealot throwing-knives blitz / Hive Scum dual shivs special throw)
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

-- Zealot throwing-knives blitz ability name (equipped-ability lookup key / charge read)
local KNIVES_ABILITY_NAME = "zealot_throwing_knives"

-- Hive Scum dual shivs weapon templates ("dual_shivs_p1_m1" / "dual_shivs_p1_m2"):
-- the special action throw (action_special_throw, kind "weapon_throw") uses the
-- same dual_shivs_throwing_knife_projectile locomotion on both variants, so a
-- prefix match covers them and future variants sharing that projectile.
local DUAL_SHIVS_TEMPLATE_PREFIX = "dual_shivs"

-- Enemy scan interval (seconds)
local ENEMY_SCAN_INTERVAL = 0.1
-- Adaptive throttle threshold: doubles the scan interval when a scan finds more
-- enemies than this
local ADAPTIVE_THROTTLE_THRESHOLD = 30

-- Engine broadphase query hard limit (broadphase_system.lua BROADPHASE_CELL_RADIUS = 50):
-- a query with a radius beyond 50 m silently returns unreliable results (no error,
-- just an empty scan). Radii over the limit are covered by a lattice of <=50 m
-- sub-queries, see query_broadphase below.
local ENGINE_QUERY_LIMIT = 50
-- Lattice spacing: the diagonal half of a 50*sqrt(2) m lattice cell is exactly 50 m,
-- so adjacent sub-query circles (radius 50) tile the plane without gaps.
local LATTICE_STEP = ENGINE_QUERY_LIMIT * 1.4142135623731

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
	broadphase_scratch = {}, -- reused per sub-query (multi-query coverage path)
	broadphase_seen = {}, -- unit de-duplication set (multi-query coverage path)
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

--- Archetype name of the local player ("zealot" / "broker" / ...), nil when unknown
local function player_archetype_name(player)
	local player_unit = player and player.player_unit

	if not player_unit then
		return nil
	end

	local data_ext = ScriptUnit.has_extension(player_unit, "unit_data_system")
		and ScriptUnit.extension(player_unit, "unit_data_system")

	if data_ext and data_ext.archetype_name then
		return data_ext:archetype_name()
	end

	-- Fallback: read the player profile directly
	local profile = player._profile
	local archetype = profile and profile.archetype

	return archetype and archetype.name or nil
end

--- Whether the player is a Zealot (archetype name "zealot")
---@param player table
---@return boolean
function Context.is_zealot(player)
	return player_archetype_name(player) == "zealot"
end

--- Whether the player is a Hive Scum (archetype name "broker")
---@param player table
---@return boolean
function Context.is_broker(player)
	return player_archetype_name(player) == "broker"
end

--- Whether the Zealot throwing-knives blitz is equipped.
-- 1.13.0: the blitz no longer occupies slot_grenade_ability (its ability entry uses
-- inventory_item_reference, which the ability extension no longer equips as a slot
-- weapon), so match the equipped ability name instead of the grenade-slot weapon
-- template. Primary path uses the game's native per-ability slot lookup (the same
-- source as the knife action's own gate), with an equipped-abilities scan fallback.
---@param player_unit userdata
---@return boolean
function Context.has_throwing_knives(player_unit)
	local ability_ext = ScriptUnit.has_extension(player_unit, "ability_system")
		and ScriptUnit.extension(player_unit, "ability_system")

	if not ability_ext then
		return false
	end

	if ability_ext.ability_slot_by_ability_name then
		if ability_ext:ability_slot_by_ability_name(KNIVES_ABILITY_NAME) then
			return true
		end
	end

	-- Fallback: scan the equipped ability names (old extensions / variant names)
	if not ability_ext.equipped_abilities then
		return false
	end

	local equipped = ability_ext:equipped_abilities()
	local ability = equipped and equipped.grenade_ability
	local name = ability and ability.name

	if not name then
		return false
	end

	return string_find(name, KNIVES_ABILITY_NAME, 1, true) ~= nil
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

--- Hive Scum dual-shivs special-throw state (nil when the wielded weapon is not a
--- dual shivs weapon). The throw is a weapon special action, so it is only
--- available while the shivs are wielded; the remaining charges live on the
--- weapon slot component's num_special_charges (fed by tagging enemies), not on
--- the ability extension.
---@param player_unit userdata
---@return table|nil { mode = "broker_shivs", charges = number }
local function get_broker_shivs_state(player_unit)
	local weapon_ext = ScriptUnit.has_extension(player_unit, "weapon_system")
		and ScriptUnit.extension(player_unit, "weapon_system")
	local weapon_template = weapon_ext and weapon_ext:weapon_template()
	local template_name = weapon_template and weapon_template.name

	if type(template_name) ~= "string"
		or not string_find(template_name, DUAL_SHIVS_TEMPLATE_PREFIX, 1, true) then
		return nil
	end

	local data_ext = ScriptUnit.has_extension(player_unit, "unit_data_system")
		and ScriptUnit.extension(player_unit, "unit_data_system")
	local inventory = data_ext and data_ext:read_component("inventory")
	local wielded_slot = inventory and inventory.wielded_slot
	local slot_component = (data_ext and wielded_slot and wielded_slot ~= "none")
		and data_ext:read_component(wielded_slot)
	local charges = slot_component and slot_component.num_special_charges

	return {
		mode = "broker_shivs",
		charges = charges or 0,
	}
end

--- Supported knife-throw state of the local player (nil when no throw is
--- available right now):
---   - Zealot: throwing-knives blitz equipped (throwable while wielding any
---     weapon); charges = remaining ability charges
---   - Hive Scum (broker): dual-shivs weapon wielded (special action throw);
---     charges = the weapon slot's num_special_charges
--- mode selects the ballistic parameter preset in game/indicators (kept as a
--- string so this module stays free of core/ imports). The returned table holds
--- only scalars/strings, safe to cross frames.
---@param player table
---@return table|nil { mode = "zealot_blitz"|"broker_shivs", charges = number }
function Context.get_throw_state(player)
	if not player or not player.player_unit then
		return nil
	end

	if Context.is_zealot(player) then
		local player_unit = player.player_unit

		if not Context.has_throwing_knives(player_unit) then
			return nil
		end

		return {
			mode = "zealot_blitz",
			charges = Context.get_knives_count(player_unit),
		}
	end

	if Context.is_broker(player) then
		return get_broker_shivs_state(player.player_unit)
	end

	return nil
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

--- Broadphase range query working around the engine's 50 m query limit.
-- Within the limit a single query runs (zero overhead). Beyond it, the range is
-- covered by a lattice of <=50 m sub-queries offset by LATTICE_STEP whose circles
-- tile the plane without gaps; overlapping hits are de-duplicated. Units are
-- appended to results (never cleared), so callers must iterate 1..returned count.
--@param broadphase userdata
--@param origin Vector3 query centre
--@param query_range number desired radius
--@param enemy_side_names table category filter from side:relation_side_names
--@param results table output array (pre-cleared by the caller)
--@return number num_hits
local function query_broadphase(broadphase, origin, query_range, enemy_side_names, results)
	if query_range <= ENGINE_QUERY_LIMIT then
		return broadphase.query(broadphase, origin, query_range, results, enemy_side_names)
	end

	local scratch = state.broadphase_scratch
	local seen = state.broadphase_seen

	table_clear(seen)

	local num_results = 0
	local rings = math.ceil((query_range - ENGINE_QUERY_LIMIT) / LATTICE_STEP)

	for i = -rings, rings do
		local offset_x = i * LATTICE_STEP

		for j = -rings, rings do
			table_clear(scratch)

			local centre = Vector3(origin.x + offset_x, origin.y + j * LATTICE_STEP, origin.z)
			local hits = broadphase.query(broadphase, centre, ENGINE_QUERY_LIMIT, scratch, enemy_side_names)

			for k = 1, hits do
				local unit = scratch[k]

				if unit and not seen[unit] then
					seen[unit] = true
					num_results = num_results + 1
					results[num_results] = unit
				end
			end
		end
	end

	return num_results
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

					local num_hits = query_broadphase(broadphase, from_pos, max_distance + 5, enemy_side_names, results)

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
