# cc-gitflow-regulator

## Layout

- `scripts/cc-gitflow-regulator.sh` — all logic. Subcommands `rename` / `notify` / `end`
- `scripts/finish-feature.sh` - wrap-up, handles killing session & removing cruft
- `scripts/start-feature.sh` - start-up counterpart: syncs base, creates `feature/<name>`, detects the test suite. Modes `plan` / `start`
- `hooks/hooks.json` — wires subcommands to `PostToolUse[EnterWorktree]`, `Stop` (async), `SessionEnd`.

## Considerations

- Gitflow: feature branches off `develop` (configurable)
- Hooks only target `.claude/worktrees/`; the user-invoked commands (`/start-feature`, `/finish-feature`) act on the user's own checkout
- Pushing to remote only on user's go ahead
- Destructive steps (reset, detach) gated on user interaction


