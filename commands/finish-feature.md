---
description: "Finish a gitflow branch (Sourcetree-style): merge into develop with --no-ff, release the worktree lock, optionally kill the attached session and delete the branch — destructive steps confirmed first."
argument-hint: "[branch] [--kill-session] [--delete-branch]"
allowed-tools: ["Bash(bash:*)", "Bash(git:*)", "Bash(gh:*)"]
---

# /finish-branch

All logic is deterministic and lives in `scripts/finish-branch.sh` — do not
improvise git commands. Your job is only: run the plan, obtain consent for the
destructive flags, run finish, relay the output.

## 1. Plan (read-only)

Run:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/finish-branch.sh" plan $ARGUMENTS
```

Show the user the plan output verbatim. If it errors (exit 2), stop and report
— do not work around it.

Plan lines worth knowing (relay them verbatim like the rest):

- `plan: adopt` — no local branch exists but origin/&lt;branch&gt; does; finish
  will create the local branch from it first (local-first reconciliation)
- `plan: worktree ... DETACHED — matched by managed-worktree name` — the
  branch is not checked out anywhere, but a managed worktree matching it by
  name was found (normal after SessionEnd or for background sessions)
- `plan: remote` — whether origin/&lt;branch&gt; exists; finish only ever runs
  `git fetch --prune` and reports — it NEVER deletes remote branches
- `plan: session AMBIGUOUS` — multiple jobs match; finish will refuse
  --kill-session rather than guess

## 2. Consent for destructive flags

Two flags are destructive and default OFF:

- `--kill-session` — kills the Claude session attached to the branch's
  worktree and deletes its job directory
- `--delete-branch` — removes the worktree and deletes the local branch

For each flag, include it in step 3 only if ONE of these holds:

1. The user passed the flag themselves in the `/finish-branch` invocation —
   that is the explicit permission signal.
2. The **immediately preceding** conversation clearly shows the user already
   understands and has approved that exact action (e.g. they just answered a
   permission prompt or question amounting to the same thing). Older or vaguer
   mentions do not count.
3. Neither applies → ask now (AskUserQuestion, one question per flag, default
   No) and include the flag only on an explicit Yes.

Never substitute your own judgment that deletion "seems fine" — the gate is
the user's signal, not the state of the repo.

## 3. Finish

Run (with only the consented flags):

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/finish-branch.sh" finish <branch> [--kill-session] [--delete-branch]
```

## 4. Report

Relay the script's summary lines. Exit codes:

- `0` — finished; report merge commit, and what was/wasn't cleaned up
- `2` — refused by a preflight guard; report the reason verbatim, fix nothing
- `3` — merge conflicted; the script already pushed the branch and opened a PR
  (the only path that pushes, and it never happens without the user having
  invoked this command). This is the normal two-step conflict process, not a
  failure: the PR body itself reminds the user that after the PR merges they
  run `/finish-branch <branch>` again, and the resumed run detects the branch
  is contained in the base and performs the remaining cleanup only. Relay the
  PR URL and say exactly that
- `4` — merged, but cleanup incomplete; report the warnings verbatim. Causes
  include: branch not deletable, an ambiguous session match (refused to kill),
  a detached worktree holding commits not yet in the base (refused to remove —
  they would be lost), or a folder some process still holds (on Windows, any
  process whose cwd is inside a folder locks it against deletion — EBUSY)

After any finish, if the output includes a `note:` that origin/&lt;branch&gt;
still exists on the remote, relay it: deleting remote branches is always the
user's call (multiplayer-safe), never the script's.
