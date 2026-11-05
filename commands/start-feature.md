---
description: "Start a gitflow feature branch (Sourcetree-style): sync the base, branch feature/<name> off develop, find the test suite and run a baseline. Counterpart of /finish-feature."
argument-hint: "<feature name> [--create-base] [--skip-tests]"
allowed-tools: ["Bash(bash:*)", "Bash(git:*)"]
---

# /start-feature

All git logic is deterministic and lives in `scripts/start-feature.sh`. Do not
improvise git commands. Your job is to run the plan, get consent for creating
a base branch if one is needed, run start, run the test baseline, and relay the
output.

`--skip-tests` is a flag for this command only. Do not pass it to the script.

## 1. Plan (read-only)

Run:

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/start-feature.sh" plan <name> [--create-base]
```

Show the user the plan output verbatim. If it errors (exit 2), stop and report
the reason verbatim. Do not work around it. In particular:

- **uncommitted changes**: point the user at `/feature-dirty <name>`, which
  carries dirty work onto a new branch. Do not stash for them.
- **branch already exists**: offer to switch to it. Do not create a variant
  name.

## 2. Consent for `--create-base`

If the plan prints `plan: base MISSING`, the repo has no `develop` branch yet.
`--create-base` creates `develop` from the trunk (main/master). It is local
only and nothing is pushed, but it sets a convention for the whole repo, so:

1. If the user passed `--create-base` themselves, proceed.
2. Otherwise ask (AskUserQuestion, default No) and include it only on an
   explicit Yes. On No, stop and report that `/finish-feature` needs a base
   branch to merge into.

## 3. Start

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/start-feature.sh" start <name> [--create-base]
```

Exit `0` means the branch exists and is checked out. Exit `2` means a guard
refused; report the reason verbatim and fix nothing.

## 4. Test baseline

The script's `test:` lines name the test runner(s) it found.

- If the user passed `--skip-tests`, or the output is `test: none found`, skip
  this step and say so in the report.
- Otherwise run the **first** `test:` command from the repo root, before any
  changes are made.
- Record the result as the baseline:
  - pass: say so
  - fail: list the failing tests. These failures predate the feature, so
    later failures can be told apart from new ones.
- A failing baseline does not undo the branch. It is information, not a gate.

## 5. Report

Keep it short:

- branch created, base it came from, and the short commit
- any `ok:` / `warn:` lines (base created, fast-forwarded, diverged)
- open work branches, if any. They may be duplicates of this idea.
- baseline test result, or why it was skipped
- reminder: nothing was pushed. When the work is done, `/finish-feature`
  merges this branch back into its recorded base and pushes that base to
  origin.
