---@class ZealotKnivesHelperMod:DMFMod
local mod = get_mod("ZealotKnivesHelper")

--[[
	ZealotKnivesHelper - ballistic assist crosshair for Zealot throwing knives

	While the Zealot has throwing knives equipped, shows extra dot crosshairs over
	boss/elite/specialist enemies, indicating where to move the game crosshair to hit
	that enemy (compensates the knife trajectory's gravity drop and air drag, with
	optional lead prediction from target velocity). Multiple qualifying enemies in
	range are indicated at once.

	Trajectory integration replicates the game source projectile_integration.lua.
]]

-- Global references
local Managers = Managers

-- ============================================================================
-- Settings cache
-- ============================================================================
---@class ZealotKnivesHelperModSettings
local mod_settings = {
	toggle_mod              = mod:get("toggle_mod"),
	debug_mode              = mod:get("debug_mode"),
	max_distance            = mod:get("max_distance"),
	max_angle               = mod:get("max_angle"),
	dot_size                = mod:get("dot_size"),
	dot_opacity             = mod:get("dot_opacity"),
	max_dots                = mod:get("max_dots"),
	scale_by_distance       = mod:get("scale_by_distance"),
	show_lead               = mod:get("show_lead"),
	lead_multiplier         = mod:get("lead_multiplier"),
	require_charges         = mod:get("require_charges"),
	visibility_check        = mod:get("visibility_check"),
	show_boss               = mod:get("show_boss"),
	color_boss              = mod:get("color_boss"),
	show_elite              = mod:get("show_elite"),
	color_elite             = mod:get("color_elite"),
	show_special            = mod:get("show_special"),
	color_special           = mod:get("color_special"),
}

mod.settings = mod_settings

-- Load submodules
local BreedList = mod:io_dofile("ZealotKnivesHelper/scripts/mods/ZealotKnivesHelper/game/breed_list")
local Context = mod:io_dofile("ZealotKnivesHelper/scripts/mods/ZealotKnivesHelper/game/context")
local Indicators = mod:io_dofile("ZealotKnivesHelper/scripts/mods/ZealotKnivesHelper/game/indicators")
local MarkerSync = mod:io_dofile("ZealotKnivesHelper/scripts/mods/ZealotKnivesHelper/draw/marker_sync")

-- Indicator result of the latest frame (written by indicators.update, read by marker_sync)
mod.frame_result = nil

-- ============================================================================
-- Indicator settings view (consumed by indicators.lua, derived from DMF settings)
-- ============================================================================
local indicator_settings = {
	toggle_mod = false,
	category_show = { boss = true, elite = true, special = true },
	breed_hidden = {},
	breed_config = {
		category_show = { boss = true, elite = true, special = true },
		category_color = {},
		breed_show = {},
		breed_color = {},
	},
	max_distance = 50,
	max_angle = 30,
	dot_size = 6,
	max_dots = 5,
	scale_by_distance = true,
	show_lead = true,
	lead_multiplier = 1,
	require_charges = true,
	visibility_check = false,
}

mod.indicator_settings = indicator_settings

local function rebuild_indicator_settings()
	indicator_settings.toggle_mod = mod_settings.toggle_mod and true or false
	indicator_settings.max_distance = mod_settings.max_distance or 50
	indicator_settings.max_angle = mod_settings.max_angle or 30
	indicator_settings.dot_size = mod_settings.dot_size or 6
	indicator_settings.max_dots = mod_settings.max_dots or 5
	indicator_settings.scale_by_distance = mod_settings.scale_by_distance ~= false
	indicator_settings.show_lead = mod_settings.show_lead and true or false
	indicator_settings.lead_multiplier = (mod_settings.lead_multiplier or 100) / 100
	indicator_settings.require_charges = mod_settings.require_charges and true or false
	indicator_settings.visibility_check = mod_settings.visibility_check and true or false

	-- Category toggles and colors
	local category_show = indicator_settings.category_show
	local category_color = indicator_settings.breed_config.category_color

	category_show.boss = mod_settings.show_boss and true or false
	category_show.elite = mod_settings.show_elite and true or false
	category_show.special = mod_settings.show_special and true or false
	category_color.boss = mod_settings.color_boss
	category_color.elite = mod_settings.color_elite
	category_color.special = mod_settings.color_special

	-- Per-breed toggles and colors (individually set; fall back to the category color)
	local breed_hidden = indicator_settings.breed_hidden
	local breed_show = indicator_settings.breed_config.breed_show
	local breed_color = indicator_settings.breed_config.breed_color

	for _, category in ipairs({ "boss", "elite", "special" }) do
		for _, breed_name in ipairs(BreedList.categories[category]) do
			local show_value = mod:get("breed_show_" .. breed_name)
			local color_value = mod:get("breed_color_" .. breed_name)

			breed_show[breed_name] = show_value ~= false
			breed_color[breed_name] = color_value
			breed_hidden[breed_name] = show_value == false
		end
	end

	indicator_settings.breed_config.category_show = category_show
	indicator_settings.dot_opacity = mod_settings.dot_opacity
end

-- ============================================================================
-- Lifecycle callbacks
-- ============================================================================

mod.on_enabled = function(initial_call)
	rebuild_indicator_settings()
end

mod.on_disabled = function(initial_call)
	mod.frame_result = nil
	Indicators.clear_cache()
	Context.clear_session()
	MarkerSync.clear()
end

mod.on_game_state_changed = function(status, state_name)
	if state_name ~= "GameplayStateRun" then
		return
	end

	if status == "enter" then
		rebuild_indicator_settings()
	else
		mod.frame_result = nil
		Indicators.clear_cache()
		Context.clear_session()
		MarkerSync.clear()
	end
end

mod.on_setting_changed = function(setting_id)
	if mod_settings[setting_id] ~= nil then
		mod_settings[setting_id] = mod:get(setting_id)
	end

	-- Per-breed settings (breed_show_* / breed_color_*) are re-read in the rebuild
	rebuild_indicator_settings()

	-- Invalidate the pre-change snapshot: view input is processed before the HUD
	-- update in the same frame, so the render-frame refresh would otherwise run once
	-- on targets computed with the old settings
	mod.frame_result = nil
	Indicators.clear_cache()
end

-- ============================================================================
-- Debug output
-- ============================================================================
mod.debug_print = function(_, ...)
	if mod_settings.debug_mode then
		local parts = {}

		for i = 1, select("#", ...) do
			parts[i] = tostring(select(i, ...))
		end

		mod:echo("[ZealotKnivesHelper] " .. table.concat(parts, " "))
	end
end

-- ============================================================================
-- Fixed-frame update: compute the indicator result and sync engine world markers
-- ============================================================================
-- Rate probe (debug_mode): every 5s, logs the actual call rates of the fixed-frame
-- and render-frame hooks to verify the real cadence of the two-stage pipeline
-- (read together with the head_moves probe in indicators)
local _rate_t, _rate_fixed, _rate_render = nil, 0, 0

mod:hook_safe("PlayerUnitFirstPersonExtension", "fixed_update", function(self, unit, dt, t, fixed_frame)
	local player = Managers.player:local_player(1)

	-- Only trigger on the local player unit; avoids duplicate work for remote players
	if not player or not player:unit_is_alive() or unit ~= player.player_unit then
		return
	end

	if mod_settings.debug_mode then
		_rate_fixed = _rate_fixed + 1
	end

	mod.frame_result = Indicators.update(dt, t)
	MarkerSync.sync(mod.frame_result.targets)
end)

-- ============================================================================
-- HUD: register the custom template each time the world marker element is rebuilt
-- ============================================================================
mod:hook_safe("HudElementWorldMarkers", "init", function(self, parent, draw_layer, start_scale)
	MarkerSync.register_templates(self)
end)

-- ============================================================================
-- Render-frame refresh: update marker positions at render rate, removing the
-- visual lag of the fixed-frame interval.
-- (Heavy work stays on the fixed frame: scanning/filtering/trajectory solving;
-- this only recomputes the direction from the cached pitch + latest positions.)
--
-- Uses a pre-hook (mod:hook, not safe): the latest aim points are written before
-- the engine's original update reads marker positions -- zero lag between the
-- drawn position and this frame's world state. The old hook_safe (writing after
-- the engine's read) was always one frame behind and fought with fixed-frame writes
-- (52 Hz fixed vs render rate, out of sync), causing jitter from a swinging lag
-- while moving.
-- Position writes are owned exclusively here: fixed-frame sync no longer writes
-- positions (it only seeds the position at marker creation).
-- ============================================================================
local _render_err_t = nil

--- Render-frame position refresh + write (called by the pre-hook before the
--- engine reads marker positions)
local function render_refresh()
	local result = mod.frame_result
	local targets = result and result.targets

	if not targets or #targets == 0 then
		return
	end

	local time_manager = Managers.time
	local now = time_manager and time_manager:has_timer("main") and time_manager:time("main") or nil

	if not now or now - result.t > 0.25 then
		-- Freshness guard: stop refreshing when the fixed frame stops updating
		return
	end

	Indicators.refresh_positions(targets)
	MarkerSync.update_positions(targets)
end

mod:hook("HudElementWorldMarkers", "update", function(next, self, dt, t, ...)
	if mod_settings.debug_mode then
		_rate_render = _rate_render + 1

		local time_manager = Managers.time
		local probe_now = time_manager and time_manager:has_timer("main") and time_manager:time("main") or nil

		if probe_now then
			if not _rate_t then
				_rate_t = probe_now
			elseif probe_now - _rate_t >= 5 then
				local span = probe_now - _rate_t

				mod:debug_print(
					"probe: fixed=",
					math.floor(_rate_fixed / span + 0.5),
					"/s, render=",
					math.floor(_rate_render / span + 0.5),
					"/s"
				)

				_rate_t, _rate_fixed, _rate_render = probe_now, 0, 0
			end
		end
	end

	-- pcall keeps the engine's original update running even if the refresh fails
	-- (the marker system is unaffected); error logs are throttled to one per 5s
	local ok, err = pcall(render_refresh)

	if not ok then
		local time_manager = Managers.time
		local now = time_manager and time_manager:has_timer("main") and time_manager:time("main") or 0

		if not _render_err_t or now - _render_err_t >= 5 then
			_render_err_t = now

			mod:error("render refresh failed: %s", err)
		end
	end

	return next(self, dt, t, ...)
end)
