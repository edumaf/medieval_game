# Toolchain updates

Every tool is pinned in `rokit.toml`. Nothing floats on `latest`, so two
developers cannot silently run different compilers, and CI runs exactly what you
run.

## Current toolchain

| Tool | Version | Why it is here |
| --- | --- | --- |
| Rokit | 1.2.0 | Installs and pins everything below. Pinned in the CI workflows, not in `rokit.toml`. |
| Rojo | 7.7.0 | Filesystem → Studio sync, sourcemaps, place builds |
| Wally | 0.3.2 | Package manager |
| wally-package-types | 1.6.2 | Restores Luau types Wally strips from package links |
| Selene | 0.31.0 | Linter with Roblox API awareness |
| StyLua | 2.5.2 | Formatter |
| luau-lsp | 1.69.0 | Editor intelligence, and the `analyze` type-check gate |
| Lune | 0.10.5 | Runs the Luau scripts in `scripts/` |

## Updating

Do this on its own branch. Never fold a toolchain bump into a feature PR.

```bash
git checkout main && git pull
git checkout -b chore/toolchain-update
```

1. **Find the current versions.** Check each project's GitHub releases page.
   Prefer the latest stable release; skip release candidates unless you need a
   specific fix.
2. **Edit `rokit.toml`.** One tool at a time is easier to bisect than all eight.
3. **Install:**
   ```bash
   rokit install
   ```
4. **Refresh the API definitions** if you moved luau-lsp — they are pinned to
   its version:
   ```bash
   lune run scripts/fetch-global-types
   ```
5. **Run everything:**
   ```bash
   wally install
   rojo sourcemap default.project.json --output sourcemap.json
   wally-package-types --sourcemap sourcemap.json DevPackages/
   stylua --check src tests scripts
   selene src tests scripts
   luau-lsp analyze --platform=roblox --sourcemap=sourcemap.json \
     --definitions=.tooling/globalTypes.d.luau --base-luaurc=.luaurc \
     --ignore="**/Packages/**" --ignore="**/DevPackages/**" src tests
   lune run scripts/validate-project
   rojo build default.project.json --output build/dev.rbxl
   rojo build build.project.json --output build/medieval-game.rbxl
   ```
   A StyLua bump will usually reformat files. Commit that reformat **as its own
   commit** so the version bump stays reviewable.
6. **Test the Studio path by hand.** `rojo serve`, connect, press Play, confirm
   the boot logs appear and the Jest suite still runs. CI cannot check this.
7. **Update this table** and the version in `docs/decisions.md` if the reasoning
   changed.
8. Open a PR titled `chore: update toolchain` listing old → new for each tool.

## Updating Rokit itself

Rokit is not in `rokit.toml`. It is pinned as `ROKIT_VERSION` in both workflow
files, and installed by hand on each machine.

```bash
rokit self-update
rokit --version
```

Then set `ROKIT_VERSION` in `.github/workflows/ci.yml` and
`.github/workflows/roblox-tests.yml` to match, and tell the team to run
`rokit self-update`.

## Why not let it float

A floating toolchain means "works on my machine" becomes unfalsifiable: a
formatter minor bump reformats half the repository in somebody's unrelated PR, a
linter release adds a rule and red-lines `main`, a Rojo change alters the
generated tree. Pinning turns all of those into a deliberate, reviewable commit.
