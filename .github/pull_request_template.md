<!--
Keep this short. A reviewer should understand the change without opening Studio.
Delete any section that genuinely does not apply.
-->

## What changed

<!-- One or two sentences. What does this PR do? -->

## Why

<!-- The problem, the bug, or the task this solves. Link the issue: Closes #123 -->

## How it was tested

<!--
Be specific. "Tested in Studio" is not enough.
Example: "Played solo in Studio, joined with 2 players via Test > Clients and
Servers, confirmed the handshake logs the right build on both."
-->

- [ ] `stylua --check src tests scripts` passes
- [ ] `selene src tests scripts` passes
- [ ] `luau-lsp analyze` passes (see README "Running validation")
- [ ] Jest suite passes in Studio (press Play, check Output)
- [ ] Play-tested in Roblox Studio

## Studio / map changes

<!--
Rojo does NOT sync Workspace, terrain or StarterGui. If this PR depends on
something a builder or the UI designer changed in Studio, say so here, name who
made it, and say whether it has been published. A reviewer who pulls this branch
and sees nothing will assume the code is broken.
-->

- [ ] No Studio-side changes are needed to review this
- [ ] Studio-side changes are needed — described above

## Dependencies

- [ ] No dependency changes
- [ ] `wally.toml` changed and `wally.lock` is committed alongside it
- [ ] `rokit.toml` changed — everyone must re-run `rokit install` after merging

## Breaking changes

<!--
Anything that will break a teammate's branch or an existing save: a changed
remote payload, a renamed module, a moved instance path, a DataStore schema
change. Write "None" if there are none.
-->

## Notes for the reviewer

<!-- Where to look first, what you are unsure about, anything you want pushed back on. -->
