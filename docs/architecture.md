# Architecture

## The shape of it

```
ReplicatedStorage
  Shared/            src/shared      types, config, utilities, remote declarations
  Packages/          Packages/       Wally runtime dependencies
  DevPackages/       DevPackages/    Wally dev dependencies (development project only)
  Remotes/           created at runtime by Shared/Net

ServerScriptService
  Server             src/server/init.server.luau     the only self-starting server script
    Services/        src/server/Services             authoritative gameplay systems
  ServerPackages/    ServerPackages/                 server-only Wally dependencies
  Tests/             tests/                          Jest suite (development project only)

StarterPlayer/StarterPlayerScripts
  Client             src/client/init.client.luau     the only self-starting client script
    Controllers/     src/client/Controllers          presentation, input, UI logic
```

## The three layers

**Server (`src/server`)** owns truth. Currency, inventory, damage, progression,
rewards, purchases and anything a player could profit from lying about are
decided here and nowhere else. Services never trust a value that came from a
client.

**Client (`src/client`)** owns presentation. Input, UI, effects, camera, local
prediction. It may *ask* the server for things; it may never *tell* the server
what happened. Assume every client is running modified code.

**Shared (`src/shared`)** owns the vocabulary both sides need: types, tunable
config, pure utilities, and the remote declarations. Nothing secret goes here —
`ReplicatedStorage` is fully visible to every client. Drop rates, economy
formulas and anti-cheat thresholds belong in a server-only module.

## Lifecycle

Both entry points hand a folder of modules to `Shared/Runtime/Bootstrap`. Every
ModuleScript directly inside may export two optional functions:

| Hook | When | Rules |
| --- | --- | --- |
| `Init()` | First, for every module, in alphabetical order | Must not yield. Must not assume any other module has initialised. Register handlers, build local state. |
| `Start()` | After every `Init()`, each in its own thread | May yield. Anything that talks to another system goes here. |

That split is the whole reason `Bootstrap` exists: it removes load-order bugs
without a dependency-injection framework. If you find yourself needing another
module during `Init()`, you want `Start()`.

Subfolders are ignored by the lifecycle. Put helper modules a system owns in a
subfolder next to it and nothing will try to start them.

## Adding a system

A server system:

1. Create `src/server/Services/ThingService.luau`.
2. Return a table. Add `Init` and/or `Start` if it needs them.
3. Keep state in module-local variables. Never `_G`, never `shared` — Selene
   fails the build on both.
4. Release everything per-player in your `PlayerRemoving` path.

A client system is the same, in `src/client/Controllers/`.

Read `src/server/Services/SessionService.luau` first. It is deliberately small
and shows the whole pattern: local state, a validated remote handler, and
cleanup on leave.

## Networking

Every remote is declared in `src/shared/Net/Remotes.luau` and created by the
server at boot via `Net.build()`, before any service registers a handler. Both
sides fetch remotes through `Net.getEvent` / `Net.getFunction`, so a misspelled
name is a type error instead of a `nil` index at runtime.

To add one:

1. Add the name to the `RemoteName` union and to `Definitions` in `Remotes.luau`.
2. Register the server handler in a service's `Init()` — before any client can
   reach it.
3. **Validate every argument.** Check types, check ranges, check that the player
   is allowed to do this, check rate. `Net` resolves instances; it validates
   nothing.

Keep the list short. Each entry is a hole in the boundary that somebody has to
defend.

## Growing this

The layout is meant to absorb combat, inventory, quests, NPCs, progression and
currencies as sibling services and controllers, with their shared types in
`src/shared/Types.luau` and their remotes in `src/shared/Net/Remotes.luau`. When
a service outgrows one file, give it a folder with an `init.luau` and put its
private helpers beside it — the lifecycle only looks at direct children, so the
helpers stay out of the boot sequence.

Resist adding layers before there is duplication to remove.

## Performance rules that are cheap to follow

- Prefer events to polling. Reach for `RunService.Heartbeat` only when something
  genuinely has to change every frame, and disconnect it when it does not.
- Keep every `Connect` you make in a place you can disconnect it from. A
  connection that outlives its player is a leak.
- Do not send a remote per frame. Batch, or send state changes.
- Do the expensive thing once and cache it, rather than once per player per
  frame.

Do not micro-optimise beyond this. The goal is to avoid architecture that is
expensive to undo, not to tune code that does not exist yet.
