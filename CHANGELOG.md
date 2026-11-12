# Changelog

## 1.0.0 — unreleased

First release intended for distribution.

### Added

- `/start-feature <name>` (alias `/new-feature`): syncs `develop` from origin,
  creates `feature/<name>` off it, records that base in git config
  (`gitflow.branch.<branch>.base`), and runs the test suite as a baseline.
  `--create-base` bootstraps `develop` from main/master.
- `/finish-feature` pushes the merged base to origin after a clean merge.
  `CC_GITFLOW_REGULATOR_PUSH_MERGED=0` keeps merges local.
- `/finish-feature` offers to delete the branch on origin (`ask: delete-remote`)
  once the local branch is gone and origin holds nothing beyond it. The delete
  only goes through if origin hasn't moved (`--force-with-lease`).
- Worktree leftovers are checked before merging: finish refuses and lists them,
  or takes `--stash-changes` (the stash outlives the worktree) or
  `--discard-changes`.
- A background job holding the worktree is handled during cleanup: `done` and
  `failed` jobs are stopped, a `blocked` job is stopped only after the user
  agrees (`--kill-stalled-session`), any other job is left alone, and the
  session running finish is never stopped.
- `/start-release` (alias `/new-release`) and `/finish-release`: cut
  `release/<version>` from `develop` with the version suggested from the
  Conventional Commits since the last tag, bump the manifests, draft the
  changelog entry; then land it on `main` with a tag, merge it back, push,
  clean up, and (after a yes) push the tag and create the GitHub Release page.
- `/start-hotfix` (alias `/new-hotfix`) and `/finish-hotfix`: the same for a
  fix to what is released, branched from `main` and merged back into an open
  release branch when there is one.
- Settings `CC_GITFLOW_REGULATOR_CHANGELOG` and
  `CC_GITFLOW_REGULATOR_GH_RELEASE`, plus per-repo git config switches.
- Test detection finds plain `*.sh` suites in `tests/`, and
  `git config gitflow.testCommand` overrides it.
- Behaviour tests in `tests/` for the hook script and every command.

### Changed

- `/finish-branch` is renamed `/finish-feature`; `/finish-branch` stays as an
  alias.
- Finish merges into the base recorded by `/start-feature`, falling back to
  `CC_GITFLOW_REGULATOR_BASE`, then `develop`/`dev`.
- Finish now removes the worktree and deletes the local branch by default, once
  `develop`, `dev`, `main` or `master` holds its work. A feature merged into a
  release or hotfix base is kept until that base lands. `--keep-branch` keeps
  both.
- If the worktree can't be removed, the branch is kept too, so a re-run can
  finish the cleanup; leftover folders git already dropped are found and
  removed on that re-run.

### Removed

- `--delete-branch`: deletion is now the default (use `--keep-branch` to opt
  out). Passing it is an error.
- `--kill-session`: replaced by the automatic handling of stalled background
  jobs above.
