# UI workflow

One designer, three developers, and a system that must not make them wait on
each other.

## The split

**Layout is authored in Studio.** ScreenGuis, Frames, TextLabels, colours,
fonts, corner radii, positions, `UIListLayout`s — all of it lives in
`StarterGui` in the place file, and the designer edits it visually. Rebuilding
that in code would be slower, uglier and would cut the designer out of their own
work.

**Behaviour is authored in Git.** Reading game state, responding to clicks,
tweening, showing and hiding — that is Luau in
`src/client/Controllers/`, named `<Screen>Controller.luau`.

They meet at a **name**, not a file. A controller finds its ScreenGui under
`PlayerGui` and drives it.

```lua
local Players = game:GetService("Players")

local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
local screen = playerGui:WaitForChild("MainMenu")
local playButton = screen:WaitForChild("PlayButton")
```

Because of that, **the instance names in a ScreenGui are an interface.**
Renaming `PlayButton` breaks the controller exactly like renaming a function
would. Designers: rename freely while a screen is still a sketch; once a
controller exists, treat it as a contract and mention renames in the PR.

## Who does what

| Task | Designer (Studio) | Developer (Git) |
| --- | --- | --- |
| New screen | Builds the ScreenGui in `StarterGui`, sets `Enabled = false` | — |
| Wiring it up | — | Writes `<Screen>Controller.luau` |
| Restyle, reposition, recolour | Yes | Not their call |
| Add a button that does something new | Adds the button, tells the developer its name | Handles the click |
| Data shown on screen | — | Fetches it, sets the text |
| Animation and transitions | — | Tweens it (or asks the designer for the target state) |

## Conventions

- One ScreenGui per screen, named for the screen: `MainMenu`, `Inventory`,
  `QuestLog`.
- One controller per ScreenGui: `MainMenuController.luau`.
- Ship screens with `Enabled = false` and let the controller turn them on. A
  screen that flashes on join is a screen nobody disabled.
- `ResetOnSpawn = false` unless the screen genuinely should reset on death.
- Put shared UI pieces the designer reuses in `StarterGui` as templates and
  clone them; do not build them in code.
- Do not put LocalScripts inside a ScreenGui. Rojo does not manage `StarterGui`,
  so any script you leave there is invisible to Git, to review and to CI.

## The screens that exist, and what their controllers expect

Both of these are contracts. Renaming anything in them breaks the controller
exactly like renaming a function would, and the controller says so by name in
Output rather than erroring.

**`HealthBar`** — driven by `HealthBarController`:

```
HealthBar (ScreenGui)     ResetOnSpawn = false, ships Enabled = false
  Bar (Frame)
    Track (Frame)
      Fill (Frame)        Size driven from health/maxHealth
    Amount (TextLabel)    Text driven, as "current/max"
```

**`StaminaBar`** — driven by `StaminaBarController`:

```
StaminaBar (ScreenGui)    ResetOnSpawn = false, ships Enabled = false
  Bar (Frame)
    Track (Frame)         ClipsDescendants = true
      Fill (Frame)        Size driven from current/max stamina
```

Deliberately no `Amount` label on the stamina bar: stamina reads as a bar, not
as a number. `Fill` is sized as `UDim2.fromScale(fraction, 1)`, so it has to be
anchored to the left edge of `Track` — `AnchorPoint` `(0, 0.5)` with `Position`
`(0, 0, 0.5, 0)` — and its `Size` must not be offset-based, since the controller
overwrites it. Style, colour, corner radius and where on screen it sits are all
yours; the four names and that one anchoring rule are all the code depends on.

The controller turns `StaminaBar.Enabled` on whenever stamina is below full and
off again when it returns to full, so the bar is invisible for a player who has
spent nothing. Ship it disabled, as with every other screen.

## When the designer needs a value from code

Ask for it rather than guessing. The controller sets it:

```lua
local coinLabel = screen:WaitForChild("CoinCount") :: TextLabel
coinLabel.Text = tostring(amount)
```

The designer styles `CoinCount`; the developer fills it. Neither has to open the
other's tool.

## Avoiding conflicts

`StarterGui` lives in the place file, which Git cannot merge — same constraint as
the map. Use Team Create so the designer and builders can work at the same time,
and publish from Studio to save. See `docs/studio-workflow.md`.
