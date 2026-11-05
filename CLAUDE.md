# cc-gitflow-regulator

## Layout

- `scripts/cc-gitflow-regulator.sh` — all logic. Subcommands `rename` / `notify` / `end`
- `scripts/finish-feature.sh` - wrap-up: merge into the recorded base, push it, remove worktree + local branch, offer the origin delete. Modes `plan` / `finish` / `delete-remote`
- `scripts/start-feature.sh` - start-up counterpart: syncs base, creates `feature/<name>`, records its base, detects the test suite. Modes `plan` / `start`
- `tests/*.sh` — behaviour tests for the two command scripts (`tests/lib.sh` builds a throwaway origin + clone); run them after any script change
- `hooks/hooks.json` — wires subcommands to `PostToolUse[EnterWorktree]`, `Stop` (async), `SessionEnd`.

## Considerations

- Gitflow: feature branches off `develop` (configurable)
- Hooks only target `.claude/worktrees/`; the user-invoked commands (`/start-feature`, `/finish-feature`) act on the user's own checkout
- Hooks never push. `/finish-feature` pushes the merged base (opt-out: `CC_GITFLOW_REGULATOR_PUSH_MERGED=0`) and, on conflict, the feature branch for its PR; never a force push
- Default-on: deleting a local branch once a long-lived branch holds it, and stopping a `done`/`failed` background job that holds its worktree
- Gated on the user's explicit yes: deleting a branch on origin, discarding worktree leftovers, stopping a `blocked` job


