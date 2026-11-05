<p align="center">
  <img src="assets/logo.png" width="240" alt="A brass regulator valve wrapped in a sunburst, sitting at the junction where a dotted side branch rejoins the straight main line of a git pipe-tree carrying water drops">
</p>

# cc-gitflow-regulator

v0.3.0

Gitflow guardrails for Claude Code — every worktree flows back through the regulator.

Claude Code isolates background and parallel work in git worktrees on internal
`worktree-*` branches. Those branches don't follow gitflow naming, stay checked
out inside the worktree (so Sourcetree/GitKraken/git can't check them out —
`fatal: '<branch>' is already used by worktree at ...`), and nothing tells you
when the work is done. This plugin fixes all three:



- **Gitflow naming** — the moment a worktree is created, its branch is renamed
  to `feature/<name>`.
- **Fork from develop** — fresh worktrees are re-pointed to your gitflow base
  branch (`develop` by default), never whatever you happened to have checked out.
- **Completion alerts** — when new committed work exists, you get a desktop
  notification (Windows toast / macOS Notification Center / Linux
  `notify-send`) and, optionally, an [IFTTT](https://ifttt.com) webhook you can
  build any automation on.
- **Local delivery** — at session end the worktree's HEAD is detached, which
  releases the `feature/*` branch so your git client can check it out or merge
  it immediately. The hooks never push anything; only the commands you run
  talk to origin, as described below.
- **Start command** — `/start-feature <name>` performs the Sourcetree-style
  "Start Feature": fast-forward develop from origin, branch `feature/<name>`
  off it, and run the project's test suite as a baseline before you change
  anything. Bootstraps `develop` from main/master if the repo doesn't have one
  yet (with your go-ahead).
- **Finish command** — `/finish-feature` performs the Sourcetree-style
  "Finish Feature" for you: `--no-ff` merge into the branch's base (PR route
  on conflicts), push the base to origin, remove the worktree and delete the
  local branch, then ask before deleting the branch on origin.

## Requirements

- git ≥ 2.31
- bash (on Windows: Git Bash, which ships with Git for Windows)
- `jq` optional (a sed fallback is built in)
- a recent Claude Code — the rename hook matches the `EnterWorktree` tool and
  the notify hook uses `async` Stop hooks. Older versions degrade gracefully:
  no rename, and alerts run synchronously.

## Installation

```install
/plugin marketplace add jagp/cc-gitflow-regulator
/plugin install cc-gitflow-regulator@cc-gitflow-regulator
```

## How it works

| Hook   | Event                            | What it does                                                                                                                                                                                                                |
| ------ | -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| rename | `PostToolUse` on `EnterWorktree` | Renames `worktree-<name>` → `feature/<name>`. If the branch is _fresh_ (a single `branch: Created from ...` reflog entry), hard-resets it onto the base branch first. Worktrees that already carry commits are never reset. |
| notify | `Stop` (async)                   | If the worktree is clean and HEAD moved since the last alert, sends the desktop notification + IFTTT webhook. Deduped by commit SHA — one alert per batch of new work, not per turn.                                        |
| end    | `SessionEnd`                     | Sends any pending alert, then detaches the worktree HEAD (releases the branch) so it is free in your main checkout.                                                                                                         |

Everything is scoped to directories under `.claude/worktrees/` — the hooks
never touch your own branches or checkouts. The script always exits 0; a
guardrail must never break a session.

## Configuration

All optional, via environment variables (e.g. the `"env"` block in
`~/.claude/settings.json`):

| Variable                        | Default                   | Purpose                                                                                                                                          |
| ------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `CC_GITFLOW_REGULATOR_PREFIX`         | `feature/`                | Branch prefix for renamed worktree branches                                                                                                      |
| `CC_GITFLOW_REGULATOR_BASE`           | auto                      | Base branch to fork from. Auto-detect order: `develop`, `dev`, `origin/develop`, `origin/dev`. If none exist, worktrees keep their default base. |
| `CC_GITFLOW_REGULATOR_PUSH_MERGED`    | on                        | `/finish-feature` pushes the base branch to origin after merging. Set `0` (or `false`/`off`/`no`) to keep merges local.                          |
| `CC_GITFLOW_REGULATOR_IFTTT_EVENT`    | `claude_work_done`        | IFTTT Maker Webhooks event name                                                                                                                  |
| `CC_GITFLOW_REGULATOR_IFTTT_KEY_FILE` | `~/.claude/ifttt-key.txt` | Where your IFTTT Maker key lives                                                                                                                 |

### IFTTT setup (optional)

1. Get your key at [ifttt.com/maker_webhooks](https://ifttt.com/maker_webhooks) → Documentation.
2. Paste it into `~/.claude/ifttt-key.txt`.
3. Create an applet triggered by Webhooks event `claude_work_done`.
   Ingredients: `value1` = repo name, `value2` = branch, `value3` = detail text.

No key file → the webhook is silently skipped.

Keep the key file private (`chmod 600 ~/.claude/ifttt-key.txt` on macOS/Linux).
When a key is present, each alert sends the repo name, branch name, and alert
text to IFTTT — nothing else, and nothing at all without a key file.

## Starting a branch: `/start-feature`

```
/start-feature <feature name> [--create-base] [--skip-tests]
```

`/new-feature` is an alias.

All git logic lives in `scripts/start-feature.sh` (`plan` is read-only, `start`
acts). In order, it:

1. Slugs the name into `feature/<name>`. The slug rules are the same as
   `/feature-dirty`.
2. Refuses if the branch already exists, locally or on origin.
3. Refuses if tracked files have uncommitted changes. Use `/feature-dirty`
   to carry dirty work onto a new branch instead.
4. Resolves the base branch: `CC_GITFLOW_REGULATOR_BASE`, else
   `develop`/`dev`. A base that exists only on origin is checked out locally.
   If there is no base at all, `--create-base` creates `develop` from
   main/master.
5. Fetches origin and fast-forwards the base only if it is strictly behind.
   A base that is ahead or has diverged is reported and never forced.
6. Creates the branch from the base, switches the current checkout to it,
   and records the base in git config (`gitflow.branch.<branch>.base`, the
   key git-flow uses) so `/finish-feature` merges back into it.
7. Detects the test suite and runs it once as a baseline, so failures that
   were already there aren't mistaken for new ones. Detected runners:
   package.json `test` script (npm/pnpm/yarn/bun), pytest, cargo, go,
   `make test`, and bats.

Nothing is pushed.

## Reviewing and merging Claude's work

When you get the alert, the `feature/<name>` branch is (or will be at session
end) checked out nowhere — open your git client, review it, and merge it into
`develop` like any other feature branch. Delete it after merging as usual.

Or let the plugin do it:

## Finishing a branch: `/finish-feature`

```
/finish-feature [branch] [--keep-branch] [--stash-changes|--discard-changes] [--kill-stalled-session]
```

`/finish-branch` is an alias.

Mimics Sourcetree's Gitflow **Finish Feature** button, deterministically
(all logic lives in `scripts/finish-feature.sh`; the command is a thin
wrapper). It first shows you a read-only *plan* (branch, base, holding
worktree, background job, remote-branch state, whether the merge will be
clean, and what cleanup will do), then:

1. **Checks for leftovers** — if the branch's worktree has uncommitted or
   untracked files (anything in `.claude/` is ignored), it stops *before*
   merging and lists them. Claude asks what they are: commit them to the
   branch and re-run, carry them forward with `--stash-changes` (the stash
   survives the worktree; continue with `/start-feature <name>` then
   `git stash apply <sha>`), or throw them away with `--discard-changes`.
2. **Releases the lock** — unlocks and detaches the `.claude/worktrees/*`
   worktree holding the branch (worktrees you created yourself are never
   touched). Worktrees already on a detached HEAD, the normal state after a
   session ends, are found by their managed-worktree name.
3. **Merges** the branch with `--no-ff` into its base: the one
   `/start-feature` recorded, else `CC_GITFLOW_REGULATOR_BASE`, else
   `develop`/`dev`.
4. **Pushes the base to origin** (plain push, never forced). With no origin
   it says so; `CC_GITFLOW_REGULATOR_PUSH_MERGED=0` keeps the merge local.
   A rejected push is reported and the run ends incomplete.
5. **On conflict**, nothing is merged or pushed to the base. Instead it pushes
   the feature branch and opens a PR into the base. Once the PR is merged,
   run `/finish-feature <branch>` again: it sees the branch is already in the
   base and does the remaining cleanup.
6. **Cleans up** — removes the worktree and deletes the local branch, unless
   `--keep-branch`. The branch is deleted only once a long-lived branch
   (`develop`, `dev`, `main`, `master`, or `CC_GITFLOW_REGULATOR_BASE`) holds
   its work; a feature merged into a `release/*` or `hotfix/*` base is kept
   until that base lands, then a re-run deletes it. If the worktree can't be
   removed, the branch is kept too, so a re-run can find it.
7. **Asks about origin** — after `git fetch --prune`, if the local branch was
   deleted and `origin/<branch>` holds nothing beyond it, Claude asks whether
   to delete it on origin too. On yes, it is deleted only if origin still
   points at the commit that was checked (`--force-with-lease`), so a push
   someone made in the meantime is never lost. A branch with someone else's
   commits on it is left alone.

**When a background session holds the worktree.** On Windows a folder can't
be deleted while any process is running inside it. If removal fails and a
Claude background job's record matches the worktree, finish looks at the
job's state: a `done` or `failed` job is stopped (with its child processes)
and removal is retried; a `blocked` job may be waiting on you, so Claude asks
first and re-runs with `--kill-stalled-session` on yes; a job in any other
state is never stopped. Ordinary terminal sessions have no job record, so
finish names the problem and leaves closing them to you.

A branch that exists only on origin (a background session pushed it without
ever creating a local branch) is adopted local-first: finish creates the
local branch from `origin/<branch>` before merging.

**What reaches origin, exactly:** the base branch after a clean merge (unless
switched off), the feature branch on a conflict (for its PR), and a delete of
`origin/<branch>` only after you say yes. Never a force push.

Guardrails: it refuses to run if your main checkout has uncommitted tracked
changes or a merge in progress, or if the branch is held by a worktree the
plugin doesn't manage. It never stops the session it is running in, or any
job when several match the worktree, and it refuses to remove a detached
worktree whose HEAD holds commits not yet in the base or the branch.

## Tests

```
bash tests/hooks.sh
bash tests/start-feature.sh
bash tests/finish-feature.sh
bash tests/stalled-jobs.sh    # Windows only; skips elsewhere
```

Each builds a throwaway origin and clone in a temp folder, prints one
PASS/FAIL line per case, and exits 1 if any case fails.

## License

MIT — see [LICENSE](LICENSE).
