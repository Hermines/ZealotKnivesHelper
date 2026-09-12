return {
	run = function()
		fassert(rawget(_G, "new_mod"), "`ZealotKnivesHelper` encountered an error loading the Darktide Mod Framework.")

		new_mod("ZealotKnivesHelper", {
			mod_script       = "ZealotKnivesHelper/scripts/mods/ZealotKnivesHelper/ZealotKnivesHelper",
			mod_data         = "ZealotKnivesHelper/scripts/mods/ZealotKnivesHelper/ZealotKnivesHelper_data",
			mod_localization = "ZealotKnivesHelper/scripts/mods/ZealotKnivesHelper/ZealotKnivesHelper_localization",
		})
	end,
	packages = {},
}
