# Changelog

## 1.0.1 — unreleased

### Added

- `git config gitflow.branch.develop <name>` names the integration branch, as in
  git-flow. `/start-feature`, `/finish-feature`, the release commands and the
  worktree rename hook all honour it, so a repo with no `develop` can set it to
  `main`.
- A failing test suite now prints its last 15 lines, prefixed with the suite's
  name, so a CI log shows why it failed.

### Changed

- Install from the InterfaceLayer marketplace:
  `/plugin marketplace add jagp/interface-layer`, then
  `/plugin install cc-gitflow-regulator@interface-layer`. This repo no longer
  carries its own `.claude-plugin/marketplace.json`.

### Fixed

- `/finish-feature` deletes a feature branch once its work is in the branch
  `gitflow.branch.develop` or `gitflow.branch.master` names. Before, it treated
  such a base as a temporary release branch and kept the feature forever.

## 1.0.0 — 2026-11-12

First release intended for distribution.

### Added

- `/start-feature <name>` (alias `/new-feature`): syncs `develop` from origin,
  creates `feature/<name>` off it, records that base in git config
  (`gitflow.branch.<branch>.base`), and runs the test suite as a baseline.
  `--create-base` bootstraps `develop` from main/master.
- Every merge stage has a mode, `pr`, `push` or `local`, set by environment
  variable or per repo in git config: feature into its base
  (`CC_GITFLOW_REGULATOR_FEATURE_MERGE` / `gitflow.feature.merge`, default
  `push`), release or hotfix into `main` (`CC_GITFLOW_REGULATOR_RELEASE_MERGE`
  / `gitflow.release.merge`, default `pr`), and the merge back
  (`CC_GITFLOW_REGULATOR_BACK_MERGE` / `gitflow.release.backMerge`, default
  `push`). `pr` pushes the branch, opens a GitHub PR and stops until it is
  merged with a merge commit; it refuses rather than ever merging locally.
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
  changelog entry; then land it on `main` (through a PR by default) with a
  tag, merge it back, push, clean up, and (after a yes) push the tag and
  create the GitHub Release page.
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
