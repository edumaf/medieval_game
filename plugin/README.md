# Jest Studio plugin

Runs the real Jest suite from a toolbar button in Studio, in a context that
has the capability `debug.loadmodule` needs. See
[`docs/testing.md`](../docs/testing.md) for why this exists instead of
running Jest during Play mode.

`JestRunner.luau` is the only file. It is not synced by Rojo — it is never
part of `default.project.json` or `build.project.json` — it is a standalone
script you install directly into Roblox Studio's local Plugins folder.

## Install

```bash
lune run scripts/install-test-plugin
```

Re-run this after pulling a change to `JestRunner.luau`. Restart Studio (or
reopen it) afterwards to load the new version.

## Install by hand

If you cannot run Lune on this machine, or the installer aborts on a
platform it does not recognise:

1. Find your local Plugins folder:
   - **Windows**: `%LOCALAPPDATA%\Roblox\Plugins`
   - **macOS**: `~/Documents/Roblox/Plugins`
   (Create the folder if it does not exist.)
2. Copy `plugin/JestRunner.luau` into it.
3. Rename the copy's extension from `.luau` to `.lua` — Studio only
   auto-loads standalone plugin scripts with the `.lua` extension. Keep the
   name descriptive, e.g. `MedievalGameTests.lua`.
4. Restart Studio.

## Use

1. `rojo serve`, connect the plugin, so `ReplicatedStorage.DevPackages` and
   `ServerScriptService.Tests` are present.
2. **Plugins** tab → **Medieval Game Tests** → **Run Tests**.
3. Read the result in the Output window.

The button only runs when Studio is in Edit mode — it refuses to run while
you are in Play mode, since it tests the Edit-mode project, not the live
session, and running both at once would be confusing rather than useful.
