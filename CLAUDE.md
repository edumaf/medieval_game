# CLAUDE.md

Project context for Claude Code. Read this before touching anything.

## What this is

A collaborative Roblox game (medieval theme), built by a small team: three
developers, one UI designer, one builder. Written in Luau, synced into Roblox
Studio with Rojo. The filesystem is the source of truth for code; the Roblox
place file is the source of truth for the map and UI layout.

**No gameplay systems exist yet.** The repository currently contains the
architecture, tooling and a minimal boot path that proves it works.

## Source tree

```
src/shared/     ReplicatedStorage.Shared   types, config, utilities, remote declarations
  Types.luau            types crossing the client/server boundary
  Config.luau           frozen tunables — nothing secret, clients can read it
  Net/                  remote registry; Remotes.luau declares every remote
  Runtime/Bootstrap     Init()/Start() lifecycle runner
  Util/Logger           scoped logging — use this, not bare print
src/server/     ServerScriptService.Server        authoritative gameplay
  init.server.luau      entry point; Net.build() then Bootstrap.run
  Services/             one file per system
src/client/     StarterPlayerScripts.Client       presentation and input
  init.client.luau      entry point
  Controllers/          one file per system, including UI logic
tests/          ServerScriptService.Tests (dev project only)   Jest specs
scripts/        Lune scripts for repository automation — not game code
docs/           architecture, workflows, tooling decisions
assets/         reviewable assets only; the map is NOT here
```

`docs/architecture.md` has the full picture. Read it before adding a system.

## Tooling

Managed by **Rokit** (`rokit.toml`, exact pins). Never suggest installing a tool
globally or changing a pin without being asked.

| Tool | Used for |
| --- | --- |
| Rojo | filesystem → Studio sync, sourcemaps, `rojo build` |
| Wally | packages (`wally.toml`, committed `wally.lock`) |
| wally-package-types | restores Luau types Wally strips from package links |
| Selene | linting (`selene.toml`) |
| StyLua | formatting (`stylua.toml`) — authoritative, do not hand-format |
| luau-lsp | `analyze` type-check gate |
| Lune | runs `scripts/` |
| Jest Lua | tests — **runs only inside Roblox**, never in Lune |

## Commands

Run after any code change:

```bash
stylua src tests scripts                       # format (do this first)
selene src tests scripts                       # lint
rojo sourcemap default.project.json --output sourcemap.json
luau-lsp analyze --platform=roblox --sourcemap=sourcemap.json \
  --definitions=.tooling/globalTypes.d.luau --base-luaurc=.luaurc \
  --ignore="**/Packages/**" --ignore="**/DevPackages/**" src tests
lune run scripts/validate-project              # Rojo mappings, pins, lockfile
rojo build default.project.json --output build/dev.rbxl
```

Setup, if the working copy is fresh or manifests changed:

```bash
rokit install
wally install
rojo sourcemap default.project.json --output sourcemap.json
wally-package-types --sourcemap sourcemap.json DevPackages/   # once per install
lune run scripts/fetch-global-types
```

`wally-package-types` is not idempotent — run `wally install` again before
re-running it, never twice in a row.

You **cannot** run the test suite — Jest Lua only runs inside Roblox Studio or
via the Open Cloud workflow. Write tests, then tell the human to run them.
Never claim tests passed.

## Coding rules

- Luau only, `.luau` extension, `--!strict` at the top of every file.
- Type the boundaries: function parameters, return types, and anything crossing
  client/server. Do not annotate every local.
- No global state. `_G` and `shared` are lint errors. State lives in module-local
  variables.
- One system per module. When a module does two things, split it.
- Reuse `Shared/Util` and `Shared/Types` before writing a new helper. Check
  whether it already exists.
- No new dependency without explaining what it does that fifty lines cannot, and
  which realm it belongs in.
- Comment *why*, not *what*. Match the density of the surrounding file.
- Follow the `Init()` / `Start()` contract: `Init` never yields and never
  depends on another module; cross-system work goes in `Start`.

## Roblox rules

- **The server is authoritative** over currency, inventory, damage, progression,
  rewards, purchases and any state a player could profit from. The client
  proposes; the server decides.
- **Every RemoteEvent and RemoteFunction handler validates its arguments** —
  types, ranges, ownership, permission, rate. Assume every client is running
  modified code. `Net` resolves instances; it validates nothing.
- Nothing secret in `src/shared`. `ReplicatedStorage` is fully visible to
  clients. Drop tables, economy formulas and anti-cheat thresholds go in a
  server-only module.
- Declare remotes in `src/shared/Net/Remotes.luau`. Never `Instance.new` a
  remote elsewhere.
- Do not send a remote per frame. Batch, or send on state change.
- Every `Connect` needs a matching disconnect, and every per-player table needs
  clearing on `PlayerRemoving`. Leaks are the default failure mode here.
- Prefer events to polling. `RunService.Heartbeat` needs a justification.
- Do not micro-optimise code that does not exist yet.

## Git rules

- Check `git status` and `git branch --show-current` before changing anything.
  Uncommitted work may be in progress.
- Never commit to `main`. Work on `feature/`, `fix/`, `refactor/` or `chore/`
  branches.
- Never force-push, reset, rebase shared history, delete branches, or discard
  someone's uncommitted changes.
- Never commit secrets: API keys, `.ROBLOSECURITY`, Open Cloud keys, `.env`.
  If you need a value at runtime, read it from the environment and document it.
- Do not commit generated output: `Packages/`, `DevPackages/`, `sourcemap.json`,
  `.tooling/`, `build/`, `roblox.yml`, `*.rbxl`.
- Commit `wally.toml` and `wally.lock` together, never one alone.

## Working in this repository

- **Inspect before implementing.** Read the existing architecture and find the
  systems you should be extending. Say what you found.
- **Reuse, do not duplicate.** A second logger, a second remote registry or a
  second lifecycle runner is a bug, not a feature.
- **Do not refactor unrelated code** while implementing something. If you spot a
  problem elsewhere, mention it and leave it.
- **Do not create placeholder systems** unless they carry architectural weight.
  Empty folders and stub modules are noise.
- **Prefer the simplest thing that still scales.** No new abstraction layer
  until there is duplication to remove.
- **Verify before asserting.** Roblox APIs and this toolchain change. If you are
  unsure whether something still exists or still behaves that way, check current
  documentation rather than recalling it.
- **Run the validation commands above** after changing code, and fix what they
  report.
- **Report precisely**: what you changed, which commands you ran, what passed,
  what you could not verify. Never describe an unrun check as passing.

## Things that will trip you up

- Rojo syncs **one way**, filesystem → Studio. Edits made in Studio inside
  `Shared`, `Server`, `Tests` or `Client` are destroyed on the next sync.
- The map, terrain and `StarterGui` are **not** in this repository and never
  will be. Do not generate map geometry or build UI layout in code.
- `emitLegacyScripts` is off, so `.client.luau` becomes a `Script` with
  `RunContext = Client`, not a `LocalScript`. That is intentional.
- `tests/` and `DevPackages` exist only in `default.project.json`.
  `build.project.json` is the production tree.
