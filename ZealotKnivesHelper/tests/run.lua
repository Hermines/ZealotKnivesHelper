--[[
	Test entry point: luajit tests/run.lua
]]

local H = dofile("tests/helpers.lua")

print("ZealotKnivesHelper test suite")
print("===========================")
print("")

dofile(H.test_root .. "/test_ballistics.lua")
dofile(H.test_root .. "/test_target_filter.lua")
dofile(H.test_root .. "/test_breed_config.lua")
dofile(H.test_root .. "/test_stack_fade.lua")
dofile(H.test_root .. "/test_marker_drawing.lua")
dofile(H.test_root .. "/test_indicators.lua")
dofile(H.test_root .. "/test_module_loading.lua")

local passed, failed = H.report()

print("===========================")

if failed == 0 then
	print("All passed: " .. passed .. " assertions/cases")
	os.exit(0)
else
	print("Failures: " .. failed .. " / " .. (passed + failed) .. " total")
	os.exit(1)
end
