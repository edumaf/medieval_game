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
    Audio.spec.luau
    Config.spec.luau
    Logger.spec.luau
    Combat/
      ParryState.spec.luau
      PunchRules.spec.luau
    Stamina/
      StaminaState.spec.luau
  server/
    DeveloperAccess.spec.luau
    HealthService/
      HealthState.spec.luau
  client/
    RunningController/
      SprintState.spec.luau
    HealthBarController/
      HealthDisplay.spec.luau
    ScreenEffectsController/
      ScreenEffectState.spec.luau
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

## Which test mode to use

Studio offers several ways to run the game, and they do **not** behave the
same. This matters because the `/damage` and `/heal` commands are gated on the
server.

| Mode | Where the server runs | `IsStudio()` on the server | Test commands |
| --- | --- | --- | --- |
| **Play** / **Play Here** (solo) | Locally, in Studio | `true` | Work, no setup |
| **Test → Clients and Servers** | Locally, in Studio | `true` | Work, no setup |
| **Team Test** | On a real Roblox server | **`false`** | Need your UserId in the allow-list |
| Published game | On a real Roblox server | `false` | Need your UserId in the allow-list |

**For testing multiplayer on one machine, use Test → Clients and Servers.** It
spins up a local server plus however many client windows you ask for, runs
entirely in Studio, and needs no configuration.

**Team Test** is for editing and testing together from different machines
(it requires Team Create). Because it runs on a real Roblox server,
`RunService:IsStudio()` is `false` there on the server — although confusingly
it is still `true` on the clients. Roblox provides no reliable way to detect a
Team Test server, so we authorise people instead of environments.

### Enabling the commands for yourself

Add your Roblox UserId to `DEVELOPER_USER_IDS` in
`src/server/DeveloperAccess.luau`:

```lua
local DEVELOPER_USER_IDS: { [number]: true } = {
	[123456789] = true, -- yourname
}
```

Your UserId is in your profile URL: `roblox.com/users/<UserId>/profile`. You
can also print it in Studio with `print(game.Players.LocalPlayer.UserId)`.

This is a normal code change — commit it in a PR like anything else. Listed
developers keep the commands on the published game too; that is deliberate, and
the reasoning (plus how to tighten it) is in `DeveloperAccess.luau`.

## Manual verification: test command access

1. **Play** solo, type `/damage 20`. Confirm health drops — this must work
   with an empty allow-list.
2. **Test → Clients and Servers** with 2 players, `/damage 20` on each.
   Confirm both work, and that damaging one does not change the other's health.
3. **Team Test** with your UserId *not* in the list. Confirm `/damage 20` does
   nothing at all — no health change, no error in Output.
4. Add your UserId, sync, restart the Team Test session, and confirm the
   command now works for you and still does nothing for an unlisted teammate.

## Manual verification: Health system

`HealthService`'s numeric rules are covered by
`tests/server/HealthService/HealthState.spec.luau`, but the Humanoid
integration — spawning, damage/heal through the chat commands, death, and
respawn — can only be checked by hand in Studio (see `docs/decisions.md` for
why `HealthService` keeps its own state instead of trusting `Humanoid.Health`
directly). The manual mechanism is `/damage <amount>` and `/heal <amount>`
typed in chat, which lets you set up an exact health value without having to
land a specific number of punches.

Who may use those commands is decided by `src/server/DeveloperAccess.luau` —
see "Which test mode to use" below before you try them with other people.

1. Start `rojo serve`, connect Studio, press **Play**.
2. Confirm the server and client each log `boot complete` exactly once.
3. Type `/damage 20` in chat. Confirm health drops to 80 (Output logs the
   result; a health bar is not part of this feature yet).
4. Type `/damage 500`. Confirm health lands at exactly 0, not negative.
5. Confirm the character dies exactly once — one ragdoll, one `Humanoid.Died`
   log line, not repeated.
6. Type `/heal 50` while dead. Confirm nothing happens — a dead character
   cannot be healed.
7. Respawn. Confirm the new character starts at 100 health.
8. Type `/heal 30`. Confirm health is clamped at 100, not above it.
9. Repeat damage/heal/death/respawn a few times. Confirm no duplicate
   `HealthChanged`/`Died` connections (watch for doubled log lines) and no
   stale state from a previous character.
10. With a second player in the server, damage one player and confirm the
    other player's health is unaffected.
11. Check Output for errors or warnings throughout.

## Manual verification: Health bar

`HealthBarController` drives the Studio-owned `StarterGui.HealthBar` from the
local player's Humanoid, so the fill and label can only be checked by eye.
`HealthDisplay.spec.luau` already covers the maths; these steps cover the
wiring. Use the same `/damage` and `/heal` commands as above.

1. Press **Play**. The bar appears only once real health arrives — confirm it
   is not showing the designer's 75/100 preview at spawn, but 100/100 full.
2. `/damage 25`, `/damage 25`, `/damage 25`. Confirm the fill steps down
   through roughly three quarters, half and one quarter of the track, and the
   label matches at each step.
3. `/heal 50`. Confirm the fill grows again and the label agrees.
4. `/damage 500`. Confirm the label reads exactly `0/100` and the fill is
   fully empty, with no sliver of green left.
5. Respawn. Confirm the bar returns to 100/100 and keeps updating — a bar that
   freezes after the first death means the Humanoid connections were not
   re-bound.
6. Repeat damage/death/respawn several times. Confirm the label never lags a
   step behind the fill, and Output stays clean.
7. Confirm the bar keeps its designer-set position, size and styling
   throughout — this controller only writes `Enabled`, `Fill.Size` and
   `Amount.Text`.

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

## Manual verification: Punch

`PunchRules` covers the arithmetic — cooldown, reach, cone, nearest-target
selection — in `tests/shared/Combat/PunchRules.spec.luau`. What no unit test
can cover is whether a punch actually connects between two real characters,
so this needs two players.

Use **Test → Clients and Servers** with 2 players (no allow-list needed), or
Team Test if you are on separate machines.

**Landing a hit**

1. Stand player A directly in front of player B, close enough to touch.
2. Left click on A. Confirm B's health bar drops by 25, and Output logs
   `A punched B for 25 -> 75`.
3. Punch three more times. Confirm B reaches exactly 0, dies once, and
   respawns at 100.
4. Confirm **A's** health never changes. You cannot punch yourself.

**Not landing a hit**

5. Face away from B and click. Confirm nothing happens — no damage, no log
   line. The cone is 120 degrees, so "slightly off to the side" should still
   connect; directly behind must not.
6. Walk well away from B (more than about 4.5 studs, and with B standing
   still) and click. Confirm nothing happens. B must be stationary for this
   step — a receding target is given a lag allowance on top of the reach, so
   the effective distance is larger while they run.
7. Click with nobody else in the server. Confirm no errors in Output.
8. Punch B while B is dead. Confirm nothing happens.

**Cooldown**

9. Click as fast as you can. Confirm damage lands at most about twice a
   second, not once per click, and that Output does not fill with warnings.

**Crowd behaviour** (needs 3 players, or move a second character into place)

10. With two targets in front of you at different distances, confirm the
    **nearer** one takes the damage.
11. With one player behind you and one in front, confirm the one **in front**
    takes it — being closer must not let the player behind steal the hit.

**Respawn**

12. Die, respawn, and punch again. Confirm it still works — a punch that stops
    working after your first death means the animation or character
    references were not re-bound.
13. Die and respawn several times, then punch **once**. Confirm B loses
    exactly 25, not a multiple of it. Damage that scales with how many times
    you have died means `CharacterAdded` is stacking marker connections
    instead of replacing them.
14. Punch, and while the swing is still playing, reset (Esc → Reset
    Character). Confirm the dead character's swing does not damage anyone
    after the new one spawns.

**Animation**

`Config.PunchAnimationId` is `rbxassetid://86842108763107` (Punch_Right), and
its `Hit` marker is what fires `PunchRequest` — the click only starts the
swing. Empty is still the supported "no animation" state, in which the hit is
reported on the click instead; skip 16–18 if you have blanked the id.

15. Confirm the swing plays for the attacker.
16. Confirm the **other** player sees it too. Animations played on your own
    character replicate automatically; if only you can see it, the animation
    was loaded on the wrong Animator.
17. Watch B's health bar against A's swing. Damage must land **mid-swing**, on
    the frame the fist arrives — not on the click, and not when the animation
    ends. This is the whole point of the marker; if damage lands instantly the
    marker is not connected.
18. Confirm one click deals damage exactly once. Two hits from one swing means
    the marker is connected more than once.
19. Confirm the punch reads over walking: run at B and punch while moving. The
    swing must be visible, not overridden by the walk animation (that is what
    `Action` priority is for).

**Chasing a running target**

This is the case lag compensation exists for, and the one that was broken. It
needs both players moving; standing still will not reproduce it. Run it with
two real clients — **Test → Clients and Servers** — not one client and a
dummy, because the whole effect comes from B's position being replicated to A.

20. Have B hold W and run in a straight line. Have A chase B holding W, sprint
    (Left Shift) if needed to close, and stay directly behind B.
21. While still moving, punch as soon as B looks within arm's reach on A's
    screen. Confirm B takes 25 and Output logs `A punched B for 25 -> 75`.
    Before the fix this is the punch that missed.
22. Repeat four times without stopping. Confirm B dies and respawns — the fix
    must hold up over repeated attacks, not just the first one.
23. Run the same chase in the opposite direction, and again along a different
    axis. The correction is computed from B's velocity, so it must not depend
    on which way the two of you are facing in the world.
24. Now have B outrun A properly — B sprinting, A walking — until B is clearly
    far ahead, well past arm's reach on A's screen. Punch. Confirm **nothing**
    happens. The allowance is a few studs, not a licence to hit at any range.
25. With both of you still running, have B cut sideways across A's view rather
    than away. Confirm punching at the empty space ahead of A does not hit B:
    the correction moves the reach check along the line to B, never the cone.
26. Stand still, both of you, and punch at normal range. Confirm it behaves
    exactly as it did before — a stationary target gets no allowance at all,
    so any change in feel here means something is wrong.

## Manual verification: Parry

`ParryState` covers the phases and the direction test in
`tests/shared/Combat/ParryState.spec.luau`, and the movement precedence is in
`tests/client/RunningController/SprintState.spec.luau`. What no unit test can
cover is the Q key, the animation, the `Hold` marker, the frozen pose, and a
punch actually being stopped between two real characters — so most of this
needs two players.

Use **Test → Clients and Servers** with 2 players, or Team Test if you are on
separate machines.

**Important:** `Config.ParryAnimationId` is `rbxassetid://82891306050913` and
its `Hold` marker is what raises the guard. Nothing in the repository can check
that the marker exists inside the published asset — step 3 is that check. If it
is missing or misspelled, the parry winds up forever: slowed, unable to punch,
never protected, and **nothing appears in Output**. Blanking the id is still the
supported "no animation" state, in which the guard is reached on the key press
instead; skip steps 2–4 if you have done that.

**Basic parry**

1. Hold Q. Confirm the parry animation starts.
2. Confirm it reaches its `Hold` position.
3. Keep Q held. Confirm the character **stays** in the Hold pose rather than
   playing on to the end, snapping back to idle, or looping the wind-up. A
   looping or restarting animation here means the track is not being frozen.
4. Still holding Q, walk around with WASD. Confirm the character moves and the
   guard pose stays up.
5. Confirm movement is visibly slower than normal (8 against 16).
6. Release Q. Confirm the pose is dropped cleanly and movement returns to 16.

**Front attacks** — B holds Q and is in the Hold pose throughout

7. A punches B from directly in front. Confirm **0 damage**: B's health bar does
   not move, and Output logs `B parried A`.
8. Repeat from B's front-left. Confirm 0 damage.
9. Repeat from B's front-right. Confirm 0 damage.
10. Punch B repeatedly from the front for several seconds. Confirm B's health
    never drops at all.

**Rear attacks** — B holds Q and is in the Hold pose throughout

11. A punches B from directly behind. Confirm B takes the **normal 25** and
    Output logs `A punched B for 25 -> 75`.
12. Repeat from B's back-left. Confirm 25.
13. Repeat from B's back-right. Confirm 25.
14. Have B turn to face A while A keeps punching. Confirm damage stops landing
    the moment B is facing them — the arc follows B's character, not the world.

**The wind-up is not protected**

15. Have B press Q and have A punch **immediately**, before B's animation
    reaches Hold. Confirm B takes 25. Protection starts at the marker, not at
    the key press.
16. Have B tap Q and release it before Hold. Confirm B was never protected, the
    animation stops cleanly, and B's speed returns to 16.

**Normal combat is unchanged**

17. With nobody holding Q, confirm a punch still deals 25 from the front.
18. Confirm the 120-degree cone still works: punching someone directly behind
    you still does nothing.
19. Confirm the range still works: back off past about 4.5 studs from a
    stationary target and confirm the punch misses.
20. Confirm the cooldown still works: click as fast as you can, and confirm
    damage lands at most about twice a second.
21. Re-run the chase from step 21 of the punch matrix above. Lag compensation
    must behave exactly as it did before.

**Punching while parrying**

22. Hold Q and left click. Confirm **no swing plays at all** and no damage is
    dealt.
23. Press Q and click during the wind-up, before Hold. Confirm still no swing —
    the lockout starts at the key press.
24. Release Q and click. Confirm punching works again immediately.

**Edge cases**

25. Die while holding Q. Confirm the pose is dropped and nothing is left
    guarding.
26. Respawn. Confirm the new character is **not** parrying even if you never
    released Q, and that pressing Q again works normally on it.
27. Mash Q rapidly. Confirm the animation is not restarted underneath a raised
    guard, and that you end up in a sane state (either guarding or not) rather
    than stuck.
28. Hold Q, and while guarding, reset (Esc → Reset Character). Confirm the new
    character is at speed 16 and unprotected.
29. Have another player punch you from the front at the exact moment you release
    Q. Confirm nothing is left stuck — you are hittable a moment later either
    way.
30. Have two players both hold Q at once, and punch each from the front and the
    back. Confirm each is protected independently — one player's guard must not
    protect the other.
31. Leave the server while guarding, rejoin, and confirm you spawn unprotected
    at speed 16.
32. Press Q as fast as you possibly can, repeatedly, from a standing start.
    Confirm every parry that visibly reaches the Hold pose **actually
    protects** — punch from the front on each one. A guard that animates but
    does not protect means a valid transition is being dropped somewhere, which
    is the bug removing the transition rate limiter was meant to make
    impossible.
33. Press Q within the first instant of spawning, before the character has
    finished loading. Confirm you either get a normal parry with a visible
    wind-up, or nothing at all — you must **never** be protected immediately
    with no animation.

**A guard lasts as long as the key is held**

There is deliberately no maximum duration. These steps exist to catch a
timeout being reintroduced by accident.

34. Hold Q and keep holding it. Have the other player punch you from the front
    at roughly 2 seconds, again at 10 seconds, and again past a full minute of
    continuous holding. Confirm **0 damage every time** — the guard must not
    quietly stop working at any point.
35. Through that same long hold, confirm your speed stays at 8 and you still
    cannot punch.
36. Release Q after the long hold. Confirm the pose drops, speed returns to 16,
    punching works again, and a fresh press of Q guards normally.

**Movement interaction**

37. Hold Shift to sprint (24), then press Q while still sprinting. Confirm the
    speed drops to 8.
38. Release Q while still holding Shift. Confirm the speed goes straight back
    to **24**, not 16 — a parry must not strand a sprinting player at walking
    speed.
39. Hold Q, then press and release Shift underneath it. Confirm the speed stays
    at 8 throughout.
40. After several parry/sprint combinations, release everything and confirm the
    speed settles at exactly 16 with no modifier left behind.

**Counterpunch**

41. Hold Q, release it, and immediately left click. Confirm the punch comes out
    and lands. Then repeat, clicking as close to the release as you can manage.
    A punch that silently vanishes **and** leaves you unable to punch again for
    half a second means the parry rejection is consuming the punch cooldown.

42. Check Output for errors or warnings throughout. Malformed parry payloads are
    dropped silently by design, so nothing should appear there during honest
    play at all.

## Manual verification: Stamina

`StaminaState` covers the pool arithmetic — clamping at both ends, the empty and
full tests, the punch multiplier and the replication threshold — in
`tests/shared/Stamina/StaminaState.spec.luau`. What no unit test can cover is a
real character actually running, a guard actually ending when the pool runs out,
and the bar on screen. Most of the interesting steps need two players.

Use **Test → Clients and Servers** with 2 players, or Team Test if you are on
separate machines.

Before you start: the stamina bar is a Studio-authored screen. If
`StarterGui.StaminaBar` does not exist yet, Output carries one warning naming
the missing instance and the rest of the system still works — verify the
gameplay steps first and come back to the UI ones.

**Sprint**

1. Hold Shift and run. Confirm the bar appears and drains steadily.
2. Release Shift while still running. Confirm the drain stops and the bar starts
   refilling within a fraction of a second.
3. Let it refill completely. Confirm the bar disappears at exactly full and does
   not linger part-filled.
4. Hold Shift **standing still**. Confirm nothing drains — an idle player
   holding the key is not sprinting.
5. Hold Shift while walking face-first into a wall. Confirm nothing drains, for
   the same reason.
6. Sprint until the pool is empty, and keep holding Shift. Confirm you **drop to
   the walking speed** at the moment the bar reaches zero, and stay there.
7. Keep holding Shift and watch the bar refill. Confirm it refills steadily
   while you walk — the pool must recover under a held key, not stall at zero —
   and that you do **not** flicker between 16 and 24 as it climbs.
8. Still holding Shift, confirm you start sprinting again on your own at about a
   quarter of the bar (`Config.SprintRecoveryStaminaFraction`), without touching
   the key.
9. Sprint to empty again, then release Shift and immediately press it again,
   repeatedly. Confirm this does **not** get you sprinting — the lockout is
   released by the pool, never by the key.
10. Empty the pool by punching rather than sprinting (see the Punch steps), then
    hold Shift. Confirm you cannot sprint until the bar has recovered to the
    same quarter — exhaustion is exhaustion, whatever spent it.
11. Confirm sprinting itself is unchanged otherwise: 24 while held with stamina,
    16 on release, 8 while parrying, and normal walking never affected by any of
    this.
12. Sprint, die mid-sprint (Esc → Reset Character), and respawn. Confirm the new
    character starts on a full bar (so, a hidden one), that continuing to hold
    Shift drains it again, and that a death *while exhausted* leaves the new
    character able to sprint immediately.

**Punch**

13. Punch once from full. Confirm the bar appears and drops by one punch's worth,
   then refills.
14. Punch a target from full stamina. Confirm they lose exactly 25 and Output
    logs `A punched B for 25 -> 75`.
15. Punch at nothing, and punch someone who is guarding. Confirm stamina is
    spent both times — a swing costs whether or not it lands.
16. Drain the pool to zero with sprinting, then punch. Confirm the target loses
    exactly **7.5** and Output logs `for 7.5`. If you have retuned
    `PunchDamage` or `ZeroStaminaPunchDamageMultiplier`, confirm the logged
    number is the product of the two.
17. Punch repeatedly from full without sprinting until the pool empties.
    Confirm the punch that *empties* the bar still deals 25, and the next one
    deals 7.5. That ordering is deliberate — see `docs/decisions.md`.
18. Confirm the punch is otherwise unchanged at zero stamina: same cooldown,
    same swing animation, same reach, and still stopped completely by a guard.
19. Watch the Network graph (F9 → Network, or the Studio microprofiler) while
    holding Shift for ten seconds. Confirm stamina traffic is a handful of
    messages a second, not one per frame.

**Parry / block**

20. Hold Q from full. Confirm the bar appears and drains, more slowly than
    sprinting does.
21. Release Q. Confirm the drain stops and the pool refills.
22. Hold Q and Shift together. Confirm only **one** drain is charged, at the
    parry rate, matching the fact that you are walking at 8.
23. Hold Q until the pool empties. Confirm the guard **ends by itself**: the
    pose drops, and a punch from the front now lands for full damage.
24. Still at zero, press Q again. Confirm no guard starts — no animation, no
    slowdown, and a punch from the front still lands.
25. Let stamina regenerate a little, then press Q. Confirm a normal guard starts
    again, with its usual wind-up.
26. Have the other player punch you during step 23, in the moment the pool runs
    out. Confirm you take the damage — the guard genuinely ended and did not
    keep protecting you invisibly.

**UI**

27. Confirm the bar is hidden on join, before anything has been spent.
28. Confirm it appears the moment stamina drops below full and stays visible for
    the whole regeneration, not just while the key is held.
29. Confirm it disappears again once the pool is full.
30. Drain, die, and respawn. Confirm the bar is present, hidden and working for
    the new character — a bar that stops updating after a death means the
    ScreenGui has `ResetOnSpawn` on, or the controller lost its references.
31. Confirm the fill moves smoothly rather than in visible steps, and that it
    keeps up with a punch landing.

**Multiplayer and authority**

32. With both players sprinting, confirm each bar drains independently and
    neither moves when the other player acts.
33. Have one player empty their pool. Confirm the other player's punches still
    deal 25, their guard still works, and — with both holding Shift — that only
    the exhausted one drops to walking pace while the other keeps sprinting.
34. Have one player leave and rejoin. Confirm they come back on a full pool and
    that Output shows no errors about a missing record.
35. In the client console, set any local stamina value you can find and confirm
    it changes nothing that matters: punches keep dealing what the server says,
    and a guard started on a locally-faked pool is refused by the server.

36. Check Output for errors or warnings throughout. Malformed sprint payloads
    are dropped silently by design, so nothing should appear there during honest
    play at all.

## Manual verification: Screen effects

`ScreenEffectState` covers the rules — which vignette a health change deserves,
how strong it is, and which of two effects wins — in
`tests/client/ScreenEffectsController/ScreenEffectState.spec.luau`. What no unit
test can cover is what it actually looks like, whether the tween is smooth, and
whether the bindings survive a respawn. That is all by eye.

Solo **Play** is enough for most of this, using `/damage` and `/heal` from the
Health section above. Steps 15–18 need a second player.

**Taking damage**

1. `/damage 5`. Confirm a red vignette appears around the edges of the screen
   almost immediately and fades away smoothly over about half a second.
2. Confirm the middle of the screen stays clear throughout — you must be able
   to read the health bar and see what is in front of you the whole time.
3. `/damage 50`. Confirm the red is clearly stronger than it was for 5.
4. `/damage 40` from full health. Confirm it is stronger again. The three
   should be visibly ordered, not merely different.
5. Confirm the vignette is behind the health bar, not over it.

**Taking healing**

6. `/damage 80`, then `/heal 5`. Confirm a *green* vignette, subtle, same shape
   as the red one.
7. `/heal 60`. Confirm it is clearly stronger, and unmistakably green.
8. Confirm nothing green appears at spawn. Arriving at full health is not a
   heal, and a flash on join means the first health reading was treated as a
   change.

**Rapid changes**

9. `/damage 10` five times as fast as you can type. Confirm the effect stays at
   roughly one hit's strength rather than climbing to a solid red screen, and
   that it never flickers or snaps.
10. `/damage 60`, then `/damage 5` immediately. Confirm the screen does not
    visibly *drop* when the small hit lands — the stronger peak is held.
11. `/damage 60`, then `/heal 40` immediately. Confirm the red is replaced by
    green cleanly, with no flicker and no red left underneath.
12. `/heal 40`, then `/damage 60` immediately. Confirm the reverse works too.
13. Stand still at partial health for a full minute without typing anything.
    Confirm the screen stays completely clear — any slow red/green flicker here
    means `Config.ScreenEffectMinHealthChange` is too low for whatever is
    moving the Humanoid.

**Dying**

14. `/damage 500` from full health. Confirm:
    - the red is much stronger than any `/damage` vignette,
    - it *spreads inwards* from the edges over about a second rather than
      appearing at full size,
    - it covers most of the screen at its peak,
    - it then holds, rather than fading, until you respawn.
15. Repeat, and have a second player `/damage` you again while you are dead.
    Confirm the death vignette does not flinch — no extra flash, no fade.
16. Repeat, and have them `/heal` you while you are dead. Confirm nothing green
    appears.
17. Die by punches from another player rather than by chat command. Confirm the
    death effect starts on the killing blow, not a moment late and not twice.

**Respawn**

18. Respawn after a death. Confirm the screen clears smoothly over about a third
    of a second and is completely clear once you are up.
19. Take damage on the new character. Confirm the red vignette still plays — an
    effect that stops working after your first death means the Humanoid
    connections were not re-bound.
20. Die and respawn five times, then `/damage 10` **once**. Confirm you get one
    vignette at one hit's strength. An effect that gets stronger, or plays
    twice, the more you have died means `CharacterAdded` is stacking
    connections instead of replacing them.
21. Reset (Esc → Reset Character) mid-fade, while a red vignette is still on
    screen. Confirm the new character comes up with a clear screen.
22. Leave and rejoin the server. Confirm you spawn with a clear screen.
23. Check Output for errors or warnings throughout — a character being removed
    while an effect is playing must produce nothing at all.

## Manual verification: Combat and health audio

`Audio`'s fitting arithmetic — how far the swing may be pitched, and when the
rest has to be faded — is covered by `tests/shared/Audio.spec.luau`, and the
shipped ids, volumes and bounds by `Config.spec.luau`. Nothing in either can
tell you whether it *sounds* right, or whether two sounds that must overlap
actually do. All of that is by ear.

Steps 1–8 are solo **Play**. Steps 9–16 need **Test → Clients and Servers**
with 2 players.

**Punch swing**

1. Left click. Confirm the whoosh starts with the swing, not before it and not
   after it.
2. Confirm it is finished by the time the arm is back down. A whoosh still
   going while you are standing idle means the fade is not being scheduled —
   check `Config.PunchSwingFadeSeconds` and the playback speed bounds.
3. Confirm the swing does not sound obviously pitch-shifted or chipmunked. If
   it does, widen the gap between the animation and the sound with the fade
   rather than with `PunchSwingMaxPlaybackSpeed`.
4. Click as fast as the cooldown allows. Confirm you hear one whoosh per swing,
   restarting cleanly, never two layered on top of each other.
5. Punch, and while the swing is still playing, reset (Esc → Reset Character).
   Confirm the whoosh stops with the character rather than continuing over the
   respawn.
6. Punch immediately after respawning, several times over. Confirm the swing is
   audible every time and at full volume — a swing that goes silent after the
   first fade means the volume is not being restored.
7. Hold Q and click. Confirm **no swing sound at all**, matching the animation:
   the punch never happened.
8. Punch at empty air, with nobody in front of you. Confirm you hear the swing
   and **no impact**.

**Punch impact** (2 players)

9. Punch player B from in front, in range. Confirm a distinct impact sound
   lands mid-swing, on the same frame the health bar drops.
10. Confirm the impact does **not** cut the whoosh off. Both should be audible,
    the impact layered on top of a swing that keeps going. A whoosh that stops
    dead the instant the hit lands is the failure this is written to catch.
11. Confirm **B** hears the impact too, and that it comes from the right place —
    have B face away and confirm it is behind them.
12. Walk A well away from B and punch. Confirm neither player hears an impact.
13. Have B hold Q and parry a punch from the front. Confirm there is **no
    impact sound** — a parried punch dealt no damage and must sound like it.
14. Confirm B hears **no swing sound** from A. That is expected, not a bug: the
    swing is local to the attacker. See `docs/decisions.md`.

**Health feedback** (steps 15–16 with 2 players; the rest solo)

15. `/damage 25`. Confirm a damage sound plays with the red vignette, starting
    and finishing with it.
16. `/heal 25`. Confirm a different, healing sound plays with the green
    vignette.
17. `/damage 10` five times quickly. Confirm the sound restarts cleanly each
    time and never stacks into a chorus.
18. `/damage 40` then `/heal 40` immediately. Confirm the damage sound is
    replaced by the healing one rather than both playing at once, matching what
    the vignette does.
19. `/heal 40` then `/damage 40` immediately. Confirm the reverse.
20. `/damage 500` from full health. Confirm the death vignette plays in
    **silence** — no damage sting on the killing blow. That is deliberate; see
    `docs/decisions.md`.
21. `/damage 20`, and while the red is still fading, `/damage 500`. Confirm the
    damage sound stops when the death effect takes over rather than finishing
    underneath it.
22. Respawn. Confirm nothing is left playing.
23. In a 2-player test, damage **one** player. Confirm only that player hears
    the damage sound — the other must hear nothing at all. Repeat for `/heal`.
24. Check Output for errors or warnings throughout.

## Manual verification: Exhaustion vignette

`ScreenEffectState.forSprintLock` covers the edge rule — once on the way in,
never while held, never on release, again next time — in
`tests/client/ScreenEffectsController/ScreenEffectState.spec.luau`, and the
colour and intensity ordering is in `Config.spec.luau`. What no unit test can
check is what it looks like, or that it lines up with the moment the sprint is
actually taken away. Solo **Play** is enough for all of it.

1. Hold Shift and run until the stamina bar empties. Confirm a dark, near-black
   vignette appears around the edges the moment the sprint drops back to
   walking speed — the visual and the speed change are the same event and must
   not be a beat apart.
2. Confirm it is clearly darker at the edges and that the middle of the screen
   stays readable throughout.
3. Confirm it holds briefly at full strength and then fades out smoothly,
   rather than starting to fade the instant it appears. A vignette that snaps
   straight back reads as a hit, not as exhaustion.
4. Keep Shift held at zero stamina. Confirm the vignette plays **once** and does
   not re-trigger, pulse or flicker while you stay exhausted — the pool keeps
   replicating at zero, and none of those updates may redraw it.
5. Release Shift and let the pool refill. Confirm nothing is drawn as the
   lockout releases and the sprint comes back.
6. Run the pool dry a second time. Confirm the vignette plays again.
7. Repeat five or six times. Confirm it is identical every time and that Output
   stays clean.

**Against the other effects**

8. Take damage (`/damage 25`), and while the red is still fading, run the pool
   dry. Confirm the dark vignette replaces the red cleanly, with no flicker and
   no red left underneath.
9. Run the pool dry, and while the dark vignette is up, `/damage 25`. Confirm
   the red replaces it — being hit outranks being tired.
10. Repeat step 9 with `/heal` instead. Confirm the green replaces it.
11. Exhaust yourself, then `/damage 500` while the dark vignette is showing.
    Confirm the death effect takes over completely.
12. **The important one:** `/damage 500` to die, and while the death vignette is
    up, have the pool run dry (sprint into the death, or wait for a drain that
    lands after it). Confirm the death vignette does **not** turn grey. Death
    outranks exhaustion, always.
13. Respawn after step 12. Confirm the screen clears completely and that
    becoming exhausted on the new character draws the vignette normally.
14. Die and respawn five times, then run the pool dry **once**. Confirm you get
    one vignette, not several — the stamina subscription is made once for the
    session, so a duplicate here means it has been moved into a per-character
    path.
15. Confirm no sound plays with it. That is expected: no exhaustion asset has
    been uploaded, and `Config.ScreenEffectExhaustionSound` ships with an empty
    id. Once one is filled in, re-run steps 1–7 and confirm it fades with the
    vignette rather than outliving it.
