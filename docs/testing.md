# Testing

We use [Jest Lua](https://jsdotlua.github.io/jest-lua/) — the framework Roblox
uses internally, and the successor to TestEZ.

## Where tests live

`tests/`, mirroring the shape of `src/`:

```
tests/
  jest.config.luau          testMatch — do not rename spec files without updating this
  TestRunner.server.luau    runs the suite when you press Play in Studio
  shared/
    Config.spec.luau
    Logger.spec.luau
```

Rojo maps `tests/` to `ServerScriptService.Tests`, and only in
`default.project.json` — the production build in `build.project.json` has no
tests in it.

A test file is named `<Thing>.spec.luau`. Jest matches `**/*.spec`, so the name
matters.

## Writing one

```lua
--!strict
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local JestGlobals = require(ReplicatedStorage.DevPackages.JestGlobals)
local Thing = require(ReplicatedStorage.Shared.Thing)

local describe = JestGlobals.describe
local expect = JestGlobals.expect
local it = JestGlobals.it

describe("Shared.Thing", function()
	it("does the thing", function()
		expect(Thing.compute(2)).toBe(4)
	end)
end)
```

Test the logic, not the engine. The highest-value tests here are for pure
functions: validation, formulas, state transitions, data shaping. Something that
needs three players and a physics step is an integration test you should
play-test, not a unit test.

## Running them in Studio

**One-time setup per machine.** Jest needs Studio's `FFlagEnableLoadModule`
flag, which is off by default:

1. Close Roblox Studio.
2. Create or edit `ClientAppSettings.json` in your Studio install folder:
   - Windows: `%LOCALAPPDATA%\Roblox\Versions\<version>\ClientSettings\`
   - macOS: `~/Library/Application Support/Roblox/Versions/<version>/ClientSettings/`
   (Create the `ClientSettings` folder if it does not exist.)
3. Put this in it:
   ```json
   { "FFlagEnableLoadModule": "True" }
   ```
4. Reopen Studio.

That file is machine-specific and gitignored — never commit it. You will need to
redo this after a Studio version update, because the path contains the version.

**Every time:**

1. `rojo serve`, connect the plugin.
2. Press **Play** in Studio.
3. Results appear in the Output window. `TestRunner` only runs in Studio, so
   nothing test-related executes in a live server.

If you see `DevPackages is missing`, run `wally install` and reconnect Rojo.

## Running them in CI

Jest Lua only runs inside Roblox, and CI has no Roblox Studio. The supported way
to run tests headlessly is Roblox's **Open Cloud Luau Execution API**, which
executes a script inside a real Roblox server against a place you upload. That
is what `.github/workflows/roblox-tests.yml` does.

Until it is configured, the workflow skips and every-PR confidence comes from the
`CI` workflow: formatting, linting, type-checking, project validation and a real
build of both project files.

### Configuring it

You need a place that is **not** your live game, so a failed test run cannot
touch players.

1. In Studio, create a new place inside the same universe as the game
   (**File → Publish to Roblox**, same experience, new place). Call it
   `medieval-game-ci`.
2. Note its **place ID** and the **universe ID**.
3. At [create.roblox.com/credentials](https://create.roblox.com/credentials),
   create an API key with:
   - `universe-places:write` — scoped to that universe
   - `universe.place.luau-execution-session:write` — scoped to that universe
   Restrict it by IP if your team can; otherwise leave it open and rotate it if
   it ever leaks.
4. In the repository: **Settings → Secrets and variables → Actions**
   - Secret `ROBLOX_OPEN_CLOUD_KEY` — the API key
   - Variable `ROBLOX_UNIVERSE_ID` — the universe ID
   - Variable `ROBLOX_TEST_PLACE_ID` — the CI place ID
5. Run the workflow manually (**Actions → Roblox tests → Run workflow**) and
   watch it. **Do not make it a required status check until you have seen it
   pass at least once** — it has never run against your universe before.

Running it locally is the same, with the values in your shell:

```bash
rojo build default.project.json --output build/test-place.rbxl
ROBLOX_OPEN_CLOUD_KEY=... ROBLOX_UNIVERSE_ID=... ROBLOX_TEST_PLACE_ID=... \
  lune run scripts/open-cloud-tests
```

Never put those values in a file inside the repository.
