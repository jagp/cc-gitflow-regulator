---
description: "Finish a gitflow release: check it, merge it into main (--no-ff), tag it, merge the tag back into develop, push the branches, clean up, then ask before pushing the tag and publishing the GitHub Release."
argument-hint: ""
allowed-tools: ["Bash(bash:*)", "Bash(git:*)", "Bash(gh:*)"]
---

# /finish-release

All logic is deterministic and lives in `scripts/finish-release.sh`. Do not
improvise git commands. Your job is to run the plan, run finish, handle the
`ask:` lines with the user, and relay the output.

In this file, `<type>` is `release`. (`/finish-hotfix` follows this same file
with `<type>` = `hotfix`.)

## 1. Plan (read-only)

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/finish-release.sh" <type> plan
```

Show the output verbatim, including every `warn:` line (old version strings
still in files, changed files no test mentions, commits only on main). They
never block; the user decides whether to fix them first. On exit `2`, stop
and report the reason verbatim.

## 2. Finish

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/finish-release.sh" <type> finish
```

Exit codes:

- `0`: landed. Relay the `ok:` lines, then handle the `ask:` lines (step 3).
  Exception, the PR route (`gitflow.release.pr` / `CC_GITFLOW_REGULATOR_RELEASE_PR`
  on): a `next:` line means nothing landed yet. finish pushed the branch and
  opened (or found) a PR into main. Relay the PR URL and the `next:` line,
  stress that the PR must be merged **with a merge commit** (not squash or
  rebase), and stop. Never merge the PR yourself. Once the user has merged
  it, running `/finish-<type>` again continues from the tag.
- `2`: refused (dirty tree, failing tests, no changelog entry, a manifest at
  another version, a tag that marks something else; on the PR route also no
  origin, no working `gh`, or a PR that was squash/rebase merged). Report
  verbatim, fix nothing.
- `3`: a merge conflicted. Nothing half-done is left behind, and running
  finish again later skips every step that already happened.
  - With `ask: sync-main`: the merge into main conflicts. Ask
    (AskUserQuestion, default Yes) whether to merge main into the branch so
    the conflict can be resolved there. On yes, run
    `bash "${CLAUDE_PLUGIN_ROOT}/scripts/finish-release.sh" <type> sync-main`.
    If that lists `conflict:` files, show them and resolve each with the user
    (never pick a side on your own), commit, then run step 2 again.
  - With `next: merge ... by hand`: main and the tag are done (local only);
    the merge back conflicted. Do that merge with the user, resolve the listed
    files together, commit, then run step 2 again.
- `4`: landed, but something in cleanup failed (a push, deleting the branch).
  Report the `warn:` lines verbatim.

## 3. The ask: lines

- `ask: delete-remote <branch> <sha>`: the branch also exists on origin. Ask
  (AskUserQuestion, default No). Only on an explicit yes, run
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/finish-feature.sh" delete-remote <branch> <sha>`
  with the values exactly as printed.
- `ask: push-tag v<version>`: ask (AskUserQuestion, default No) whether to
  push the tag and publish. A pushed tag is hard to take back. Only on an
  explicit yes, run
  `bash "${CLAUDE_PLUGIN_ROOT}/scripts/finish-release.sh" <type> publish`.
  On no, say the tag stays local and running `/finish-<type>` again later
  goes straight back to this question.

## 4. Report

- the merge into main, the tag, and the branch merged back into
- what was pushed, or why nothing was
- after publish: the GitHub Release (or the `warn:` line with the command to
  run by hand), every `rollback:` line, and the `notify:` / `announce:`
  lines, so the user knows where to announce the release and has the text
  ready. Nothing is sent anywhere.
