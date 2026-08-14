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

This trusts a client to say when it is protected, and it is worth setting out
precisely where that trust ends, without flattering it. **The parry is not
cheat-proof.**

What the server decides, and a modified client cannot touch:

- **Whether a guard is up at all.** The phase lives in `ParryService`, and
  `hold` with no `begin` behind it is a no-op inside `ParryState`.
- **The direction.** `ParryState.attackerDot` is fed both characters' live
  server-side positions and the defender's own `CFrame.LookVector`. Nothing on
  the wire influences it, so the rear half cannot be closed from the client.
- **The damage.** `CombatService` still decides who was hit and for how much,
  and `HealthService` still applies it.
- **Whether a guarding player may punch.** `CombatService` refuses it.

What a modified client can still do, all of it accepted for now:

- **Skip the wind-up**, by sending `begin` and `hold` back to back. There is no
  server-side timing floor — see below.
- **Hold a guard for as long as it likes**, by never sending `end`. There is no
  maximum duration — see below.
- **Guard without playing the animation**, so opponents get no visual tell. The
  animation is client-played, and making the server verify it would mean
  trusting a different client-driven signal rather than no longer trusting one.
- **Guard at full speed.** `WalkSpeed` is client-authoritative, exactly as it is
  for sprinting, so the slowdown that is supposed to pay for the protection is
  not enforced. This is the largest remaining gap and it is a movement problem,
  not a parry one.
- **Toggle the punch lock**, by sending `end`, punching, and sending
  `begin`/`hold` again. The lock costs a modified client nothing; it is there so
  honest clients and the server agree about what a guard means.
- **Aim the guard perfectly**, by rotating its own character to face whoever is
  attacking. Characters are client-network-owned, so facing is theirs. Any
  directional guard on a client-owned character has this property.

The honest summary is that this raises the cost of cheating and bounds the
damage, rather than preventing it. Closing the movement gap is what would change
the picture materially, and that means making `WalkSpeed` server-authoritative —
the step `docs/decisions.md` has been pointing at since the sprinting section,
and deliberately out of scope for this feature.

### No timing floor on the wind-up

Refusing to treat a guard as raised until the animation's own time-to-`Hold` had
elapsed was considered and deliberately left out. The floor needs a number that
only the animation knows, which puts us back in exactly the position
`PunchHitMarkerName` exists to avoid — a hand-measured constant that silently
rots the next time the animation is re-exported, except this one rots in the
direction of "the guard mysteriously does not work for the first few frames."
Revisit it if parry-skipping turns out to matter; the hook is one comparison in
`ParryState.isProtectedFrom`, not a redesign.

### A guard has no maximum duration, and that is a gameplay decision

Holding Q guards. It keeps guarding for as long as the key is held — one
second, twenty seconds, two minutes — and only an explicit release, a death, a
respawn or a disconnect ends it. `ParryState` reads no clock at all, so there is
no path out of `active` that the player did not ask for.

A five-second ceiling was tried and removed. It was introduced to bound a
modified client that sends `begin` and `hold` and then simply never sends `end`,
and it did bound that — but it could not tell that client apart from an honest
one, so it also cut off any player who chose to hold a guard while waiting for
an opening. A defensive stance that silently stops defending after five seconds
is a worse game than one that can be exploited, and the exploit it prevented was
not the expensive part of cheating here anyway.

**So this is a real, accepted increase in exposure, and it should not be read as
anything else.** A modified client can now hold a permanent front-facing guard
for the entire life of its character: it never sends `end`, never plays the
animation, and never slows down, because none of those three are things the
server checks. It still cannot widen the arc, cannot cover its back, and cannot
punch without first releasing the guard — but "front-immune indefinitely" is
available to anyone willing to modify their client, and no part of this feature
prevents it.

What actually closes that gap is making the slowdown real, because the slowdown
is what a guard is supposed to cost. That means server-authoritative
`WalkSpeed` — the step the sprinting section above has been pointing at — and it
is out of scope here. Until then the parry is honest-player infrastructure with
a server-authoritative *decision*, not a server-enforced *cost*.

### Never drop a valid transition

An earlier version of this rate-limited `begin` on the server and returned
without applying it. That was a bug, and the shape of it is worth remembering:
the client went `idle → attempting → active` while the server stayed `idle`, the
following `hold` became a no-op against an idle state, and the player wound up
slowed, unable to punch, watching their own guard animation, and taking full
damage from the front. Two `begin` messages inside a tenth of a second is
something an ordinary double-tap produces.

So there is no rate limiter on the phase, and there should not be one. Repeats
are made harmless *in the state machine*, where an ignored transition still
leaves both sides agreeing, rather than by discarding messages, where it does
not. The invariant is: **a valid transition is always applied.** Spam is
bounded instead by the fact that no transition allocates or schedules anything
beyond one small table, and that a malformed payload is dropped in silence —
`ParryService` deliberately does not `warn` on rejected input, for the same
reason `CombatService` does not log a punch inside its cooldown: the payload is
attacker-controlled, so a line per rejection is a way to flood the output on
demand.

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

Stale state is a different problem from lag, and it is closed for every case
except one. Each way a parry ends other than the key coming up is observed
server-side rather than reported: `CharacterRemoving` clears the record on death
and respawn, and `PlayerRemoving` clears it on disconnect. The exception is a
client that stays connected, stays alive, and simply never sends `end` — nothing
bounds that, deliberately, for the reasons above.

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

## Screen effects read the Humanoid, and add no remote

`ScreenEffectsController` draws the damage, healing and death vignette from
`Humanoid.HealthChanged` and `Humanoid.Died` on the local character. It adds no
entry to `Remotes.luau` and touches no server file.

The channel already exists and is already documented. `HealthService` owns the
authoritative number and mirrors it onto `Humanoid.Health`/`MaxHealth`, Humanoid
properties replicate server → client on their own, and `HealthBarController`
has been reading exactly this since the health bar landed — for the reason
given there: a display-only system that shows a player their own health has
nothing worth lying to. A `HealthChangedEvent` remote would be a second copy of
a channel that already works, and a second thing to keep in step with the
mirror, in exchange for nothing. Each entry in `Remotes.luau` is a hole in the
boundary somebody has to defend; this feature does not need one.

Nothing about authority moves. `HealthService.takeDamage`/`heal` remain the only
writers, `CombatService` remains the only caller in combat, and a modified
client that forces its own `Humanoid.Health` still only changes the colour of
its own screen — the same cosmetic gap the health mirror section above already
describes and deliberately leaves open.

### Death is bound twice on purpose

The vignette is triggered both by `Humanoid.Died` and by health reaching zero
inside `ScreenEffectState.forHealthChange`. That is not a duplicate: Roblox does
not promise which of the two the client sees first, and a killing blow that drew
an ordinary red flash before the death caught up would read as a stutter.
Whichever arrives first plays the death; the other finds a death already showing
and `withEffect` returns the state untouched, so it plays exactly once either
way.

### The vignette is built in code, not in `StarterGui`

This is the one screen in the game that `docs/ui-workflow.md` does not apply to,
and it is worth saying why rather than leaving it to look like an oversight.

That rule exists so the designer owns layout. This has none to own: four
full-bleed bands pinned to the four screen edges, no position, no text, no
styling, and a size that is animated every frame from `Config`. There is nothing
for a designer to place, and a `StarterGui` copy would only be a set of instances
they must not touch. Building it in `StarterGui` would also make the feature
inert until the place file caught up, for no benefit — the health bar has a real
layout and correctly lives there; this does not.

Everything anybody would actually retune — the three colours, both reaches, all
four durations, the intensity range — is in `Config`, not baked into the
controller. If the effect ever grows a border, an icon, or anything with a
position, that is the signal to move it into `StarterGui` and drive it by name
like `HealthBar`.

### Four gradient bands rather than one vignette texture

An `ImageLabel` with a radial vignette texture is the usual way to do this, and
it would be a reasonable swap later. It is not what shipped, because it needs an
uploaded image asset: `assets/images/` is empty, and an unpublished or wrong
`rbxassetid://` fails silently — exactly the failure mode the punch and parry
animations already document, except that here it would leave the feature
invisible with nothing in Output.

Four `Frame`s with a `UIGradient` each need no asset at all, and they buy the
expanding death effect for free: the spread towards the centre is each band's
`Size` growing, which a single fixed texture cannot do without a second texture
or a scale trick. The cost is four instances instead of one, all of them inert
(`Active = false`, so none of them can swallow the click that throws a punch).

### One tween, driven through a `NumberValue`

Every visible property is derived from a single 0-to-1 `Level` value, and only
that value is ever tweened. Tweening the bands directly would mean eight tweens
— four transparencies and four sizes — that a second hit mid-fade could leave
half-replaced, which is the "old effects fighting new ones" failure this feature
has to avoid.

With one driver there is exactly one tween at a time. A new effect cancels the
previous one and rises from wherever the level had got to, so repeated damage
lifts the vignette back up instead of restarting it from black. `Cancel()` alone
is not quite enough, because the fade a hit queues is started from the rise's
`Completed` handler: a generation counter makes a handler belonging to a
replaced tween do nothing, so a stale fade can never start on top of a newer
effect.

## Combat and health audio

Four sounds landed at once — a punch swing, a punch impact, a damage sting and
a heal sting — and they are deliberately not one system. Each is played by the
system that already owns the event it belongs to.

### A helper in `Shared/Util`, not an audio controller

`Shared/Util/Audio.luau` builds a Sound from a `Types.SoundSpec` and starts it.
That is the whole of it: no manager, no channel table, no registry, no state,
and nothing in the boot sequence. Every caller keeps its own Sound and decides
when it starts and stops, because every one of them already owns the event that
decides.

An `AudioController` was the alternative and would have been worse. Three
systems need a sound, and each needs it at a different moment, in a different
realm, with a different lifetime — a controller in the middle would have to be
told all three of those things by the caller anyway, and would add a boot entry
and an indirection for it. What the three actually share is six property
assignments and a cleanup rule, so that is what was factored out. Nothing is
scattered: every id, volume, speed and roll-off distance is in `Config`.

It is in `Shared/Util` rather than under `src/client` because the server needs
it too. See below.

### The impact is played by the server, the swing by the client

They are split because the two events live in different places, not for
symmetry.

The **swing** starts on the same line as the animation, in `PunchController`,
because that is where a punch visibly begins. It is fitted to
`AnimationTrack.Length` rather than to a duration written down anywhere, so a
re-exported animation re-fits the sound instead of drifting from it — the same
reason the hit timing comes from a marker rather than a `task.wait`. Speed does
as much of the fitting as it can within `PunchSwingMinPlaybackSpeed` and
`PunchSwingMaxPlaybackSpeed`, and a short fade takes off whatever the cap
refused, so a much longer sound is trimmed rather than pitched into a different
sound.

The **impact** is created in `CombatService`, on the server, inside the target's
`HumanoidRootPart`. A Sound inside a replicated part is heard by every client
near it, so both players hear the hit, positioned, with no remote at all. The
client could not do this even if we wanted it to: `PunchRequest` carries no
arguments and the attacker is never told whether it connected, which is the
whole point of that design. Playing it client-side would mean either a new
remote whose only cargo is a sound, or the client deciding it hit — and the
second is the thing this codebase is built not to do.

There is no hit part or hitbox to originate it from, because this combat system
has none: reach is a distance between two root parts and the cone is a dot
product. The target's root part *is* where this architecture says the punch
landed, and `CombatService` already has it in hand from target selection.

The consequence, stated plainly: **only the attacker hears their own swing.**
Sounds made on a client do not replicate, and the server does not learn a punch
happened until the `Hit` marker — half way through the swing, which is the wrong
moment to start a whoosh. Making the swing audible to everyone means moving it
onto the character and adding a remote for it. The half that matters to the
player being hit is the impact, and that one is heard by both.

### Overlap is structural, not managed

The swing and the impact never interfere because they are not the same Sound,
not in the same realm, and not owned by the same system. `PunchController` can
restart or fade its swing as often as it likes and the impact — a separate,
server-created, self-destroying instance — is untouched. There is no mixer
deciding they may overlap; there is nothing that could stop them.

Within each sound, repeats restart rather than layer, matching what the systems
around them already do. A new punch stops the previous swing exactly as it stops
the previous animation, and a new health event replaces the feedback sound
exactly as it replaces the vignette. So mashing the punch key produces one
whoosh at a time and as many impacts as actually landed, which is the correct
answer to both.

### Health feedback has no timing of its own

The damage and heal sounds do not have a duration, a fade, or a timer. Their
volume is `peak × level`, where `level` is the same 0-to-1 driver
`ScreenEffectsController` already uses for the vignette's transparency and
reach.

That is what "synchronised" means here, rather than two systems configured to
similar numbers: there is one envelope. A hit landing mid-fade lifts the colour
and the sound together, a heal replaces both, a respawn takes both down, and
retuning `ScreenEffectFadeSeconds` moves the audio with it because there is
nothing else to move. The sound cannot outlive the vignette, because it is
silent whenever the vignette is clear.

They are flat rather than positional — parented to `SoundService`, not to a
character. This is the player's own body reporting to them, and only they hear
it; a Sound outside a `BasePart` ignores roll-off entirely. That also means
neither can be destroyed underneath the controller when a character is removed,
which is why the punch swing is parented there too.

### Dying is silent, for now

No death sound was uploaded, and the killing blow is classified as a death
rather than as damage (see the screen effects section above), so it does not
play the damage sting either. Borrowing that sting would make dying sound like
being hit, which is the one thing the death effect exists not to be.

Adding one later is an entry in `Config` and an entry in `FEEDBACK_SPECS`, and
nothing else — the death effect already runs through the same envelope, so it
would be fitted to the spread automatically.
