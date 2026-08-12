--!strict
--[[
	Jest configuration.

	testMatch is matched against instance names. Rojo turns `Config.spec.luau`
	into a ModuleScript named `Config.spec`, so this pattern picks up every file
	named `*.spec.luau` anywhere under ServerScriptService.Tests.
]]

return {
	testMatch = { "**/*.spec" },
}
