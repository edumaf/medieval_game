# Tooling decisions

Why the stack looks the way it does. Read this before proposing a change to it.

## No game framework (no Knit, no Flamework)

We use plain Luau modules plus a ~50-line `Bootstrap` that runs `Init()` then
`Start()` (`src/shared/Runtime/Bootstrap.luau`).

Frameworks like Knit mainly buy you service discovery, lifecycle ordering and
automatic remote wiring. With five people and no shipped systems yet, that trade
is bad: a framework adds a layer every new contributor and every AI session has
to learn, changes how stack traces read, and pins us to someone else's release
cadence. The two-phase lifecycle removes the only problem we actually have
(load order), and `src/shared/Net` handles remotes explicitly, which we want
anyway — every hole in the client/server boundary should be visible in one file.

Revisit this if we end up hand-writing the same service plumbing in ten places.

## Rokit, not Foreman or Aftman

Rokit is the current toolchain manager from the Rojo organisation and supersedes
Foreman and Aftman, both of which are effectively unmaintained. One `rokit.toml`
pins every tool, and `rokit install` reproduces the exact set on any machine.

## Wally for packages

Wally is still the Roblox package manager with a real public registry and the
one Jest Lua ships to. Its last release is older than the rest of our stack, but
it works, the format is stable, and there is no maintained replacement with a
comparable registry. We keep the dependency list near-empty, so our exposure is
small.

`wally-package-types` is a required companion, not an optional extra: Wally's
generated link files drop exported types, so without it every package resolves
to `any` and our strict type-checking gate becomes decorative.

## Jest Lua for tests, not TestEZ

TestEZ was archived by Roblox in September 2024 — it still works, but gets no
further fixes. Roblox itself moved to Jest Lua, which is actively developed
and is what their internal code, Studio plugins and first-party libraries are
tested with.

The cost is that **Jest Lua only runs inside Roblox.** It cannot run in Lune or
any standalone Luau runtime. That shapes our CI (below) and it is the reason we
did not pick a Lune-native test framework instead: a runner that only executes
Roblox-free code would quietly exclude most of the game.

TestEZ's classic `require()`-based runner would have sidestepped the Script
Capabilities problem below entirely, since it never reads a script's `Source`
property. We considered it and stayed on Jest anyway: trading a maintained,
Roblox-standard framework for an archived one to dodge a solvable transport
problem is the wrong trade for a test suite this team will build on for years.
See the next section for the transport we picked instead.

## Jest runs locally through a Studio plugin, not Play mode

Jest's per-test module isolation calls `debug.loadmodule`, which reads a
ModuleScript's `Source` property. Roblox's Script Capabilities model gates
`Source` reads behind the `PluginOrOpenCloud` capability, which an ordinary
Play-mode `Script` never has — no Studio flag changes this, because
`FFlagEnableLoadModule` only controls whether `debug.loadmodule` exists, not
whether the calling script is authorized to use it. An earlier version of this
repository ran Jest from `tests/TestRunner.server.luau` on Play; it could not
have worked, on any machine, and was removed.

A Studio plugin does carry `PluginOrOpenCloud`, which is why Roblox's own
internal Jest tooling also runs tests from a plugin connected to a running
Studio session rather than from Play mode. `plugin/JestRunner.luau` does the
same thing at a much smaller scale: a toolbar button that requires the same
`ServerScriptService.Tests` and `ReplicatedStorage.DevPackages.Jest` Rojo
already syncs, and calls `Jest.runCLI` against them. It is not a second test
system — it runs the real, currently-synced project, the same way the removed
Play-mode runner did.

It is a hand-written ~150-line script rather than a third-party tool
(`jest-roblox-cli` and similar exist) because the whole point of this
plugin is small and legible: one file, no build step, installed by copying it
into Studio's Plugins folder. Revisit this if the team ends up wanting
coverage reports, watch mode, or other features that are genuinely hard to
hand-roll.

## Tests in CI run through Open Cloud, not a Roblox Studio session

CI cannot launch Roblox Studio, and Jest cannot run outside Roblox. The
supported way out is Roblox's Open Cloud **Luau Execution API**, which runs a
script inside a real headless Roblox server against a place you upload. That is
what `.github/workflows/roblox-tests.yml` and `scripts/open-cloud-tests.luau`
do, and it mirrors Roblox's own `place-ci-cd-demo` reference flow.

It needs an API key and a throwaway test place, so it is a separate, opt-in
workflow. Until it is configured, every-PR confidence comes from the checks that
need no Roblox at all — formatting, linting, **type-checking**, project
validation and a real `rojo build` of both project files. Those catch the large
majority of breakages in a typed Luau codebase.

## Lune for repository scripts

Repository automation is written in Luau and run by Lune rather than in Bash or
Python, so there is one language in the repository and every contributor can
read the tooling. Lune is the standard standalone Luau runtime and is installed
by Rokit like everything else.

## Two Rojo project files

`default.project.json` is the development project: it includes `tests/` and
`DevPackages` so the Studio Jest plugin and the Open Cloud workflow can find
them. `build.project.json` is the production project and contains neither. CI
builds both, so a mapping that breaks one and not the other cannot merge.

## `emitLegacyScripts: false`, except `src/client`

Rojo emits `Script` instances with a `RunContext` (`Client`/`Server`) instead of
the deprecated `LocalScript`. If you are used to seeing `LocalScript` in
StarterPlayerScripts and see `Script` instead, this is why — it is correct and
it runs on the client.

`src/client` is the one deliberate exception, via the nested
`src/client.project.json` (root `emitLegacyScripts` is untouched — this is
scoped to that one subtree only). Roblox copies every Starter container's
contents into each player's `PlayerScripts`, so a `RunContext`-based `Script`
parented directly under `StarterPlayerScripts` runs twice: once as the
template Roblox left in place, once as the copy it made. Roblox's own current
guidance (`Script types and locations` in the Creator Docs) is explicit about
this and prescribes a `LocalScript` for exactly this container, so that is
what `src/client.project.json` produces. `ServerScriptService.Server` is not
a Starter container and is not affected — it stays `Script` with
`RunContext = Server`.

We looked at nesting the client script one level deeper inside
`StarterPlayerScripts` instead, since the Studio warning text only mentions a
script "parented to a container." We could not find anything confirming that
depth changes Roblox's copy-and-run behavior (as opposed to just the
warning), so we did not rely on it.
