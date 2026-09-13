--[[
	World marker synchronizer (game side)

	Every fixed frame, syncs the targets output by indicators into position markers
	on HudElementWorldMarkers:
	  - new targets: created via Managers.event:trigger("add_world_marker_position", ...)
	    (with an initial position); data (color/size/opacity/visibility) updates in place
	  - targets off the list: removed via Managers.event:trigger("remove_world_marker", id)
	    (the linger period is owned by indicators: targets stay in the output list while
	    lingering)
	Position writes do not happen here: fixed-frame writes would fight with the
	render-frame refresh and cause cadence jitter; positions are owned exclusively by
	the main module's render-frame pre-hook calling update_positions (zero-lag writes
	every frame)

Projection/frustum culling/distance scaling are handled by the engine. This module
also refreshes the engine-side template clone fields (max_distance / scale_settings)
onto every marker so setting changes apply instantly (the engine clones the template
per marker; editing the shared table does not affect existing markers).
]]

local mod = get_mod("ZealotKnivesHelper")

local MarkerTemplate = mod:io_dofile("ZealotKnivesHelper/scripts/mods/ZealotKnivesHelper/draw/marker_template")

-- Global references (captured at load time, same pattern as context.lua)
local Vector3 = Vector3

local MarkerSync = {}

local MARKER_TYPE = MarkerTemplate.name

-- Distance scaling parameters: scale from 1 to 0.5 between 5-50 m
local SCALE_SETTINGS = {
	scale_from = 0.5,
	scale_to = 1,
	distance_min = 5,
	distance_max = 50,
}

local _unit_markers = {} -- [unit] = {id, data}
local _element = nil -- world marker element last used by sync (reused by render-frame refresh)

-- The engine cuts markers off at template.max_distance measured from the camera to
-- the MARKER position (hud_element_world_markers _calculate_markers), and the marker
-- position is the aim point: the target plus the ~10 m trajectory extension
-- (indicators AIM_POINT_EXTENSION) plus the lead displacement. The mod's own
-- max_distance setting filters by TARGET distance, so writing the raw value here
-- would silently hide dots in the top of the range (with the 50 m default nothing
-- was drawn beyond ~40 m). The margin re-bases the engine cutoff onto target
-- distance: 10 m aim extension + 2 m incumbent edge tolerance (target_filter
-- DISPLAY_EDGE_TOLERANCE_DISTANCE) + 18 m lead headroom. The lead displacement
-- compounds (the lead solve iterates and flight time grows with distance), so 18 m
-- covers retreating targets up to ~13 m/s at the 100% lead multiplier and ~8.5 m/s
-- at 150% (measured with the solver over the whole admitted band at the default
-- 50 m setting; at larger settings flight time grows and the covered speed drops
-- (~7 m/s at 75 m, ~5 m/s at 100 m); only leap-speed transients can still pop a dot
-- at the extreme edge. Keep it in sync with those two constants when they change.
local MAX_DISTANCE_MARGIN = 30

--- Build the aim point vector from the target table's scalar components (engine
--- objects must not cross the fixed-frame/render-frame boundary; the target table
--- carries scalars across frames and Vector3 is always built at the store site in
--- the same phase)
local function target_position(target)
	local x, y, z = target.aim_x, target.aim_y, target.aim_z

	if x and y and z then
		return Vector3(x, y, z)
	end

	return nil
end

--- Get the world marker element (nil before the HUD is built)
local function get_world_markers_element()
	local ui_manager = Managers.ui
	local hud = ui_manager and ui_manager:get_hud()

	return hud and hud:element("HudElementWorldMarkers") or nil
end

--- Register the template into the element (idempotent; the engine creates markers
--- by template name)
local function register_template(element)
	local templates = element and element._marker_templates

	if templates and templates[MARKER_TYPE] ~= MarkerTemplate then
		templates[MARKER_TYPE] = MarkerTemplate
	end
end

-- Exported for the main file to call in the HudElementWorldMarkers.init hook
MarkerSync.register_templates = register_template

local function remove_marker_by_id(id)
	pcall(function()
		Managers.event:trigger("remove_world_marker", id)
	end)
end

--- Refresh the engine-side template clone fields of a single marker
local function refresh_marker_template(marker, settings)
	local template = marker.template

	if not template then
		return
	end

	template.max_distance = (settings.max_distance or 50) + MAX_DISTANCE_MARGIN
	template.scale_settings = settings.scale_by_distance and SCALE_SETTINGS or nil
end

--- Sync the target list (indicators' per-fixed-frame output)
function MarkerSync.sync(targets)
	local element = get_world_markers_element()

	if not element or not element._markers_by_id then
		-- No HUD: the engine already reclaimed all markers when it destroyed the
		-- element, just clear the local records
		for unit in pairs(_unit_markers) do
			_unit_markers[unit] = nil
		end

		_element = nil

		return
	end

	_element = element

	register_template(element)

	local markers_by_id = element._markers_by_id
	local settings = mod.indicator_settings or {}
	local seen = {}

	for i = 1, #targets do
		local target = targets[i]
		local unit = target.unit

		if unit then
			local entry = _unit_markers[unit]
			local marker = entry and markers_by_id[entry.id] or nil

			if entry and not marker then
				-- Reclaimed on the engine side (HUD rebuild etc.), recreate
				_unit_markers[unit] = nil
				entry = nil
			end

			if not entry and target.linger then
				-- Lingering fading target whose marker is gone: do not recreate (it is
				-- fading out, recreating would flash)
				entry = nil
			elseif not entry then
				local pos = target_position(target)

				if pos then
					local data = {
						color = target.color,
						size = target.size,
						stack_alpha = target.stack_alpha,
						visible = target.visible,
					}
					local new_id

					Managers.event:trigger("add_world_marker_position",
						MARKER_TYPE, pos, function(id)
							new_id = id
						end, data)

					if new_id then
						entry = {
							id = new_id,
							data = data,
						}
						_unit_markers[unit] = entry
						marker = markers_by_id[new_id]
					end
				end
			end

			if entry and marker then
				-- Update the data in place (lingering targets too: their fade alpha);
				-- positions are not written here -- fixed-frame writes would fight with
				-- the render-frame refresh and cause cadence jitter. Positions are owned
				-- by the render-frame pre-hook (update_positions), zero-lag every frame
				local data = entry.data

				data.color = target.color
				data.size = target.size
				data.stack_alpha = target.stack_alpha
				data.visible = target.visible

				refresh_marker_template(marker, settings)
			end

			seen[unit] = entry
		end
	end

	-- Markers off the list (and not lingering): no data source at render frame
	-- anymore, remove immediately; lingering targets still appear in targets and
	-- their markers were reused/updated above
	for unit, entry in pairs(_unit_markers) do
		if not seen[unit] then
			remove_marker_by_id(entry.id)
			_unit_markers[unit] = nil
		end
	end
end

--- Render-frame position refresh: only writes the latest aim points into existing
--- markers (called at render rate by the main module's HudElementWorldMarkers.update
--- hook, no event/creation overhead; vectors are built from scalars in the render
--- frame, no cross-phase object reuse)
function MarkerSync.update_positions(targets)
	local markers_by_id = _element and _element._markers_by_id

	if not markers_by_id then
		return
	end

	for i = 1, #targets do
		local target = targets[i]
		local entry = target.unit and _unit_markers[target.unit]

		if entry then
			local marker = markers_by_id[entry.id]

			if marker then
				local pos = target_position(target)

				if pos then
					Vector3Box.store(marker.world_position, pos)
				end
			end
		end
	end
end

--- Remove all of this mod's markers (session switch / mod disable)
function MarkerSync.clear()
	for unit, entry in pairs(_unit_markers) do
		remove_marker_by_id(entry.id)
		_unit_markers[unit] = nil
	end
end

--- Current marker count (debugging)
function MarkerSync.count()
	local num = 0

	for _ in pairs(_unit_markers) do
		num = num + 1
	end

	return num
end

return MarkerSync
