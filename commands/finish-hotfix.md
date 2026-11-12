---
description: "Finish a gitflow hotfix: check it, merge it into main (--no-ff), tag it, merge the tag into the open release (or develop), push, clean up, then ask before pushing the tag and publishing."
argument-hint: ""
allowed-tools: ["Bash(bash:*)", "Bash(git:*)", "Bash(gh:*)"]
---

# /finish-hotfix

Follow `${CLAUDE_PLUGIN_ROOT}/commands/finish-release.md` exactly, with
`<type>` = `hotfix` everywhere it appears.

What differs for a hotfix (the script handles all of it):

- an empty changelog entry is filled from the hotfix's commits before it is dated
- after main, the fix is merged into the open `release/*` branch if there is
  one, otherwise into develop, so the next release cannot ship without it.
  The version-file conflict this always causes with an open release is
  settled automatically (the release's version wins; both changelog entries
  are kept). Any other conflict stops as usual.
