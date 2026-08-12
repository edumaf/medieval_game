# Assets

Git is good at some Roblox assets and bad at others. This folder is only for the
ones it is good at.

## What belongs in Git

| Folder | Put here | Why it works |
| --- | --- | --- |
| `models/` | `.rbxm` / `.rbxmx` exports of **self-contained, reusable** models | One file per thing, reviewable as "added/changed", insertable by anyone |
| `animations/` | Animation **IDs and metadata** (`.json`, `.luau`) | The animation itself lives on Roblox; only the ID is ours |
| `sounds/` | Sound **IDs and metadata** | Same |
| `images/` | Source art (`.png`, `.psd`) and the Roblox asset IDs it was uploaded as | Keeps the editable original next to the ID it became |

Keep binary files small and few. Git stores every version of every binary
forever — a 40 MB model committed ten times is 400 MB in everyone's clone,
permanently.

## What does not belong in Git

- **Place files** (`.rbxl`, `.rbxlx`). Binary, unmergeable, and huge. Gitignored.
  The map lives in the place; see `docs/studio-workflow.md`.
- **The map itself.** Terrain, world geometry, the composed scene. Studio owns it.
- **Uploaded audio, images and meshes.** Roblox hosts them. Store the ID.
- **Anything above ~10 MB.** Ask before committing it.

## Exporting a model

1. In Studio, select the Model. Give it a real name and a `PrimaryPart`.
2. Right-click → **Save to File**.
3. Save into `assets/models/` as `.rbxm`.
4. Commit it. Say in your PR what it is and where it is meant to be used.

To use one, drag it into Studio (**right-click a folder → Insert from File**).
These are library pieces, not part of the synced tree — Rojo does not mount
`assets/`, so nothing here appears in the game automatically.

## Referencing asset IDs from code

Do not scatter `rbxassetid://...` through the codebase. Collect them in a module
under `src/shared/` so there is one place to look when an upload is replaced:

```lua
--!strict
return table.freeze({
	Sounds = table.freeze({
		SwordHit = "rbxassetid://1234567890",
	}),
})
```
