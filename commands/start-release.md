---
description: "Start a gitflow release: suggest the next version from the commits since the last tag, branch release/<version> off develop, bump the manifests, draft the changelog entry."
argument-hint: "[X.Y.Z]"
allowed-tools: ["Bash(bash:*)", "Bash(git:*)"]
---

# /start-release

All git logic is deterministic and lives in `scripts/start-release.sh`. Do not
improvise git commands. Your job is to run the plan, settle the version with
the user, run start, and relay the output.

In this file, `<type>` is `release`. (`/start-hotfix` follows this same file
with `<type>` = `hotfix`.)

## 1. Plan (read-only)

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/start-release.sh" <type> plan $ARGUMENTS
```

Show the output verbatim. On exit `2`, stop and report the reason verbatim;
fix nothing. Common refusals: uncommitted changes, another `<type>/*` still
open (finish it first), the tag already exists (pick another version), a
malformed version (it must be `X.Y.Z`, no `v`, no suffix).

## 2. Version

- **A version was given:** use it. If the plan printed a `warn: ... understates`
  line, ask (AskUserQuestion) whether to keep it or take the suggestion.
- **No version given:** the plan's `plan: version` line is a suggestion, with
  the commits that drove it listed under it. Ask (AskUserQuestion) whether to
  use it; the user may name another version instead. Leaving 0.x (going to
  1.0.0) is never suggested: it only happens when the user names it.

## 3. Start

```
bash "${CLAUDE_PLUGIN_ROOT}/scripts/start-release.sh" <type> start <version>
```

Always pass the settled version explicitly.

## 4. Report

- the branch created and where it started
- the `ok:` lines: manifests bumped, changelog entry drafted, bump committed
- the baseline test result (`tests: passed`, `tests: FAILED (...)`, or the
  `warn: no tests ran` line). A failing baseline is information, not a gate.
- if a changelog entry was drafted: ask the user to edit it before finishing.
  It is built from commit subjects and usually wants rewording for readers.
- nothing was pushed. When the branch is ready, `/finish-<type>` lands it.
