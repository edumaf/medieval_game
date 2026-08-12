# Testing

We use [Jest Lua](https://jsdotlua.github.io/jest-lua/) — the framework Roblox
uses internally, and the successor to TestEZ.

There are three distinct testing paths in this repository. Know which one
you're running:

| Path | What it tests | How | When |
| --- | --- | --- | --- |
| **Unit tests** | Pure logic in `src/shared`, `src/server`, `src/client` | The Studio Jest plugin | Every change |
| **Integration / gameplay tests** | Multiplayer, replication, UI, input, networking | Pressing **Play** in Studio, by hand | Every change |
| **CI tests** | The same Jest suite as local unit tests | Open Cloud, in GitHub Actions | Every PR |

Play mode is **not** a way to run Jest. See "Running them locally" below for
why, and "Gameplay testing" in the README for what Play mode is actually for.

## Where tests live

`tests/`, mirroring the shape of `src/`:

```
tests/
  jest.config.luau          testMatch — do not rename spec files without updating this
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

## Running them locally

**Not with Play mode.** Jest's per-test module isolation calls
`debug.loadmodule`, which reads a ModuleScript's `Source` property. Roblox's
Script Capabilities model gates that behind the `PluginOrOpenCloud`
capability, which an ordinary Play-mode script never has — flipping
`FFlagEnableLoadModule` does not change this, because the flag only controls
whether `debug.loadmodule` exists, not whether the calling script is
authorized to use it. A `Script` under `ServerScriptService` during Play mode
is neither a plugin nor an Open Cloud session, so it fails with:

```
The current thread cannot read 'Source' (lacking capability PluginOrOpenCloud)
```

before a single test runs. This is why `tests/TestRunner.server.luau` was
removed — it could not have worked, on any machine, regardless of Studio
flags.

**Use the Studio plugin instead.** A plugin runs with the capability Jest
needs, which is why Roblox's own internal Jest tooling also runs tests from a
Studio plugin rather than Play mode. It requires the exact same
`ServerScriptService.Tests` and `ReplicatedStorage.DevPackages.Jest` Rojo
already syncs — it is not a second test system, it runs the real project.

**One-time setup per machine:**

```bash
lune run scripts/install-test-plugin
```

This copies `plugin/JestRunner.luau` into your local Roblox Plugins folder.
See [`plugin/README.md`](../plugin/README.md) if you need to install it by
hand, or if the installer does not recognise your platform. Restart Studio
afterwards, and re-run the installer any time `plugin/JestRunner.luau`
changes.

**Every time:**

1. `rojo serve`, connect the plugin, so `ReplicatedStorage.DevPackages` and
   `ServerScriptService.Tests` are present.
2. **Plugins** tab → **Medieval Game Tests** → **Run Tests**.
3. Results appear in the Output window.

If you see `ReplicatedStorage.DevPackages is missing`, run `wally install` and
reconnect Rojo. The button also refuses to run while you are in Play mode — it
tests the Edit-mode project, not the live session, so running both together
would be misleading rather than useful.

## Running them in CI

Jest Lua only runs inside Roblox, and CI has no Roblox Studio. The supported way
to run tests headlessly is Roblox's **Open Cloud Luau Execution API**, which
executes a script inside a real Roblox server against a place you upload. That
is what `.github/workflows/roblox-tests.yml` does.

Until it is configured, the workflow skips and every-PR confidence comes from the
`CI` workflow: formatting, linting, type-checking, project validation and a real
build of both project files.

> `scripts/open-cloud-tests.luau` had transport-level bugs fixed early on: the
> polling loop checked for a `"QUEUED"` task state that does not exist in the
> current API, and the result parser read `output.returnValues` where
> Roblox's own reference implementation reads `output.results`. Once this was
> actually configured and run for real, the workflow correctly reached the
> Roblox execution session and uploaded/executed the place — but Jest itself
> then failed inside the session. See below.

### Why Jest needs `ServerScriptService.LoadStringEnabled`

Jest's module loader (`jest-runtime`) tries two mechanisms to load a test
module in its own isolated environment, in order:

1. `debug.loadmodule` — needs the `PluginOrOpenCloud` capability (see above)
   *and* Studio's `FFlagEnableLoadModule`, which only exists on a developer's
   local Studio install. Open Cloud's headless execution servers have no way
   for a developer to set that flag, so this path is unavailable there.
2. `loadstring(source, chunkName)` — jest-runtime's own fallback for exactly
   this situation, added in 3.10.0. `loadstring` is disabled by default for
   *every* server script on Roblox (`ServerScriptService.LoadStringEnabled`
   defaults to `false`) — including inside an Open Cloud execution session,
   which loads and runs the uploaded place under normal server rules. With
   both mechanisms unavailable, Jest fails with `loadstring() is not
   available` before a single test runs.

The fix is **not** a Jest, Wally, or version change — 3.10.0 is the current
release and its two-tier fallback is already the correct design; the second
tier just needs to be switched on for this one, dev-only place.
`default.project.json`'s `ServerScriptService` now sets
`$properties.LoadStringEnabled: true`, which Rojo bakes into
`build/test-place.rbxl` (and the local `build/dev.rbxl`). `build.project.json`
— the actual production place — is untouched and still defaults to `false`;
nothing in this codebase calls `loadstring` outside of Jest's own fallback,
and Jest is never part of a production build (`build.project.json` has no
`Tests` or `DevPackages` mapping at all). See `docs/decisions.md`.

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
