---
description: "Finish a gitflow branch (Sourcetree-style): --no-ff merge into its base, push the base to origin, delete the worktree and local branch (--keep-branch keeps them), then ask before deleting the branch on origin."
argument-hint: "[branch] [--keep-branch] [--stash-changes|--discard-changes] [--kill-stalled-session]"
allowed-tools: ["Bash(bash:*)", "Bash(git:*)", "Bash(gh:*)"]
---

# /finish-feature

All logic is deterministic and lives in `scripts/finish-feature.sh` — do not
improvise git commands. Your job is only: run the plan, settle any leftovers with
the user, run finish, relay the output.

## 1. Plan (read-only)

Run:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/finish-feature.sh" plan $ARGUMENTS
```

Show the user the plan output verbatim. If it errors (exit 2), stop and report
— do not work around it.

Plan lines worth knowing (relay them verbatim like the rest):

- `plan: adopt` — no local branch exists but origin/&lt;branch&gt; does; finish
  will create the local branch from it first (local-first reconciliation)
- `plan: worktree ... DETACHED — matched by managed-worktree name` — the
  branch is not checked out anywhere, but a managed worktree matching it by
  name was found (normal after SessionEnd or for background sessions)
- `plan: remote` — whether origin/&lt;branch&gt; exists. Finish never deletes
  it on its own; at most it asks (step 7)
- `plan: session AMBIGUOUS` — multiple background jobs match the worktree;
  finish will not kill any of them

## 2. Leftovers in the worktree

If the plan shows `plan: leftovers` (or finish exits 2 with `leftover:`
lines), the worktree has uncommitted or untracked files. The script refuses
before merging because it cannot tell what they are. Show the files, then ask
(AskUserQuestion) which applies:

1. **Commit them to this branch** — they belong to the feature. Commit them in
   the worktree, then start again from step 1, so they are merged too.
2. **Carry them to a new branch** — re-run with `--stash-changes`. Relay the
   `ok: stashed ...` line: the stash outlives the worktree, and the user picks
   it up with `/start-feature <name>` then `git stash apply <sha>`.
3. **Discard them** — re-run with `--discard-changes`. Only on an explicit
   choice; never pick this yourself.

## 3. Keeping the branch

By default finish removes the worktree and deletes the local branch once a
long-lived branch (develop, dev, main, master) holds its work. A feature
merged into a temporary base (`release/*`, `hotfix/*`) is kept, and the
output says to re-run `/finish-feature` once that base lands in develop/main. Pass `--keep-branch` only when the user asked to keep it (in the
invocation or the immediately preceding conversation). Never add it on your
own judgment.

## 4. Finish

Run (with `--keep-branch` only per step 3, plus any leftover flag chosen in step 2):

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/finish-feature.sh" finish <branch> [--keep-branch] [--stash-changes|--discard-changes] [--kill-stalled-session]
```

## 5. Report

Relay the script's summary lines. Exit codes:

- `0` — finished; report merge commit, whether the base was pushed to origin
  (or that no origin exists / pushing is switched off), and what was/wasn't
  cleaned up
- `2` — refused by a preflight guard; report the reason verbatim, fix nothing
- `3` — merge conflicted; nothing was merged and the base was not pushed. The
  script pushed the feature branch to origin and opened a PR into the base
  instead. This is the normal two-step conflict process, not a
  failure: the PR body itself reminds the user that after the PR merges they
  run `/finish-feature <branch>` again, and the resumed run detects the branch
  is contained in the base and performs the remaining cleanup only. Relay the
  PR URL and say exactly that
- `4` — merged, but cleanup incomplete; report the warnings verbatim. Causes
  include: the base could not be pushed to origin, branch not deletable, several background jobs matching the worktree (none stopped),
  a detached worktree holding commits not yet in the base (refused to remove —
  they would be lost), or a folder some process still holds (on Windows, any
  process whose cwd is inside a folder locks it against deletion — EBUSY).
  Whenever the worktree survives, the branch is kept too, so re-running
  `/finish-feature <branch>` (from the main checkout) finishes the cleanup

## 6. A stalled background job holds the worktree

If removal fails and a background job's record matches the worktree, the
script acts on the job's state. A `done`/`failed` job is stopped and removal
retried without asking (`ok: stopped background job ...`). A `blocked` job may
be waiting on the user, so the script prints instead:

```
ask: kill-stalled <job-id> (blocked) — ...
```

Ask the user (AskUserQuestion, default No) whether to stop that job. On an
explicit Yes, re-run step 4 with the **same flags** plus
`--kill-stalled-session`. A job in any other state is never stopped.

## 7. The branch on origin

Finish never deletes origin/&lt;branch&gt; by itself. When the local branch was
deleted and origin's copy holds nothing beyond it, the output includes:

```
ask: delete-remote <branch> <sha> — ...
```

Ask the user (AskUserQuestion, default No) whether to delete origin's copy
too. Only on an explicit Yes, run:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/finish-feature.sh" delete-remote <branch> <sha>
```

with the branch and sha exactly as printed. It deletes only if origin is still
at that sha; if someone pushed in the meantime it refuses (exit 2) — relay
that and stop. Any `note:` about origin/&lt;branch&gt; (someone else's commits on
it, or the local branch was kept) is relayed as-is; no question is asked.
