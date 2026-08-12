# GitHub repository setup

Everything in this file must be done **by hand** by a repository administrator
in the GitHub web UI. None of it can be committed — the files in `.github/`
supply the templates and workflows, but branch protection, permissions and
merge settings are repository settings.

Work through it once, top to bottom.

---

## 1. Add the team

**Settings → Collaborators and teams**

| Person | Access |
| --- | --- |
| Developers (×3) | Write |
| UI designer | Write |
| Builder / environment artist | Write (or Read, if they only work in Team Create) |
| Repository owner | Admin |

Only Admins should be able to change branch protection.

## 2. Fill in CODEOWNERS

`.github/CODEOWNERS` ships with `@your-org/...` placeholders. Replace them with
real usernames (`@alice`) or team slugs. A code owner must have **write** access
or GitHub ignores the entry silently.

Commit that change like any other — it is the one part of this document that
lives in Git.

## 3. Protect `main`

**Settings → Branches → Add branch ruleset** (or *Add rule* on the classic UI),
targeting `main`:

- [x] **Require a pull request before merging**
  - Required approvals: **1**
  - [x] Dismiss stale approvals when new commits are pushed
  - [x] Require review from Code Owners
- [x] **Require status checks to pass before merging**
  - [x] Require branches to be up to date before merging
  - Required check: **`Lint, type-check and build`**
    (This name only appears in the list after CI has run once. Push any branch
    first, then come back.)
  - Add **`Jest (Open Cloud)`** only after you have configured it and seen it
    pass — see `docs/testing.md`.
- [x] **Require conversation resolution before merging**
- [x] **Block force pushes**
- [x] **Restrict deletions**
- [ ] Do **not** allow bypassing the above, including for administrators.

That combination gives you the property the team actually wants: nothing reaches
`main` without review and green CI, and `main`'s history cannot be rewritten.

## 4. Merge settings

**Settings → General → Pull Requests**

- [x] Allow squash merging — set the default commit message to
      **"Pull request title and description"**
- [ ] Allow merge commits — **off**
- [ ] Allow rebase merging — **off**
- [x] Automatically delete head branches

Squash-only keeps `main` at one commit per merged PR: readable history,
trivially revertable, and nobody has to care how messy their branch was.

## 5. Actions permissions

**Settings → Actions → General**

- Actions permissions: *Allow enterprise/owner actions, and select non-enterprise
  actions* — or *Allow all* if that is simpler. Our workflows use only
  `actions/checkout`, `actions/cache` and `actions/upload-artifact`.
- Workflow permissions: **Read repository contents permission** (read-only).
  Both workflows declare `permissions: contents: read` themselves; this makes
  read-only the floor.
- [ ] Allow GitHub Actions to create and approve pull requests — **off**

## 6. Secrets for the Roblox test workflow

Optional, and only when you are ready. **Settings → Secrets and variables →
Actions**:

| Name | Kind | Value |
| --- | --- | --- |
| `ROBLOX_OPEN_CLOUD_KEY` | Secret | Open Cloud API key |
| `ROBLOX_UNIVERSE_ID` | Variable | Universe ID |
| `ROBLOX_TEST_PLACE_ID` | Variable | A **test** place, never the live one |

Full instructions, including the exact API key scopes, are in `docs/testing.md`.

## 7. Housekeeping

- **Settings → General → Features**: enable Issues. Disable Wiki and Projects
  unless you will use them — an empty wiki is a place stale docs go to hide.
- Add labels the templates reference: `bug`, `feature`, `chore`, `dependencies`.
- Dependabot is configured in `.github/dependabot.yml` and will open monthly PRs
  for GitHub Actions. It does **not** understand `rokit.toml` or `wally.toml`;
  those are updated by hand (`docs/toolchain.md`, `docs/dependencies.md`).

## 8. Stale branch cleanup

"Automatically delete head branches" handles merged branches. For abandoned
ones, once a month:

```bash
git fetch --prune
git branch -vv | grep ': gone]' | awk '{print $1}' | xargs -r git branch -d
```

That deletes only local branches whose remote is gone, and only if they are
merged (`-d`, not `-D`). To see stale remote branches:

```bash
git for-each-ref --sort=committerdate --format='%(committerdate:short) %(refname:short)' refs/remotes/origin
```

Ask the author before deleting anything on the remote.
