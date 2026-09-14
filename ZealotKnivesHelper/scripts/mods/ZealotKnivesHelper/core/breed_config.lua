--[[
	Breed config resolution (pure functions, no engine dependency, unit-testable
	with luajit)

	"Show this breed's dot" = category toggle AND breed toggle
	"Dot color"             = breed color, or the category color when the breed's
	                          "use custom color" toggle is off (the main module
	                          stores nil for such breeds)

	Config (built from cached DMF settings by the main module):
	  category_show  { boss = bool, elite = bool, special = bool }
	  category_color { boss = {a,r,g,b}, ... }
	  breed_show     { [breed_name] = bool }          missing means true
	  breed_color    { [breed_name] = {a,r,g,b} }     missing/nil falls back to the
	                                                  category color
]]

local BreedConfig = {}

--- Whether this breed's indicator dot should be shown
---@param breed_name string
---@param category string "boss" | "elite" | "special"
---@param config table
---@return boolean
function BreedConfig.is_shown(breed_name, category, config)
	if not config or not config.category_show or not config.category_show[category] then
		return false
	end

	local breed_show = config.breed_show

	if breed_show and breed_show[breed_name] == false then
		return false
	end

	return true
end

--- Color of this breed's indicator dot (DMF color format {a, r, g, b}, 0-255)
---@param breed_name string
---@param category string
---@param config table
---@return table
function BreedConfig.color(breed_name, category, config)
	if config then
		local breed_color = config.breed_color

		if breed_color and breed_color[breed_name] then
			return breed_color[breed_name]
		end

		local category_color = config.category_color

		if category_color and category_color[category] then
			return category_color[category]
		end
	end

	-- Fallback color: white
	return { 255, 255, 255, 255 }
end

return BreedConfig
