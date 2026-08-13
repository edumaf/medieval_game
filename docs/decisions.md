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

## `ServerScriptService.LoadStringEnabled: true`, dev/test project only

Once Open Cloud was actually configured and run for real, Jest failed inside
the execution session with `loadstring() is not available`, after correctly
reaching Roblox's server and starting to collect tests. This is a different
problem from the `PluginOrOpenCloud` capability issue above, not a
restatement of it — the capability check was already passing (Open Cloud
sessions do carry `PluginOrOpenCloud`), but `jest-runtime@3.10.0` has a
second, independent requirement.

`jest-runtime` tries `debug.loadmodule` first, and falls back to
`loadstring(source, chunkName)` if that's unavailable — this fallback was
added in 3.10.0 specifically for lower-privileged contexts, so this is not a
bug in Jest or a reason to change its version; 3.10.0 is current and its
design is correct. `debug.loadmodule` requires Studio's
`FFlagEnableLoadModule`, which has no equivalent on Open Cloud's headless
servers, so Open Cloud always falls to the second tier. `loadstring` is
disabled by default for every Roblox server script
(`ServerScriptService.LoadStringEnabled` defaults to `false`) — a security
default, since misuse can lead to remote code execution — and an Open Cloud
execution session runs the uploaded place under ordinary server rules, so it
inherits that default too.

The fix is a place property, not a code or dependency change:
`default.project.json`'s `ServerScriptService` now sets
`$properties.LoadStringEnabled: true`, so it's baked into
`build/test-place.rbxl` (and the local `build/dev.rbxl`). This is scoped
exactly the same way `Tests/` and `DevPackages` already are: `default.project.json`
is the dev/test project; `build.project.json` — the actual production
place — does not set it and keeps Roblox's `false` default. Nothing in this
codebase calls `loadstring` outside of Jest's own fallback, and Jest is never
part of a production build in the first place, so there is no path for this
setting to reach a live server.

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

## Sprinting (`RunningController`) is client-only, for now

`src/client/Controllers/RunningController/` sets `Humanoid.WalkSpeed` locally
in response to Left Shift, with no remote involved. This works — and reaches
the server and other clients — because player characters are
client-network-owned by default, so a client's own changes to its Humanoid's
movement properties already replicate outward.

This is deliberately client-authoritative, not an oversight. Right now
nothing in the game (no stamina, no combat, no speed-gated rewards or
anti-cheat) gives a modified client anything to gain by reporting a false
speed, so there is nothing yet for the server to validate. **The first system
that cares whether a player is "really" sprinting — stamina, combat, a
speed-dependent reward, movement-based anti-cheat — needs to make speed
server-authoritative**: track sprint intent server-side (a `RemoteEvent`
declared in `Shared/Net/Remotes.luau`, validated like every other handler —
see `SessionService`) and either clamp or reject a `Humanoid.WalkSpeed` the
server did not expect, rather than trusting the client's number. Do not
retrofit that ahead of needing it.

Respawn behavior: if Left Shift is still held when a character respawns, the
new character starts sprinting immediately — `RunningController` only swaps
which `Humanoid` it applies the existing sprint-intent state to, it does not
reset that state on death. Input connections are made once, in `Start()`; a
respawn never reconnects anything, so there is nothing to leak or duplicate.

The state transitions (`SprintState.luau`, beside the controller) are covered
by `tests/client/RunningController/SprintState.spec.luau` — they need no
Humanoid or input device, so they are pure Jest unit tests rather than a
Studio play-test. The actual key handling and `Humanoid.WalkSpeed` effect can
only be verified by hand in Studio.

## Health (`HealthService`) keeps its own state and mirrors it onto Humanoid

Unlike sprinting, health is server-authoritative from the first version, and
that ruled out the option that looked simplest: reading and writing
`Humanoid.Health`/`MaxHealth` directly and treating them as the source of
truth. Health is not one of Roblox's specially-replicated Humanoid movement
properties (`WalkSpeed`, jump state, and so on) that only ever flow
server→client because a player's own character is client-network-owned —
`Humanoid.Health`, specifically, replicates in the other direction too: a
client's own change to their own Humanoid's `Health` reaches the server. This
is a known, documented Roblox behavior (it is how, for example, client-side
fall damage or a modified client's self-heal/self-damage reaches the server),
not an oversight in this codebase. Treating `Humanoid.Health` as authoritative
would mean `HealthService.getHealth`/`isDead` could be lying the moment a
player runs modified client code — the opposite of what "Unlike the Running
System, Health must be server-authoritative" requires.

`HealthService` therefore keeps the real number in a module-local table
(`records[player].state`, a `HealthState.HealthState` — current, max, dead),
exactly like `SessionService.sessions`. Every read (`getHealth`, `getMaxHealth`,
`isDead`) and write (`takeDamage`, `heal`) goes through that table, never
through the Humanoid. `Humanoid.Health`/`MaxHealth` are mirrored one-way, from
this state onto the Humanoid, purely so Roblox's own death/ragdoll handling
(and any future health bar) have something to read.

That mirror has to defend itself, or it becomes a second source of truth by a
different route: Roblox inserts a default passive-regen script into every
character (1% of `MaxHealth`/second) unless something overrides it, and that
would drift `Humanoid.Health` away from `records[player].state.current` on its
own, in addition to the client-replication case above. Rather than adding an
empty `Health` script under `StarterCharacterScripts` — which would mean
touching the Rojo mappings, explicitly out of scope for this feature —
`HealthService` connects to the character's `Humanoid.HealthChanged` and
snaps `Humanoid.Health` back to `records[player].state.current` whenever the
two disagree. Once they match, re-applying the same value is a no-op, so this
cannot loop. This is ordinary server-authority reassertion (the same idea as
`Net`'s "the server validates, the client does not get to assert state"), not
an anti-cheat system: there is no detection, logging-for-punishment, or rate
limiting here, just "this service owns this number."

One gap this does **not** close: a modified client can still change what its
*own screen* shows for its own Humanoid's `Health` between the moment it
diverges and the next `HealthChanged` correction, and Roblox's real `Died`
event fires off the live `Humanoid.Health` value, not off
`records[player].state`. A client could theoretically force their own
Humanoid's health to 0 to trigger a cosmetic death/ragdoll `HealthService`
does not know about, or hold it above 0 to delay the visual effect of a lethal
`takeDamage` call by a frame. Nothing today depends on that timing — there is
no combat, no rewards, no kill credit — so closing it completely would mean
building exactly the anti-cheat system this feature is explicitly not meant
to add. Revisit this when Combat lands: at that point `Humanoid.Died` becoming
meaningful for game logic (not just visuals) is the signal that this mirror
needs to become an actively-defended one.

## The client never names its punch target

`PunchRequest` carries no arguments. The client reports that the player
swung; `CombatService` works out who was in front of them, from server-side
character positions, and applies the damage itself.

The alternative — the client sending the target it thinks it hit, with the
server validating range afterwards — is more common in Roblox projects and is
noticeably easier to write. It also means the server is checking a claim
rather than making a decision, and every such check is one exploit away from
being incomplete: a modified client that reports a plausible-but-wrong target
only has to satisfy the checks the server actually wrote. With no arguments
there is nothing to validate, because there is nothing to lie about. The only
thing a client controls is how often it asks, and that is rate-limited with
the same cooldown constant the honest client uses.

The cost is real and worth stating: server-side selection uses the server's
view of positions, so a player on a bad connection will occasionally swing at
someone who has already moved on the server and see nothing happen. That is
the correct failure direction for a fighting game — a missed hit is a worse
experience than a stolen one, but a stolen one is a worse *game*.

Target selection is "nearest player inside a 120-degree cone" rather than a
raycast or a hitbox. It costs one distance and one dot product per player, it
has no dependency on limb colliders or animation timing, and it is entirely
expressible in numbers — which is why `PunchRules` is unit-tested and
`CombatService` is a thin wrapper around it. Revisit this when weapons with
real reach arrive; a sword swing probably wants a shape query.

`PunchRules` lives in `src/shared/Combat/`, not server-side, so the client can
reuse `canPunch` to avoid firing a remote it already knows will be dropped.
Nothing in it is worth hiding: knowing the reach and the cone angle does not
let a modified client exceed either, since the server recomputes both. The
alternative was a second copy of the same cooldown predicate on the client,
which is exactly the kind of duplication that drifts.

### What this means for the `Humanoid.Health` mirror

The previous section left an open question: whether combat landing would make
`Humanoid.Died` meaningful for game logic and force the health mirror to
become actively defended. It does not, yet.

`CombatService` reads `Humanoid` for nothing but position — liveness comes
from `HealthService.isDead`, which is server state, and damage goes through
`HealthService.takeDamage`. A client faking its own `Humanoid.Health` still
appears alive and targetable to the server, and still takes damage normally.
So the gap described above stays cosmetic and stays open. The signal to close
it is kill credit, death rewards, or respawn timers keyed off `Humanoid.Died`
— none of which exist yet.
