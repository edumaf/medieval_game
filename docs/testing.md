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
    Combat/
      ParryState.spec.luau
      PunchRules.spec.luau
  server/
    DeveloperAccess.spec.luau
    HealthService/
      HealthState.spec.luau
  client/
    RunningController/
      SprintState.spec.luau
    HealthBarController/
      HealthDisplay.spec.luau
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

**Movement interaction**

32. Hold Shift to sprint (24), then press Q while still sprinting. Confirm the
    speed drops to 8.
33. Release Q while still holding Shift. Confirm the speed goes straight back
    to **24**, not 16 — a parry must not strand a sprinting player at walking
    speed.
34. Hold Q, then press and release Shift underneath it. Confirm the speed stays
    at 8 throughout.
35. After several parry/sprint combinations, release everything and confirm the
    speed settles at exactly 16 with no modifier left behind.

36. Check Output for errors or warnings throughout. In particular, a
    `sent a malformed parry transition` warning during honest play means
    something is wrong with the controller, not with the player.
