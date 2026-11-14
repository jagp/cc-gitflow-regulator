# cc-gitflow-regulator

## Layout

- `scripts/cc-gitflow-regulator.sh` — all logic. Subcommands `rename` / `notify` / `end`
- `scripts/finish-feature.sh` - wrap-up: merge into the recorded base, push it, remove worktree + local branch, offer the origin delete. Modes `plan` / `finish` / `delete-remote`
- `scripts/start-feature.sh` - start-up counterpart: syncs base, creates `feature/<name>`, records its base, detects the test suite. Modes `plan` / `start`
- `scripts/start-release.sh` / `scripts/finish-release.sh` - releases and hotfixes (type as first argument). Modes `plan` / `start`; `plan` / `finish` / `sync-main` / `publish`
- `scripts/common.sh` (roots, switches, branch lookups, test detection) and `scripts/release-lib.sh` (versions, manifests, changelog) - sourced libraries; `scripts/run-tests.sh` runs the detected tests
- `scripts/prune-merged.sh` - session-start cleanup: delete local branches whose work origin's long-lived branches hold. Modes `plan` / `run` / `session` (the hook)
- `tests/*.sh` — behaviour tests for the command scripts (`tests/lib.sh` builds a throwaway origin + clone); run them after any script change
- `hooks/hooks.json` — wires subcommands to `PostToolUse[EnterWorktree]`, `Stop` (async), `SessionEnd`, and `prune-merged.sh session` to `SessionStart` (startup, resume).

## Considerations

- Gitflow: feature branches off `develop` (configurable)
- Hooks only target `.claude/worktrees/`, except the session-start prune, which deletes local branches whose tip an origin long-lived branch contains and sits on no long-lived first-parent line (never one checked out anywhere, never a worktree); the user-invoked commands (`/start-*`, `/finish-*` for features, releases, hotfixes) act on the user's own checkout
- Hooks never push. Every merge stage has a mode, `pr` | `push` | `local` (`common.sh` `merge_mode`): feature → base `CC_GITFLOW_REGULATOR_FEATURE_MERGE` / `gitflow.feature.merge` (default `push`), release/hotfix → main `CC_GITFLOW_REGULATOR_RELEASE_MERGE` / `gitflow.release.merge` (default `pr`, the highest-stakes merge), merge back `CC_GITFLOW_REGULATOR_BACK_MERGE` / `gitflow.release.backMerge` (default `push`, PR from main). A `pr` stage refuses rather than falling back to a local merge; `/finish-feature` also pushes the feature branch for a PR on conflict; never a force push
- Default-on: deleting a local branch once a long-lived branch holds it, stopping a `done`/`failed` background job that holds its worktree, the changelog entry, the GitHub Release page
- Gated on the user's explicit yes: deleting a branch on origin, discarding worktree leftovers, stopping a `blocked` job, pushing a release tag (and publishing)


