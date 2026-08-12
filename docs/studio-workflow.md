# Git vs Roblox Studio: who owns what

This is the single most important convention in the repository. Get it wrong and
you will either lose a builder's day of work or spend an afternoon wondering why
your script keeps reverting.

## The rule

> **Rojo owns code. Studio owns the world.**

Rojo syncs **one direction only**: filesystem → Studio. Anything Rojo manages is
overwritten from disk every time it syncs. Anything Rojo does not manage lives in
the place file and is saved by publishing from Studio.

## Ownership table

| Thing | Lives in | Edited with | Never edit in |
| --- | --- | --- | --- |
| Luau source, modules, services, controllers | Git (`src/`) | Your editor | Studio — edits are wiped on next sync |
| Shared types, config, remote declarations | Git (`src/shared`) | Your editor | Studio |
| Tests | Git (`tests/`) | Your editor | Studio |
| Tooling, CI, project files | Git | Your editor | Studio |
| Map geometry, terrain, props | The place file | Studio | Git |
| Lighting, atmosphere, sky | The place file | Studio | Git |
| Spawn locations, zone markers | The place file | Studio | Git |
| UI layout (ScreenGuis, Frames, colours) | The place file (`StarterGui`) | Studio | Git |
| UI logic | Git (`src/client/Controllers`) | Your editor | Studio |
| Reusable models exported as `.rbxm` | Git (`assets/models`) | Studio, then export | — |

**While Rojo is connected, everything under `ReplicatedStorage.Shared`,
`ServerScriptService.Server`, `ServerScriptService.Tests` and
`StarterPlayerScripts.Client` is Rojo's.** Do not type in those instances in
Studio. Everything else in the place — `Workspace`, `Lighting`, `StarterGui`,
`SoundService` — is yours to build in.

## Studio hierarchy conventions

Builders: keep `Workspace` organised like this so scripts can find things by a
stable path and so two people can work without colliding.

```
Workspace
  Map/              everything static and non-interactive
    Terrain         (the Terrain object)
    Structures/     castles, walls, buildings
    Props/          barrels, crates, decoration
    Nature/         trees, rocks, foliage
  Gameplay/         things code looks up by name
    Spawns/         SpawnLocation instances
    Zones/          invisible parts marking regions
    Interactables/  doors, chests, anything a player uses
  Effects/          runtime-created visuals (leave empty on disk)
```

Rules:

- **Never rename anything under `Gameplay/` without saying so in your PR.** Code
  finds those by name; a rename is a breaking change.
- Anchor everything static. Unanchored map geometry is a physics bill you pay
  forever.
- Name things descriptively. `Part`, `Part1`, `Model` are not names.
- Group a structure into a `Model` with a `PrimaryPart` before you move it.
- Do not put scripts in `Workspace`. If something needs behaviour, a service in
  `src/server` should find it and drive it.

## How map work gets shared

Roblox place files are binary. Git cannot merge them, so **two people editing
the same place at once will lose work.**

Use one of these, and say which in your PR:

- **Team Create** (recommended for the builder and the UI designer). Roblox
  handles concurrent editing. The place is the source of truth for world
  content; nobody needs to touch Git for it.
- **Exported models.** For a self-contained piece — a castle, a props pack —
  right-click the Model → *Save to File*, write it to `assets/models/`, and
  commit it. It is reviewable as "a new file appeared", and anyone can insert it.
  See `assets/README.md`.

Do not commit whole `.rbxl` place files. `.gitignore` already blocks them.

## The order of operations that avoids pain

1. Pull `main` and run `rokit install` / `wally install` if either manifest
   changed.
2. Start `rojo serve`.
3. Open the place in Studio and connect the Rojo plugin.
4. Build in `Workspace` / `StarterGui`; write code in your editor.
5. Publish from Studio to save world changes. Commit and push to save code.

Those last two are separate acts. Publishing does not save your code. Committing
does not save the map.
