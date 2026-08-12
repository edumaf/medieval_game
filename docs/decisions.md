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

TestEZ still works but is in maintenance — Roblox itself moved to Jest Lua, which
is actively developed and is what their internal code, Studio plugins and
first-party libraries are tested with.

The cost is that **Jest Lua only runs inside Roblox.** It cannot run in Lune or
any standalone Luau runtime. That shapes our CI (below) and it is the reason we
did not pick a Lune-native test framework instead: a runner that only executes
Roblox-free code would quietly exclude most of the game.

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
`DevPackages` so you can run the suite by pressing Play. `build.project.json` is
the production project and contains neither. CI builds both, so a mapping that
breaks one and not the other cannot merge.

## `emitLegacyScripts: false`

Rojo emits `Script` instances with a `RunContext` (`Client`/`Server`) instead of
the deprecated `LocalScript`. If you are used to seeing `LocalScript` in
StarterPlayerScripts and see `Script` instead, this is why — it is correct and
it runs on the client.
