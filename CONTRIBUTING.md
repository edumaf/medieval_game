# Contributing

Setup, workflow and troubleshooting all live in [README.md](README.md). This
page is the short version for people who already have the repository running.

## Before you start

```bash
git checkout main && git pull origin main
rokit install && wally install     # only if rokit.toml or wally.toml changed
git checkout -b feature/your-thing
```

Branch prefixes: `feature/`, `fix/`, `refactor/`, `chore/`.

## Before you push

```bash
stylua src tests scripts plugin
selene src tests scripts plugin
rojo sourcemap default.project.json --output sourcemap.json
luau-lsp analyze --platform=roblox --sourcemap=sourcemap.json \
  --definitions=.tooling/globalTypes.d.luau --base-luaurc=.luaurc \
  --ignore="**/Packages/**" --ignore="**/DevPackages/**" src tests plugin
lune run scripts/validate-project
rojo build build.project.json --output build/medieval-game.rbxl
```

Then run the unit tests from the Studio plugin (**Plugins** → **Medieval Game
Tests** → **Run Tests** — not by pressing Play, see
[`docs/testing.md`](docs/testing.md)) and play-test your change separately.
CI cannot do either of those for you.

## Pull requests

Fill in every section of the template. Keep the PR small enough to review
properly. One approval plus green CI, then **squash and merge**.

## The rules that matter most

- `main` is protected. Everything goes through a PR.
- The server is authoritative; validate everything the client sends.
- Nothing secret in `src/shared` — clients can read all of it.
- Rojo owns code, Studio owns the world. Do not edit across the line.
- Never commit secrets, place files, or generated folders.
- Commit `wally.toml` and `wally.lock` together.

Full list: [README.md → Development rules](README.md#development-rules).

## Where to read next

| Topic | File |
| --- | --- |
| How the code is organised | [`docs/architecture.md`](docs/architecture.md) |
| Git vs Studio ownership, map conventions | [`docs/studio-workflow.md`](docs/studio-workflow.md) |
| UI handoff between designer and developers | [`docs/ui-workflow.md`](docs/ui-workflow.md) |
| Writing and running tests | [`docs/testing.md`](docs/testing.md) |
| Adding and updating packages | [`docs/dependencies.md`](docs/dependencies.md) |
| Updating the toolchain | [`docs/toolchain.md`](docs/toolchain.md) |
| Repository settings an admin must configure | [`docs/github-setup.md`](docs/github-setup.md) |
| Why this stack and not another | [`docs/decisions.md`](docs/decisions.md) |
| Working with Claude Code | [`CLAUDE.md`](CLAUDE.md) |
