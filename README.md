# Medieval Game

A collaborative Roblox game built by a small team, with code in Git and the
world in Roblox Studio.

**The game is playable, barely.** You can run, punch someone for 25 damage,
parry a punch coming at your front, and die. That is the whole of it — see
[What exists so far](#what-exists-so-far).
Everything else here is the foundation those systems were built on: the
architecture, the toolchain, the tests, the CI, and the conventions. This README
is the onboarding guide — if you follow it top to bottom you will end up with a
working development environment and your first pull request merged, without
asking anyone.

---

## Contents

- [Project overview](#project-overview)
- [What exists so far](#what-exists-so-far)
- [Development philosophy](#development-philosophy)
- [Tech stack](#tech-stack)
- [Repository structure](#repository-structure)
- [Setup](#setup)
  - [1. Install Git](#1-install-git)
  - [2. Install Roblox Studio](#2-install-roblox-studio)
  - [3. Install Rokit](#3-install-rokit)
  - [4. Clone the repository](#4-clone-the-repository)
  - [5. Install the project toolchain](#5-install-the-project-toolchain)
  - [6. Install dependencies](#6-install-dependencies)
  - [7. Fetch the Roblox API definitions](#7-fetch-the-roblox-api-definitions)
  - [8. Install the Rojo Studio plugin](#8-install-the-rojo-studio-plugin)
  - [9. Configure your editor](#9-configure-your-editor)
  - [10. Install Claude Code](#10-install-claude-code-optional)
- [Running the project](#running-the-project)
- [Git vs Roblox Studio: who owns what](#git-vs-roblox-studio-who-owns-what)
- [Working on the map](#working-on-the-map)
- [Working on UI](#working-on-ui)
- [Working on code](#working-on-code)
- [Using Claude Code](#using-claude-code)
- [The development workflow](#the-development-workflow)
  - [Creating a feature branch](#creating-a-feature-branch)
  - [Making changes](#making-changes)
  - [Running validation](#running-validation)
  - [Committing](#committing)
  - [Pushing](#pushing)
  - [Opening a pull request](#opening-a-pull-request)
  - [Code review](#code-review)
  - [Merging](#merging)
  - [Updating your local repository](#updating-your-local-repository)
- [A complete example session](#a-complete-example-session)
- [Testing](#testing)
- [Dependency management](#dependency-management)
- [Security](#security)
- [Troubleshooting](#troubleshooting)
- [Development rules](#development-rules)

---

## Project overview

A medieval-themed Roblox experience. The team is three developers, one UI
designer and one builder. Everyone works on short-lived branches off `main` and
merges through reviewed pull requests.

The architecture is designed to absorb the systems we know are coming —
inventory, quests, NPCs, enemies, progression, currencies, player data — without
being rebuilt. Combat has started; the rest is still ahead.

## What exists so far

Enough to fight someone. Not enough to call it a game yet.

### Controls

| Input | Does |
| --- | --- |
| **Left click** | Throw a punch — 25 damage, ~4.5 studs, 120° cone in front of you |
| **Left Shift** (hold) | Sprint (16 → 24 walkspeed) — costs stamina while you are moving |
| **Q** (hold) | Parry — blocks punches from your front half, slows you to 8 walkspeed, costs stamina |
| `/damage <n>`, `/heal <n>` | Developer-only test commands (see [Testing](#testing)) |

### Systems

| System | Where | What it does |
| --- | --- | --- |
| **Health** | `HealthService` + `HealthBarController` | 100 HP, server-authoritative, on-screen bar, death and respawn |
| **Punch combat** | `CombatService` + `PunchController` + `PunchRules` | Left click, animated swing, server decides who was hit |
| **Parry** | `ParryService` + `ParryController` + `ParryState` | Hold Q, animated guard, server decides whether it stopped the punch |
| **Sprinting** | `RunningController` + `SprintState` | Hold Shift; the speed is applied client-side, the intent is reported to the server (see `docs/decisions.md`) |
| **Stamina** | `StaminaService` + `StaminaState` + `StaminaController` + `StaminaBarController` | 100-point pool, server-authoritative, spent by sprinting, parrying and punching, on-screen bar |
| **Screen effects** | `ScreenEffectsController` + `ScreenEffectState` | Red vignette when hit, green when healed, a stronger spreading red on death, near-black when stamina runs out |
| **Combat & health audio** | `Shared/Util/Audio` + the systems that own each event | Punch swing fitted to the animation, impact from the target's root part, damage/heal stings on the vignette's own envelope |
| **Session** | `SessionService` + `SessionController` | Boot handshake, detects a client on a stale build |

Everything a player could profit from lying about — health, damage, who got hit
— is decided on the server. The punch remote carries **no arguments at all**:
the client says "I swung," and the server works out the rest from its own view
of where everyone is standing.

### Things worth knowing if you are about to touch combat

- **The punch's timing comes from the animation, not from a timer.** The swing
  has a `Hit` marker on the frame the fist connects, and that marker is what
  fires the request. Re-exporting the animation without that marker stops
  punches landing, silently.
- **There is lag compensation.** A target running away is drawn nearer on the
  attacker's screen than it really is on the server, which used to make chase
  punches miss. `PunchRules.perceivedDistance` gives some of that back, capped
  so it cannot become a ranged attack.
- **The parry has the same timing story, and the same silent failure.** Holding
  Q winds up a guard; the `Hold` marker on the parry animation is what actually
  makes you protected, and the track is frozen there while you hold the key.
  A missing or renamed marker leaves you slowed and unable to punch but never
  protected, with nothing in Output to say so.
- **Parry is directional.** It stops punches from your front half only. Getting
  hit from behind while guarding is working as intended.
- **Stamina is the server's, and it is spent by all three.** Sprinting and
  guarding drain it continuously, every swing costs a fixed amount, and it
  refills when you are doing none of them.
- **Running it to zero makes you EXHAUSTED, and that is one state.** No sprint,
  no guard, and punches that still swing and still connect but deal **zero**
  damage. All three come back together — and the dark vignette clears — only
  once the pool reaches `StaminaRecoveryFraction` (25%). Being merely low costs
  you nothing: the threshold gates the way out of exhaustion, never the way in.
- **All the numbers are in `src/shared/Config.luau`** — damage, reach, cooldown,
  cone angle, sprint speed, parry speed, parry arc, lag allowance, and every
  stamina rate and cost. Tune there, not in Studio.

### Not built yet

Weapons, inventory, quests, NPCs, enemies, progression, currency, player data
persistence, and the map itself.

## Development philosophy

**GitHub is the source of truth for code.** Luau source, configuration, project
structure, tests, tooling and documentation live in Git, are reviewed in pull
requests, and are validated by CI.

**Roblox Studio is the source of truth for the world.** Terrain, map geometry,
prop placement, lighting and UI layout are authored visually in Studio, because
forcing them through a file-sync tool would make everyone slower for no gain.

The two meet through [Rojo](https://rojo.space), which syncs the filesystem into
Studio in **one direction**: disk → Studio. This split is the single most
important thing to understand about the repository, and it has its own section
[below](#git-vs-roblox-studio-who-owns-what).

## Tech stack

| Tool | Version | What it does |
| --- | --- | --- |
| [Rokit](https://github.com/rojo-rbx/rokit) | 1.2.0 | Toolchain manager. Installs everything below at the exact pinned version. |
| [Rojo](https://rojo.space) | 7.7.0 | Syncs the filesystem into Roblox Studio; builds place files. |
| [Wally](https://wally.run) | 0.3.2 | Package manager for Luau/Roblox dependencies. |
| [wally-package-types](https://github.com/JohnnyMorganz/wally-package-types) | 1.6.2 | Restores Luau types that Wally strips from package links. |
| [Selene](https://kampfkarren.github.io/selene/) | 0.31.0 | Linter that understands Roblox globals. |
| [StyLua](https://github.com/JohnnyMorganz/StyLua) | 2.5.2 | Deterministic formatter. |
| [luau-lsp](https://github.com/JohnnyMorganz/luau-lsp) | 1.69.0 | Editor intelligence + the `analyze` type-check gate in CI. |
| [Lune](https://lune-org.github.io/docs) | 0.10.5 | Standalone Luau runtime; runs the scripts in `scripts/`. |
| [Jest Lua](https://jsdotlua.github.io/jest-lua/) | 3.10.0 | Test framework. Runs inside Roblox. |

Why each of these and not the alternatives: [`docs/decisions.md`](docs/decisions.md).

## Repository structure

```
src/
  shared/              → ReplicatedStorage.Shared     both sides can see this
    Types.luau           types that cross the client/server boundary
    Config.luau          every tunable number in the game, frozen
    Combat/PunchRules    pure punch arithmetic — reach, cone, cooldown, lag
    Net/                 remote registry; Remotes.luau declares every remote
    Runtime/             Bootstrap — the Init()/Start() lifecycle runner
    Util/                Logger and future shared helpers
  server/              → ServerScriptService.Server   authoritative gameplay
    init.server.luau     entry point
    DeveloperAccess      who may run the /damage and /heal test commands
    Services/            one file per system
      HealthService/       100 HP, damage, death, respawn
      CombatService        decides who a punch hit, and for how much
      SessionService       boot handshake, build-version check
  client/              → StarterPlayerScripts.Client  presentation and input
    init.client.luau     entry point
    Controllers/         one file per system, including UI logic
      HealthBarController/ drives the Studio-authored health bar
      PunchController      left click, swing animation, Hit marker
      RunningController/   hold Shift to sprint
      ScreenEffectsController/ damage, heal and death screen vignette
      SessionController    the client half of the handshake
  client.project.json  → (scopes StarterPlayerScripts.Client to a LocalScript)

tests/                 → ServerScriptService.Tests    Jest specs (dev build only)
scripts/                 Lune automation — not game code
plugin/                  Studio plugin that runs Jest locally — not synced by Rojo
assets/                  reviewable assets only; the map is NOT here
docs/                    architecture and workflow guides
.github/                 CI workflows, PR and issue templates, CODEOWNERS

default.project.json     development Rojo project (includes tests)
build.project.json       production Rojo project (no tests)
rokit.toml               pinned toolchain
wally.toml / wally.lock  dependencies
selene.toml              lint rules
stylua.toml              formatting rules
.luaurc                  Luau strict mode
CLAUDE.md                the contract Claude Code follows in this repository
```

Full architecture: [`docs/architecture.md`](docs/architecture.md).

---

## Setup

Do these in order. Every step says what "it worked" looks like.

### 1. Install Git

**Windows** — download and run the installer from
[git-scm.com/downloads/win](https://git-scm.com/downloads/win). Accept the
defaults; they are fine. This also gives you **Git Bash**, which is the terminal
these instructions assume on Windows.

**macOS**

```bash
brew install git
```

**Linux (Debian/Ubuntu)**

```bash
sudo apt update && sudo apt install git
```

Check it worked:

```bash
git --version
```

You should see something like `git version 2.43.0`. Then set your identity, so
your commits are attributed to you:

```bash
git config --global user.name "Your Name"
git config --global user.email "you@example.com"
```

### 2. Install Roblox Studio

Go to [create.roblox.com](https://create.roblox.com), sign in, and click
**Create** → it will prompt you to download Roblox Studio. Install it and open
it once so it finishes setting itself up.

You need a Roblox account with access to the team's group/experience. Ask the
project owner if you have not been added.

### 3. Install Rokit

Rokit downloads and pins every other tool this project uses, so you never have
to install Rojo, Wally, Selene or StyLua yourself.

**Windows (PowerShell)**

```powershell
Invoke-RestMethod https://raw.githubusercontent.com/rojo-rbx/rokit/main/scripts/install.ps1 | Invoke-Expression
```

**macOS / Linux**

```bash
curl -sSf https://raw.githubusercontent.com/rojo-rbx/rokit/main/scripts/install.sh | bash
```

**Close and reopen your terminal**, then check:

```bash
rokit --version
```

You should see `rokit 1.2.0` or newer. If you get "command not found", the
installer added `~/.rokit/bin` to your PATH but your current shell has not picked
it up — reopening the terminal is what fixes it.

### 4. Clone the repository

```bash
git clone https://github.com/edumaf/medieval_game.git
cd medieval_game
```

Everything from here on runs from inside that folder.

### 5. Install the project toolchain

```bash
rokit install
```

Rokit reads `rokit.toml` and downloads the exact versions listed there. The first
run asks you to trust each tool source — that is Rokit confirming you meant to
download binaries from those GitHub repositories. Answer yes.

Check it worked:

```bash
rojo --version      # Rojo 7.7.0
wally --version     # wally 0.3.2
selene --version    # selene 0.31.0
stylua --version    # stylua 2.5.2
lune --version      # lune 0.10.5
```

If any of these says "command not found" after a successful install, reopen your
terminal.

### 6. Install dependencies

```bash
wally install
```

This reads `wally.toml` and `wally.lock` and creates `DevPackages/` (and
`Packages/` once we have runtime dependencies). Those folders are gitignored and
regenerated — never edit or commit them.

Expected output ends with something like `Downloaded 48 packages!`.

Then restore the Luau types that Wally strips out of the links it generates:

```bash
rojo sourcemap default.project.json --output sourcemap.json
wally-package-types --sourcemap sourcemap.json DevPackages/
```

> ⚠️ Run `wally-package-types` **once** per `wally install`. It edits the link
> files in place, so a second run on the same folder fails with
> `'REQUIRED_MODULE' is not a function call`. Re-run `wally install` first if
> that happens.

### 7. Fetch the Roblox API definitions

```bash
lune run scripts/fetch-global-types
```

This downloads the Roblox API type definitions that the type checker needs,
matched to our pinned luau-lsp version, into `.tooling/` (gitignored). Without
it, type checking cannot resolve `Instance`, `Player` or any Roblox API.

Expected output: `Wrote .tooling/globalTypes.d.luau`.

### 8. Install the Rojo Studio plugin

Rojo has two halves: the `rojo` command you just installed, and a Studio plugin
that connects to it. **They must be the same major/minor version** or the plugin
will refuse to connect.

```bash
rojo plugin install
```

This installs the plugin build that ships with your exact `rojo` binary, which is
the reliable way to keep them matched. Restart Studio afterwards.

You should now see a **Rojo** button in Studio's **Plugins** tab.

> If `rojo plugin install` fails, install "Rojo" from the Creator Store in
> Studio instead, and check that the plugin's reported version matches
> `rojo --version`.

This repository also has a second, project-specific plugin that runs the Jest
suite locally — install it in the [Testing](#testing) section below once
you've cloned everything; it is not part of this setup sequence.

### 9. Configure your editor

**VS Code** is what the team uses. Open the repository folder and accept the
recommended extensions prompt — it installs Luau LSP, StyLua, Selene and the
Rojo extension. `.vscode/settings.json` in the repository already configures
them: format on save, automatic sourcemap generation, Roblox type definitions.

Any editor works if it can run the same commands. The validation you must pass
is the same either way.

Generate the sourcemap once so the language server can resolve
`ReplicatedStorage.Shared.Config` to the file on disk:

```bash
rojo sourcemap default.project.json --output sourcemap.json
```

(The VS Code setup regenerates this automatically as you work.)

### 10. Install Claude Code (optional)

Claude Code is the AI assistant this repository is configured for. It reads
`CLAUDE.md` automatically and follows the rules in it.

**Windows (PowerShell)**

```powershell
irm https://claude.ai/install.ps1 | iex
```

**macOS / Linux / WSL**

```bash
curl -fsSL https://claude.ai/install.sh | bash
```

Check it worked:

```bash
claude --version
```

> The native installer above is the current recommended method. Installing via
> `npm install -g @anthropic-ai/claude-code` still works but is no longer the
> documented default — use the native installer unless you have a reason not to.

Claude Code needs a Pro, Max, Team or Enterprise account. Run `claude` once and
follow the browser prompt to sign in.

---

## Running the project

Three things have to be true: the Rojo server is running, Studio is connected to
it, and you press Play.

**1. Start the sync server** (leave this terminal open):

```bash
rojo serve
```

Expected output:

```
Rojo server listening:
  Address: localhost
  Port:    34872
```

**2. Open the place in Studio.** Use the team's development place, or a new
Baseplate if you are just poking around.

**3. Connect.** In Studio: **Plugins** tab → **Rojo** → **Connect**. The panel
turns green and shows the same port.

At this point Studio's Explorer should contain:

- `ReplicatedStorage.Shared` (Config, Net, Runtime, Types, Util)
- `ReplicatedStorage.DevPackages`
- `ServerScriptService.Server` (with `Services`)
- `ServerScriptService.Tests`
- `StarterPlayerScripts.Client` (with `Controllers`)

**4. Press Play.** The Output window should show lines like these (the exact
interleaving varies, since controllers start in their own threads):

```
[Server] boot complete
[SessionService] session opened for YourName (12345678)
[Client] boot complete
[SessionController] connected to server build 0.1.0
```

That is the whole stack working: server boot, service lifecycle, a validated
remote round-trip, and shared config read from both sides.

While `rojo serve` is running, every file you save appears in Studio within a
second. Stop the server with `Ctrl+C`.

> `StarterPlayerScripts.Client` appears as a **LocalScript** — the one
> exception to the rest of the tree, which uses `Script` with `RunContext`
> instead. That is correct — see [`docs/decisions.md`](docs/decisions.md).

---

## Git vs Roblox Studio: who owns what

> **Rojo owns code. Studio owns the world.**

Rojo syncs one way, filesystem → Studio. Anything Rojo manages is **overwritten
from disk** on the next sync.

| Thing | Owned by | Edit it in |
| --- | --- | --- |
| Luau source, services, controllers, shared modules | Git | Your editor |
| Tests, tooling, CI, project files | Git | Your editor |
| Map geometry, terrain, props | Studio | Studio |
| Lighting, atmosphere | Studio | Studio |
| Spawns, zones, interactables | Studio | Studio |
| UI layout (`StarterGui`) | Studio | Studio |
| UI logic | Git | Your editor |
| Reusable `.rbxm` models | Git (`assets/models`) | Studio, then export |

> ⚠️ **While Rojo is connected, do not type inside `Shared`, `Server`, `Tests` or
> `Client` in Studio.** Your changes are destroyed the next time a file syncs,
> with no warning and no undo.

Everything else in the place — `Workspace`, `Lighting`, `StarterGui`,
`SoundService` — is yours to build in freely.

Full detail, including Studio folder conventions:
[`docs/studio-workflow.md`](docs/studio-workflow.md).

## Working on the map

The map is built in Studio and lives in the place file, not in Git. Place files
are binary; Git cannot merge them, so **two people editing the same place at once
will lose work.** Use **Team Create**, or split work into `.rbxm` models exported
to `assets/models/`.

Organise `Workspace` as `Map/`, `Gameplay/` and `Effects/` — the exact
conventions, and the rules about renaming things code depends on, are in
[`docs/studio-workflow.md`](docs/studio-workflow.md).

Publishing from Studio saves the map. Committing saves the code. They are
separate acts; doing one does not do the other.

## Working on UI

Layout is authored in Studio (`StarterGui`) by the designer. Logic is written in
`src/client/Controllers/<Screen>Controller.luau` by a developer. They meet at
instance **names**, which means renaming a button in Studio breaks the controller
exactly like renaming a function would.

See [`docs/ui-workflow.md`](docs/ui-workflow.md).

## Working on code

Start by reading [`docs/architecture.md`](docs/architecture.md), then open
`src/server/Services/SessionService.luau` — it is deliberately small and shows
the whole pattern.

The short version:

- A **server service** goes in `src/server/Services/`. It owns truth.
- A **client controller** goes in `src/client/Controllers/`. It owns presentation.
- Anything both need — types, config, utilities — goes in `src/shared/`.
- Modules may export `Init()` (runs first, must not yield) and `Start()` (runs
  after, may yield). `Bootstrap` handles the rest.
- Remotes are declared in `src/shared/Net/Remotes.luau` and **every server
  handler validates its arguments**.

---

## Using Claude Code

`CLAUDE.md` at the repository root is loaded automatically at the start of every
session. It tells Claude the architecture, the commands, the coding rules, the
Roblox security rules and the Git rules. You do not need to re-explain them.

### The loop

1. **Open a terminal in the repository root.** Claude Code's context is the
   folder you start it in, so starting it elsewhere loses `CLAUDE.md`.
2. **Create your branch first** (see below). Claude will not push to `main`, but
   starting on a branch avoids the conversation entirely.
3. **Start it:**
   ```bash
   claude
   ```
4. **Let it look around before asking for code.** A first message like
   *"Read the architecture docs and src/, then summarise how services and
   controllers are wired together"* costs one exchange and prevents most bad
   suggestions.
5. **Give it one specific task.**
6. **Read the diff it proposes.** You are the reviewer. Claude cannot click
   the Studio plugin button or press Play — it cannot know whether the game
   or the test suite still works, and it will tell you so rather than guess.
7. **Test it in Studio** and run validation yourself.
8. **Commit when the change is right**, not when Claude says it is done.

### A good prompt

```
Implement the inventory data model.

Before changing anything:
1. Inspect the existing architecture and tell me what you found.
2. Identify existing systems and utilities that should be reused.
3. Explain your proposed approach and wait for me to confirm.

Then:
4. Implement the smallest clean solution that fits the existing patterns.
5. Add Jest specs under tests/.
6. Run stylua, selene, luau-lsp analyze and the validate-project script.
7. Report exactly what changed and what you could not verify.
```

The shape that matters: **inspect → propose → confirm → implement → validate →
report.** Skipping "propose" is how you get a parallel system that duplicates
something you already have.

More good prompts:

```
Add a RemoteEvent for equipping an item. Declare it in Shared/Net/Remotes.luau,
handle it in a server service, and validate every argument — assume the client
is hostile. Show me the validation before you write the rest.
```

```
Review src/server/Services/ for connections that are never disconnected and
per-player state that is never cleared on PlayerRemoving. Report findings, do
not fix anything yet.
```

### What not to do

- ❌ **"Build the inventory system."** Too big. You will get a plausible-looking
  thousand-line diff you cannot review.
- ❌ **Letting it commit and push without reading the diff.** It is your name on
  the commit and your PR the team reviews.
- ❌ **Asking it to build the map or generate parts.** The world is Studio's.
  Procedurally generated placeholder geometry is not useful to anyone.
- ❌ **Asking it to "clean up the codebase" alongside a feature.** Unrelated
  refactors make a PR unreviewable. Separate branch, separate PR.
- ❌ **Accepting a new dependency without a reason.** Ask what it does that fifty
  lines cannot.
- ❌ **Believing "tests pass".** It cannot run them. Run them yourself in Studio.

---

## The development workflow

### Creating a feature branch

Always branch from an up-to-date `main`:

```bash
git checkout main
git pull origin main
git checkout -b feature/inventory-data-model
```

Branch naming — the prefix tells reviewers what to expect:

| Prefix | For | Example |
| --- | --- | --- |
| `feature/` | New functionality | `feature/combat-system` |
| `fix/` | Bug fixes | `fix/inventory-duplication` |
| `refactor/` | Restructuring, no behaviour change | `refactor/networking` |
| `chore/` | Tooling, CI, dependencies, docs | `chore/toolchain-update` |

Keep branches short-lived — days, not weeks. Long branches drift from `main` and
turn into merge archaeology. There are no permanent personal branches.

### Making changes

Work with `rojo serve` running so Studio reflects your edits as you go. Commit in
small logical steps rather than one giant commit at the end.

If `main` moves while you are working, catch up:

```bash
git fetch origin
git rebase origin/main
```

Rebasing keeps your branch a clean line on top of `main`. If you are not
comfortable with rebase, `git merge origin/main` is fine — squash merging cleans
it up at the end either way.

### Running validation

Run all of this before you push. It is exactly what CI runs, so a green run here
means a green run there.

```bash
# Format (do this first — it rewrites files)
stylua src tests scripts plugin

# Lint
selene src tests scripts plugin

# Refresh the sourcemap, then type-check
rojo sourcemap default.project.json --output sourcemap.json
luau-lsp analyze --platform=roblox --sourcemap=sourcemap.json \
  --definitions=.tooling/globalTypes.d.luau --base-luaurc=.luaurc \
  --ignore="**/Packages/**" --ignore="**/DevPackages/**" \
  src tests plugin

# Repository consistency: Rojo mappings, pinned versions, lockfile
lune run scripts/validate-project

# Both project files must build
mkdir -p build
rojo build default.project.json --output build/dev.rbxl
rojo build build.project.json --output build/medieval-game.rbxl
```

Plus the parts a machine cannot check: **run the unit tests from the Studio
plugin** (**Plugins** → **Medieval Game Tests** → **Run Tests**) and
**play-test your change** (press Play, separately).

**Reading failures**

- *StyLua prints a diff* — you did not format. Run `stylua src tests scripts plugin`.
- *Selene `undefined_variable`* — a typo, or a missing `require`. Real bug, not
  noise.
- *Selene `global_usage`* — you used `_G` or `shared`. Put the state in a module.
- *Selene `unused_variable`* — delete it, or prefix with `_` if it is a
  deliberately ignored loop variable.
- *luau-lsp `TypeError`* — read the "caused by" line at the bottom; it names the
  property that does not match.
- *luau-lsp floods you with `Unknown type 'Instance'` / `Unknown global 'game'`*
  — `.tooling/globalTypes.d.luau` is missing or stale, so it is type-checking
  with no knowledge of Roblox at all. Run
  `lune run scripts/fetch-global-types`. (luau-lsp only warns about a missing
  definitions file, so this looks like hundreds of errors in your code rather
  than one setup problem.)
- *luau-lsp cannot resolve `ReplicatedStorage.Shared.Something`* — the sourcemap
  is stale. Re-run
  `rojo sourcemap default.project.json --output sourcemap.json`.
- *validate-project complains about a path* — a Rojo mapping points at a folder
  that was renamed or deleted.

### Committing

```bash
git status                    # look at what you are about to stage
git add src/server/Services/InventoryService.luau tests/shared/Inventory.spec.luau
git commit -m "Add inventory data model with server-side validation"
```

Prefer naming files over `git add .`, so you do not sweep up build output or a
stray secret.

Write messages in the imperative — "Add inventory data model", not "added" or
"adds". First line under ~72 characters; add a body if the *why* is not obvious.

Commit `wally.toml` and `wally.lock` together, always.

### Pushing

```bash
git push -u origin feature/inventory-data-model
```

`-u` links your local branch to the remote one, so later pushes are just
`git push`.

If it is rejected because the remote has commits you do not:

```bash
git pull --rebase origin feature/inventory-data-model
git push
```

> ⚠️ Never `git push --force` to a shared branch. If you genuinely need to
> rewrite your own branch after a rebase, use `git push --force-with-lease`,
> which refuses if someone else has pushed in the meantime.

### Opening a pull request

Push, then open the PR on GitHub (the push output prints a link). The template
fills in automatically — answer every section:

- **What changed** and **why**
- **How it was tested** — "tested in Studio" is not an answer; say what you did
- **Studio/map changes** — if the reviewer needs something published in Studio to
  see your change work, say so, or they will assume it is broken
- **Dependencies** — did `wally.toml` or `rokit.toml` change?
- **Breaking changes** — anything that breaks a teammate's branch

Keep PRs small. A 200-line PR gets a real review; a 2000-line PR gets an
approval nobody means.

### Code review

CI runs automatically. It must be green before anyone reviews — do not ask for a
review on a red PR.

**As the author:** respond to every comment. Push fixes as new commits (do not
force-push mid-review; it destroys the reviewer's place in the diff). Re-request
review when you are done.

**As the reviewer:** pull the branch and run it. Check specifically for:

- Does the server validate everything the client sends?
- Is anything secret sitting in `src/shared`?
- Are connections disconnected and per-player state cleared on leave?
- Does it duplicate something that already exists?
- Are the types real, or is it `any` everywhere?

Approve, or ask for changes. "Looks good" without opening the diff is how bugs
get merged.

### Merging

**Squash and merge.** One commit per PR on `main`, titled with the PR title. That
keeps history readable and every change revertable in one step. Then delete the
branch — GitHub offers a button, and it is configured to do it automatically.

`main` is protected: no direct pushes, review required, CI required. See
[`docs/github-setup.md`](docs/github-setup.md) for the exact settings an admin
must enable.

### Updating your local repository

After anything merges:

```bash
git checkout main
git pull origin main
git fetch --prune                  # drop references to deleted remote branches
git branch -d feature/inventory-data-model
```

If `rokit.toml` or `wally.toml` changed in what you pulled:

```bash
rokit install
wally install
```

Forgetting those two is the most common cause of "it works for everyone but me".

---

## A complete example session

Adding a hypothetical "player gold" system, start to finish.

```bash
# 1. Start from current main
git checkout main
git pull origin main

# 2. Branch
git checkout -b feature/player-gold

# 3. Start the sync server (leave running in its own terminal)
rojo serve
```

```bash
# 4. In a second terminal, start Claude Code
claude
```

**5. Ask it to look before it leaps:**

> Read docs/architecture.md and src/server/Services/SessionService.luau, then
> tell me where a server-authoritative gold balance should live and what it
> should reuse.

**6. It proposes** a `GoldService` in `src/server/Services/`, state keyed by
player, cleanup on `PlayerRemoving`, a `GoldChanged` RemoteEvent declared in
`Shared/Net/Remotes.luau`, and a client controller that only displays the value.

**7. You review the plan** — is the server the only thing that can change the
balance? Yes. Approve, and it implements.

```bash
# 8. Validate
stylua src tests scripts plugin
selene src tests scripts plugin
rojo sourcemap default.project.json --output sourcemap.json
luau-lsp analyze --platform=roblox --sourcemap=sourcemap.json \
  --definitions=.tooling/globalTypes.d.luau --base-luaurc=.luaurc \
  --ignore="**/Packages/**" --ignore="**/DevPackages/**" src tests plugin
lune run scripts/validate-project
rojo build build.project.json --output build/medieval-game.rbxl
```

**9. Test in Studio.** Connect Rojo. Run the unit tests from **Plugins** →
**Medieval Game Tests** → **Run Tests** and confirm your new specs appear and
pass. Then press Play and play-test: does the balance show up, and does
nothing on the client let you change it?

```bash
# 10. Commit and push
git add src/ tests/
git commit -m "Add server-authoritative player gold balance"
git push -u origin feature/player-gold
```

**11. Open the PR**, fill in the template, note that no Studio changes are
needed.

**12. CI runs.** Green.

**13. A teammate reviews**, asks why `GoldChanged` fires on every change rather
than batching. You batch it, push a follow-up commit, they approve.

**14. Squash and merge.** Branch auto-deletes.

```bash
# 15. Clean up locally
git checkout main
git pull origin main
git fetch --prune
git branch -d feature/player-gold
```

---

## Testing

Tests live in `tests/`, are named `<Thing>.spec.luau`, and run with
[Jest Lua](https://jsdotlua.github.io/jest-lua/). There are three separate
testing paths — do not confuse them:

**Local unit tests** run through a small Studio plugin, **not** by pressing
Play. Jest needs a capability (`PluginOrOpenCloud`) that an ordinary Play-mode
script does not have, so it cannot run there under Roblox's current Script
Capabilities model, on any machine, no matter what Studio flags are set —
this is a change from an earlier version of this document.

```bash
lune run scripts/install-test-plugin   # one-time per machine
```

Then in Studio: `rojo serve`, connect, **Plugins** tab → **Medieval Game
Tests** → **Run Tests**. Results appear in the Output window. See
[`plugin/README.md`](plugin/README.md) for manual install steps and
[`docs/testing.md`](docs/testing.md) for why Play mode cannot do this.

**Gameplay testing** — multiplayer behavior, replication, UI, input,
networking, visual behavior — is still pressing **Play** in Studio, same as
always. Play mode no longer starts a test runner of any kind; it is purely
for playing the game.

**CI tests** run the same Jest suite headlessly via Roblox's Open Cloud Luau
Execution API (`.github/workflows/roblox-tests.yml`). It needs an API key and
a dedicated test place, and skips cleanly until an admin configures them.
Until then, every-PR confidence comes from formatting, linting,
**type-checking**, project validation and a real build of both project files.

Full guide, including how to configure Open Cloud:
[`docs/testing.md`](docs/testing.md).

## Dependency management

Declare dependencies in `wally.toml`, pinned to an exact version. Commit
`wally.lock` alongside it — never edit the lockfile by hand, and never commit the
`Packages/` folders.

After adding anything, regenerate the sourcemap and run `wally-package-types`,
or the package's types silently become `any`.

Full guide: [`docs/dependencies.md`](docs/dependencies.md).
Toolchain updates: [`docs/toolchain.md`](docs/toolchain.md).

## Security

### Never commit

API keys, access tokens, Open Cloud keys, `.ROBLOSECURITY` cookies, `.env` files,
private credentials, or anything machine-specific. `.gitignore` blocks the usual
suspects, but it cannot catch a key pasted into a source file.

If you commit a secret: **rotate it immediately.** Deleting it in a later commit
does not remove it from history, and the repository history is not something you
should be rewriting.

Secrets that CI needs go in **GitHub → Settings → Secrets and variables →
Actions**, and are read from the environment — see
[`docs/testing.md`](docs/testing.md).

### Roblox security principles

The server is authoritative over currency, inventory, damage, progression,
rewards, purchases and any state a player could profit from lying about. The
client handles presentation, input, UI, local effects and prediction.

**Never trust the client.** Every `RemoteEvent` and `RemoteFunction` handler
validates argument types, ranges, ownership, permission and rate. Assume every
client is running modified code, because some of them are.

**Nothing secret goes in `src/shared`.** `ReplicatedStorage` is fully readable by
every client. Drop tables, economy formulas and anti-cheat thresholds belong in a
server-only module.

---

## Troubleshooting

### Rojo

**`rojo: command not found`**
Rokit did not install it, or your PATH is stale. Run `rokit install`, then
reopen your terminal. Confirm with `rokit list`.

**The Studio plugin will not connect**
Almost always a version mismatch. Compare `rojo --version` with the version in
the Rojo plugin panel. Fix with `rojo plugin install` and restart Studio.

**"Rojo plugin is out of date" / "server version mismatch"**
Same cause. `rojo plugin install`, restart Studio, reconnect.

**`rojo serve` exits immediately**
Read the error. Usually invalid JSON in `default.project.json` (a trailing comma
is the classic), or a `$path` pointing at a folder that does not exist. Check
with:

```bash
lune run scripts/validate-project
rojo build default.project.json --output build/test.rbxl
```

**Changes do not appear in Studio**
In order: is `rojo serve` still running? Is the plugin panel green? Did you save
the file? Is the file inside a folder the project actually maps? Disconnect and
reconnect the plugin.

**Studio connected to the wrong server**
If you have two projects open, both may be on port 34872. Stop both, start one,
reconnect. Use `rojo serve --port 34873` to run two at once.

**Files land in the wrong Roblox service**
The mapping in `default.project.json` decides this, not the folder name. Check
the `tree` block, then verify what you got:

```bash
rojo sourcemap default.project.json --output sourcemap.json
```

Open `sourcemap.json` and look at the actual hierarchy.

**A script edited in Studio reverted**
Working as designed. Rojo overwrites its own instances from disk. Edit code in
your editor. See [Git vs Studio](#git-vs-roblox-studio-who-owns-what).

### Wally

**`wally: command not found`** — `rokit install`, then reopen your terminal.

**`wally install` fails to resolve**
Two packages want incompatible versions of a shared dependency. The error names
them. Relax a version constraint or drop one.

**Merge conflict in `wally.lock`**
Never hand-edit it. Take `main`'s copy and regenerate:

```bash
git checkout --theirs wally.lock
wally install
git add wally.lock
```

**A package's types are `any`**
You skipped the types step. Run:

```bash
rojo sourcemap default.project.json --output sourcemap.json
wally-package-types --sourcemap sourcemap.json DevPackages/
```

**`DevPackages` missing in Studio**
Run `wally install` and reconnect the Rojo plugin.

### Git

**`error: failed to push some refs`**
The remote has commits you do not. Pull with rebase, then push:

```bash
git pull --rebase origin your-branch
git push
```

**Merge conflicts**
Open each conflicted file, resolve between the `<<<<<<<` and `>>>>>>>` markers,
then:

```bash
git add <resolved-file>
git rebase --continue      # or: git commit, if you merged
```

Lost? `git rebase --abort` puts you back exactly where you started.

**"Your branch is behind main"**

```bash
git fetch origin
git rebase origin/main
```

**Accidental local changes you want gone**

```bash
git diff                       # ⚠️ look first — this is not undoable
git restore path/to/file       # discard changes to one file
git stash                      # or: park everything, retrieve with `git stash pop`
```

**Committed to `main` by mistake (not pushed)**

```bash
git branch feature/my-work     # save the work on a branch
git reset --hard origin/main   # ⚠️ resets main to the remote
git checkout feature/my-work
```

**A conflict in a `.rbxl` or `.rbxm`**
Git cannot merge binary files. One version has to win — talk to whoever made the
other one. This is why the map lives in Team Create.

### Roblox Studio

**Nothing runs when you press Play**
Is Rojo connected? Is `ServerScriptService.Server` present in the Explorer? Check
the Output window for errors — a failed `require` stops the whole boot.

**`Infinite yield possible on 'WaitForChild'`**
Something is not where the code expects. Check the sourcemap for the real path,
and confirm Rojo is connected.

**Code runs on the wrong side**
`src/server` → server only. `src/client` → client only. `src/shared` → both, so
it must not assume either. `RunService:IsServer()` / `:IsClient()` when you truly
need to branch.

**"This is a Script, I expected a LocalScript"**
`emitLegacyScripts` is off, so most client and server scripts are `Script`
instances with `RunContext` set. Intentional — see
[`docs/decisions.md`](docs/decisions.md). `StarterPlayerScripts.Client` is the
one deliberate exception and *is* a `LocalScript` — see the same doc for why.

**Jest reports "lacking capability PluginOrOpenCloud" / nothing happens on Play**
Expected — Jest cannot run during Play mode at all, on any machine, regardless
of Studio flags. Run it from the Studio plugin instead:
[Testing](#testing), [`docs/testing.md`](docs/testing.md).

**The Rojo plugin vanished after a Studio update**
Reinstall it: `rojo plugin install`, restart Studio.

**The test plugin (Medieval Game Tests) vanished after a Studio update**
Re-run `lune run scripts/install-test-plugin`, restart Studio.

### Claude Code

**`claude: command not found`**
Reopen your terminal after installing. If it persists, run `claude doctor` (if
`claude` resolves at all) or re-run the installer from
[step 10](#10-install-claude-code-optional).

**Authentication problems**
Run `claude` and follow the browser prompt. Claude Code needs a Pro, Max, Team or
Enterprise account — the free plan does not include it.

**It edits the wrong files**
You almost certainly started it outside the repository root, so it never loaded
`CLAUDE.md`. `cd` to the repository root and restart. Confirm with a first
message asking it to summarise the project structure.

**It misunderstands the architecture**
Point it at the source: *"Read docs/architecture.md and
src/shared/Runtime/Bootstrap.luau before answering."* Vague prompts get generic
Roblox patterns instead of ours.

**It creates a duplicate system**
It did not look first. Reset the task with an explicit inspection step: *"List
every module in src/shared/Util and tell me which one already does this before
writing anything."*

**It claims tests passed**
It cannot click the Studio plugin button. Run the suite yourself (**Plugins**
→ **Medieval Game Tests** → **Run Tests**) and treat any claim about test
results Claude makes as unverified until you do.

---

## Development rules

1. `main` is always releasable. Never push to it directly.
2. Every change goes through a pull request with one approval and green CI.
3. Format, lint, type-check and build locally before pushing. CI is a safety net,
   not your first run.
4. The server is authoritative. Validate everything the client sends.
5. Nothing secret in `src/shared` — clients can read all of it.
6. No global state. `_G` and `shared` fail the lint.
7. Every connection gets disconnected; every per-player table gets cleared on
   `PlayerRemoving`.
8. Reuse before you write. Check `src/shared/Util` and `src/shared/Types` first.
9. No new dependency without a reason in the PR description.
10. Do not refactor unrelated code inside a feature PR.
11. Never commit secrets, place files, or generated folders.
12. Rojo owns code; Studio owns the world. Do not edit across the line.

Architecture guidance for adding systems: [`docs/architecture.md`](docs/architecture.md).
The same rules, written for Claude Code: [`CLAUDE.md`](CLAUDE.md).
