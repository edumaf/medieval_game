--!strict
--[[
	Bootstrap — starts a folder of lifecycle modules.

	Both entry points (src/server and src/client) hand a folder to `run`. Every
	ModuleScript directly inside that folder is required once and may export two
	optional hooks:

	  Init()   Runs first, for every module, before any Start() runs.
	           MUST NOT yield. MUST NOT assume another module is initialised.
	           Use it to register handlers and build local state.

	  Start()  Runs afterwards, each in its own thread, so it MAY yield.
	           Anything that talks to another system belongs here.

	That two-phase split is the whole reason this file exists: it removes
	load-order bugs without needing a dependency-injection framework.

	Nested folders are ignored on purpose. Put helper modules a system owns in a
	subfolder next to it and the lifecycle will leave them alone.
]]

local Types = require(script.Parent.Parent.Types)

local Bootstrap = {}

--[[
	Requires and starts every lifecycle module directly under `container`.
]]
function Bootstrap.run(container: Instance)
	local names: { string } = {}
	local modules: { [string]: Types.LifecycleModule } = {}

	for _, child in container:GetChildren() do
		if child:IsA("ModuleScript") then
			table.insert(names, child.Name)
			modules[child.Name] = require(child) :: any
		end
	end

	-- Alphabetical, so boot order is identical on every machine and in every
	-- Studio session. A load-order bug should never be intermittent.
	table.sort(names)

	for _, name in names do
		local init = modules[name].Init
		if init then
			init()
		end
	end

	for _, name in names do
		local start = modules[name].Start
		if start then
			task.spawn(start)
		end
	end
end

return Bootstrap
