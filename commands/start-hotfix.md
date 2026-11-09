---
description: "Start a gitflow hotfix: branch hotfix/<version> off main (the next patch unless given), bump the manifests, add a changelog entry to fill in. Allowed while a release is open."
argument-hint: "[X.Y.Z]"
allowed-tools: ["Bash(bash:*)", "Bash(git:*)"]
---

# /start-hotfix

Follow `${CLAUDE_PLUGIN_ROOT}/commands/start-release.md` exactly, with the
arguments `$ARGUMENTS`, and with `<type>` = `hotfix` everywhere it appears.

What differs for a hotfix (the script handles all of it):

- it branches from main, not develop, so it carries none of the unreleased work
- the suggested version is always the next patch after the last release
- an open release does not block it; another open hotfix does
- the changelog entry starts as a bare heading. Filling it in is optional:
  `/finish-hotfix` fills an empty entry from the hotfix's commits.
