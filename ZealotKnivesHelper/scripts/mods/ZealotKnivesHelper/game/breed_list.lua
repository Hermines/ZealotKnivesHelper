--[[
	Enemy breed list (game side)

	Builds the boss/elite/specialist breed name lists from the game's breeds settings;
	consumed by the data file to generate setting widgets dynamically and by the main
	module to build the breed config.
]]

local Breed = require("scripts/utilities/breed")
local Breeds = require("scripts/settings/breed/breeds")

local BreedList = {}

local function collect()
	local result = {
		boss = {},
		elite = {},
		special = {},
	}

	for breed_name, breed_data in pairs(Breeds) do
		if Breed.is_minion(breed_data) and breed_data.unit_template_name == "minion" and breed_data.faction_name ~= "imperium" then
			if breed_data.is_boss then
				result.boss[#result.boss + 1] = breed_name
			elseif breed_data.tags and breed_data.tags.elite then
				result.elite[#result.elite + 1] = breed_name
			elseif breed_data.tags and breed_data.tags.special then
				result.special[#result.special + 1] = breed_name
			end
		end
	end

	for _, list in pairs(result) do
		table.sort(list)
	end

	return result
end

BreedList.categories = collect()

--- Category of a breed name, nil when it is not in the three categories
function BreedList.category_of(breed_name)
	local categories = BreedList.categories

	for _, category in ipairs({ "boss", "elite", "special" }) do
		for _, name in ipairs(categories[category]) do
			if name == breed_name then
				return category
			end
		end
	end

	return nil
end

return BreedList
