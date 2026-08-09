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
  it immediately. Your repo is the remote: **nothing is ever pushed without
  you.**
- **Finish command** — `/finish-branch` performs the Sourcetree-style
  "Finish Feature" for you: release the worktree lock, `--no-ff` merge into
  develop (PR route on conflicts), and — only with your explicit go-ahead —
  kill the branch's Claude session and delete the branch.

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

> If you previously wired similar hooks directly into `~/.claude/settings.json`,
> remove them when installing this plugin — otherwise both will fire.

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

## Reviewing and merging Claude's work

When you get the alert, the `feature/<name>` branch is (or will be at session
end) checked out nowhere — open your git client, review it, and merge it into
`develop` like any other feature branch. Delete it after merging as usual.

Or let the plugin do it:

## Finishing a branch: `/finish-branch`

```
/finish-branch [branch] [--kill-session] [--delete-branch]
```

Mimics Sourcetree's Gitflow **Finish Feature** button, deterministically
(all logic lives in `scripts/finish-branch.sh`; the command is a thin
wrapper). It first shows you a read-only *plan* — resolved branch, base,
holding worktree, attached Claude session, remote-branch state, and whether
the merge will be clean — then:

1. **Releases the lock** — unlocks and detaches the `.claude/worktrees/*`
   worktree holding the branch (worktrees you created yourself are never
   touched). Worktrees already sitting on a detached HEAD — the normal state
   after a session ends, since releasing the branch *is* the delivery — are
   found by their managed-worktree name instead, so the attached session and
   folder still get cleaned up.
2. **Merges** the branch into the base (`develop`/`dev`, or
   `CC_GITFLOW_REGULATOR_BASE`) with `--no-ff`, gitflow-style.
3. **On conflict**, switches to the PR route: pushes the branch and opens a
   PR into the base — the only case where anything leaves your machine, and
   it never happens without you having invoked the command. The PR body
   reminds you of the next step: once the PR is merged, run
   `/finish-branch <branch>` again and it resumes — detects the branch is
   now contained in the base and performs the remaining cleanup only.
4. **Optionally** kills the Claude session attached to the worktree and
   deletes its background job (`--kill-session`), and/or removes the worktree
   and deletes the branch with `git branch -d`, never `-D`
   (`--delete-branch`).
5. **Syncs remote-tracking refs** — `git fetch --prune`, then *reports*
   whether `origin/<branch>` still exists. Remote branches are never deleted:
   in a shared repo that's your call, so the script prints the command and
   leaves it to you.

A branch that exists only on the remote (a background session pushed it
without ever creating a local branch) is adopted local-first: the plan
announces it, and finish creates the local branch from `origin/<branch>`
before merging — no round-trip through the remote required.

Both destructive flags are **off by default**. Claude will ask you before
using either one unless you passed the flag yourself or just approved the
same action moments earlier in the conversation — that explicit signal is
the only thing that enables them.

Guardrails: it refuses to run if your main checkout has uncommitted tracked
changes, if the branch's worktree is dirty (the work isn't finished), or if
the branch is held by a worktree the plugin doesn't manage. It will not kill
the session it is running in, refuses to kill when more than one job matches
the worktree (ambiguity is never resolved by guessing), and refuses to remove
a detached worktree whose HEAD holds commits not yet in the base or the
branch — `git branch -d` protects a *branch's* commits, and this is the
equivalent protection for a detached tip.

## License

MIT — see [LICENSE](LICENSE).
