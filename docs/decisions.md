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

## The punch animation's `Hit` marker is the attack's timing

`PunchController` fires `PunchRequest` from
`track:GetMarkerReachedSignal(Config.PunchHitMarkerName)`, not from the click
that started the swing. The marker sits on the frame of `Punch_Right`
(`rbxassetid://86842108763107`) where the fist actually connects.

The alternative is a delay: click, `task.wait(0.25)`, fire. It is one line
shorter and it is wrong twice over. It hard-codes a number that belongs to the
animation, so re-exporting the swing with different timing silently
desynchronises damage from what the player sees, with nothing failing loudly
enough to notice. And it is a number nobody can derive — whoever tuned the
keyframes already knows exactly when the punch lands, and the marker is how
they say so. Polling `track.TimePosition` on `Heartbeat` has the same problem
plus a per-frame cost, for a signal the engine already raises.

The cost is that a missing or renamed marker stops punches landing entirely,
with no error. That is why the marker name is in `Config` next to the asset id
rather than buried as a string literal, and why `Config.spec.luau` asserts
both are well-formed. Neither check can prove the marker exists inside the
published asset — only Studio can, which is step 17 in `docs/testing.md`.

Nothing moved to the client. The marker decides *when* the request is sent;
`CombatService` still decides who was in range, whether they were alive, and
how much damage they take. A modified client that fires `PunchRequest` on a
loop still gets rate-limited by the same cooldown as everyone else, because
the server never trusted the timing in the first place — it only trusts its
own clock.

### The cooldown did not need changing

The request now arrives a fraction of a second later than the click, so
`CombatService`'s cooldown window shifts by that fraction. It does not narrow:
every punch is offset by the same marker delay, so the interval between two
consecutive requests is still the interval between two clicks. The client
keeps gating on the click rather than the marker, so a click made during the
cooldown plays no swing at all — a swing that visibly happens but deals no
damage would read as a bug.

## Punch reach is judged against where the attacker saw the target

`CombatService` corrects each candidate's distance with
`PunchRules.perceivedDistance` before testing reach, using the target's own
server-side `AssemblyLinearVelocity` and a fixed window
(`Config.PunchLagCompensationSeconds`).

Without it, chasing somebody was close to unplayable while punching a
stationary opponent worked fine. Every client draws other players from
replicated state, so the target on the attacker's screen is where the target
*was*, roughly a round trip ago. A target running away is therefore drawn
nearer than the server has it, by its own speed times that delay — at the
sprint speed in `Config` that is around three and a half studs, which is most
of an entire `PunchRange`. The attacker punches when the target looks well
inside range and the server, checking a fresher position, correctly reports a
miss. Both players are behaving honestly and the punch still fails, every time,
in the same direction.

This is the standard "I hit him on my screen" trade, and it is resolved the
standard way: favour the attacker's view, because that is the only frame a
player can actually aim in.

The allowance is deliberately partial. Once `PunchRange` was tightened to an
arm's length, returning the whole error would have given a sprinting runaway an
effective reach past eight studs — wider than the sevens and fives that were
tightened away precisely for landing punches across a visible gap. So
`PunchMaxCompensationStuds` hands back about half of it: a chase punch reaches
roughly six and a half, and some punches that genuinely looked like they
connected on a full-sprint target will still miss. That is a real cost, and it
is the right side to err on while the reach is this tight relative to the
sprint speed — the alternative is a punch that visibly lands from too far, which
is the complaint the range tuning was answering.

Three things keep it from becoming a licence to hit anything. The allowance is
computed from the *target's* velocity, so an attacker cannot manufacture reach
for themselves — and a victim who lied about their own velocity would only make
themselves easier to hit. It is capped in studs
(`Config.PunchMaxCompensationStuds`), so a character that has been launched, or
one reporting nonsense, cannot turn a punch into a ranged attack. And it only
ever moves the distance, never the cone: `facingDot` is still computed from
live positions, so nothing behind or beside the attacker becomes reachable no
matter how fast it is travelling.

A stationary target gets an allowance of exactly zero. That is deliberate — the
cases that already worked had to keep behaving identically, and the clamp
floors at zero so a target closing on the attacker is never pushed away.

### Why a constant and not the attacker's ping

`Player:GetNetworkPing` is the obvious source for the window and is not used.
Its unit is genuinely unclear — the official reference does not pin it down and
community sources disagree over seconds versus milliseconds — and reading it in
the wrong one would silently clamp every punch to the ceiling, which looks like
a working game with a suspiciously long reach rather than an error. It also
scales reach with the attacker's own connection quality, which rewards a worse
one. A constant treats every player the same, is a single number to tune after
play-testing, and is trivially unit-testable. Per-player compensation is worth
revisiting if the fixed window turns out to be visibly wrong for some players,
and it needs the unit settled first.

### What this does not do

There is no position history and no rewind. The correction is a first-order
reconstruction from current velocity, which is accurate for someone running in
a straight line — the case that was broken — and degrades for someone changing
direction inside the compensation window. A full rewind needs a per-player ring
buffer sampled every frame, and `RunService.Heartbeat` needs a justification in
this repository. It is not justified by a punch with a seven-stud reach.

There is still no line-of-sight check, exactly as before: reach and cone are the
whole test, and this change does not let a punch travel through anything it
could not travel through yesterday.

### Known limitation: the victim sees a ranged punch

Play-tested across two machines, and the trade above is visible in exactly the
way the theory predicts. Chase punches now register — that part works. But the
two players no longer agree on what happened: on the attacker's screen the two
characters are touching, while on the victim's screen the attacker is still
some way behind them and the hit reads as a punch thrown from thin air.

This is not a tuning failure or an unfinished fix. It is the cost of favouring
the attacker's view, and it cannot be tuned away, because the two clients
genuinely disagree about where everybody was. The only choices are:

- **Favour the attacker** (what we do). Hits land when they look like they
  should to the person swinging. The victim is sometimes hit from a distance
  that looks impossible on their own screen.
- **Favour the victim.** Nobody is ever hit unfairly, and chase punches that
  visibly connect silently fail — which is the bug that started all of this.

There is no third option. Every networked fighting game picks one and pays for
it somewhere.

**Decision: leave it.** Punching a chased opponent working at all is worth more
right now than the two views agreeing, and the discrepancy is bounded by
`PunchMaxCompensationStuds` rather than open-ended. Revisiting it properly means
position history and rewind, which is a real piece of engineering and not
justified by a single unarmed attack.

**Revisit when weapons land.** Two reasons, and the first is the dangerous one:

1. The allowance is a **flat stud value** added on top of whatever the reach is.
   A weapon with longer reach does not need a proportionally larger correction —
   the replication error depends on the target's speed, not on how long your
   sword is — so a fixed 2 studs will look progressively more wrong as reach
   grows. It may want to become proportional, or to stay fixed while reach
   grows around it. That is a deliberate decision to make, not something to
   leave to whichever number was tuned for fists.
2. More reach means a larger absolute gap between the two players' views, so
   the complaint above gets louder before it gets quieter.

`PunchMaxCompensationStuds` is the dial for how bad this looks, not
`PunchRange`. Lowering it makes the victim's experience more believable and
chase hits less reliable, in that order.

## The parry's phases are client-reported and server-held

Holding Q raises a guard that stops punches from the front. The client owns the
key, the animation and the `Hold` marker; `ParryService` owns the phase, and
`CombatService` asks it whether a punch is stopped. The three transitions
(`begin`, `hold`, `end`) travel over `ParryStateRequest` and are the only thing
the client contributes.

The obvious objection is that this trusts a client to say when it is protected.
It is worth being precise about what that trust actually buys, because it is
much less than it first appears. A modified client can send `begin` and `hold`
back to back and reach the guard without playing the wind-up. It cannot widen
the arc, because `ParryService` recomputes the direction from both root parts.
It cannot guard while dead or after respawning, because `CharacterRemoving`
clears the record server-side. It cannot claim a guard it never asked for,
because `hold` from idle is a no-op inside `ParryState`. And it cannot punch
while it claims to be guarding, because `CombatService` refuses that too. The
entire exploit is *skipping the wind-up*, and the wind-up is a fraction of a
second.

Closing even that would need a server-side timing floor: refuse to treat a
guard as raised until the animation's own time-to-`Hold` has elapsed. It was
considered and deliberately left out. The floor needs a number that only the
animation knows, which puts us back in exactly the position
`PunchHitMarkerName` exists to avoid — a hand-measured constant that silently
rots the next time the animation is re-exported, except this one rots in the
direction of "the guard mysteriously does not work for the first few frames."
Revisit it if parry-skipping ever turns out to be worth doing; the hook is a
single comparison in `ParryService.isProtectedFrom`, not a redesign.

### Why a remote at all

There is no existing channel. `PunchRequest` carries no arguments by design and
must not gain any. Health reaches the client by being mirrored onto
`Humanoid.Health`, which replicates on its own — there is no equivalent
property for "guarding" that the server could simply read.

The one genuine alternative was to skip the remote and have the server inspect
the character's `Animator` directly, since animations played on a
client-network-owned character do replicate. It was rejected because it is not
actually more authoritative: the `Hold` marker does not fire reliably on the
server for a client-driven track, server-side `TimePosition` is approximate,
and a modified client can play the same track at speed 0 or from an arbitrary
position. It would have bought the same amount of trust while being much harder
to read.

### The two races, and why neither is compensated

The guard begins at a marker on the client and is enforced on the server, so
the two disagree for about one trip time in both directions. Reaching `Hold`
before the server has processed it means a punch in that window lands despite
the player seeing themselves guarded — that favours the attacker. Releasing Q
before the server has processed *that* means a punch in that window is stopped
despite the player having let go — that favours the defender. They are
opposite-signed and bounded by the same window, so they broadly cancel out.

Neither is compensated. A client-supplied timestamp would just be one more
thing to lie about, and re-affirming the state on a timer would mean sending a
remote on a schedule, which this repository does not do. This is the same shape
of trade as the punch reach above: the server's clock is the truth, and the
discrepancy gets written down rather than papered over.

Stale state is a different problem from lag, and it *is* closed. Every way a
parry ends other than the key coming up is observed server-side rather than
reported: `CharacterRemoving` clears the record on death and respawn, and
`PlayerRemoving` clears the tables. A client that never sends `end` loses its
guard the moment it dies or leaves. A lease that expired a guard after some
number of seconds was considered and rejected — `RemoteEvent` delivery is
ordered and reliable, so it would cap legitimate long holds to defend against a
failure that does not really happen.

## The guard is the forward hemisphere, in the punch's own units

`Config.ParryMinFacingDot` is `0`, compared with `>=`, against the dot product
of the defender's look vector with the direction the attacker is in. That is
the same quantity `PunchRules` calls `facingDot`, with the two roles swapped:
the punch asks "is the target in front of the attacker", the parry asks "is the
attacker in front of the defender."

Reusing the convention rather than inventing an angle threshold matters more
than it sounds. Two directional tests in one damage path that disagreed about
what "in front" means would be a bug nobody could see by reading either one of
them. As it stands both are computed in the same function call from the same
live positions, and both are dot products against a tunable in `Config`. The
punch's `0.5` is a 120-degree cone; the parry's `0` is the whole front half.

The parry direction is deliberately **not** lag-compensated.
`PunchRules.perceivedDistance` corrects distance only, and the punch's own cone
is judged from live positions for the same reason — a guard that widened itself
according to how fast somebody was running would be a different feature.

The boundary is inclusive, so an attack from exactly 90 degrees is stopped.
That matches `PunchRules.isInReach`, which is also `>=`. Nothing hinges on it —
a punch landing on precisely the boundary is not a case that occurs in practice
— but the two comparisons agreeing means neither has to be looked up.

## `RunningController` stays the only writer of `WalkSpeed`

Parrying slows the player to `Config.ParryWalkSpeed` (8, against 16 walking and
24 sprinting), and parry outranks sprint, so holding Shift and Q gives 8.

The slowdown is applied by `RunningController`, not by `ParryController`.
`ParryController` reports its phase through `RunningController.setParryActive`
and never touches the Humanoid. This is the whole reason `SprintState` grew a
`parryRequested` field instead of the parry keeping its own modifier: two
controllers assigning `WalkSpeed` would fight, and the failure would be
intermittent and awful to reproduce — releasing Shift would clear a parry's
slowdown, ending a parry would clear a sprint, and the order the two keys came
up in would decide who won.

With one state holding both intents, the speed is recomputed from scratch on
every change rather than saved and restored, so there is no modifier that can be
left behind. A parry that ends while Shift is still down goes straight back to
24; a sprint released mid-parry leaves the parry at 8 and only drops to 16 when
the guard does. Those transitions are covered in
`tests/client/RunningController/SprintState.spec.luau`.

`SprintState` keeps its filename despite now describing movement intent
generally. Renaming it to `MovementState` would have churned the controller, its
spec and three documents for no behavioural gain, inside a feature branch that
is supposed to be reviewable.

Note that this leaves the slowdown client-authoritative, exactly as sprinting
already is: a modified client can guard at full speed. That is the same gap the
sprinting section above describes, and parry is arguably the system that section
predicted would close it. It does not close it, on purpose — making `WalkSpeed`
server-authoritative is a larger change than the parry itself, and doing it here
would have buried the feature inside a movement refactor.

## The wind-up costs something, so cancelling is not free

`ParryState` keeps three phases — idle, attempting, active — rather than one
boolean, because "asked to guard" and "actually guarding" have to differ.
Protection begins at the `Hold` marker and nowhere else: a player who releases Q
during the wind-up was never protected, and no ordering of transitions can
produce a guard except `begin` followed by `hold`.

The slowdown and the punch lockout, though, begin at the key press. That is
deliberate and it is what stops the wind-up being a free action. If cancelling
before `Hold` cost nothing, tapping Q would be pure profit — a way to flicker
in and out of the state at no risk. Paying the speed and the swing from the
moment the key goes down means a cancelled parry is a real, if small, mistake.

Blocking the punch is enforced twice, and the two are not redundant.
`PunchController` refuses to *play* a swing while engaged, because a swing that
visibly happens and deals no damage reads as a bug — the same reasoning as the
client-side cooldown gate. `CombatService` refuses the request, because that is
the one that counts.

## The `Hold` pose is held by freezing the track

At the marker, `ParryController` calls `track:AdjustSpeed(0)`. Roblox keeps
applying a playing track's current pose at speed 0, so the character stays in
the guard with no loop, no re-play and no per-frame work. Releasing Q restores
the speed and then stops the track with a short fade.

Looping the animation was the alternative and is wrong: a loop would replay the
wind-up under a guard that is already up, and would fire the marker again on
every cycle. Re-playing it on a timer has the same problem plus a timer. Neither
buys anything over a paused track.

The animation is started exactly once per parry, which is why the marker fires
exactly once and why `Play()` is preceded by `Stop(0)` — `Play()` on a track
that is already playing does nothing, and swallowing the marker would cost the
player the entire guard rather than just a frame of animation.

The same failure mode as the punch applies, and it is worth stating because it
is silent: if `Config.ParryHoldMarkerName` is missing from the published
animation, or is spelled differently, the parry winds up forever. The player is
slowed and cannot punch, and never becomes protected, with nothing in Output to
say why. That is why the marker name sits in `Config` next to the asset id, and
why `Config.spec.luau` asserts both are well-formed. Neither check can prove the
marker exists inside the published asset — only Studio can.
