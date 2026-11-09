#!/usr/bin/env bash
# Behaviour tests for the release side of the plugin: version suggestion
# (scripts/release-lib.sh) and scripts/start-release.sh for release and hotfix
# branches. One PASS/FAIL line per case, exit 1 on any failure.
# Run from anywhere: bash tests/start-release.sh
source "$(dirname "$0")/lib.sh"
# rlib <function> [args...]: call a release-lib.sh function in a subshell.
rlib() { ( source "$REPO/scripts/common.sh" && source "$REPO/scripts/release-lib.sh" && "$@" ); }
# commit <message>: an empty commit on the current branch with that message.
commit() { git commit -q --allow-empty -m "$1"; }
# suggest_from <tag>: classify <tag>..HEAD and print the suggested version.
suggest_from() { rlib eval "classify_commits $1..HEAD && suggest_version ${1#v}"; }

# --- version suggestion ----------------------------------------------------------------------
fresh; git switch -q develop; git tag v0.3.1
commit "fix: a bug"
check "fix: patch bump" '[ "$(suggest_from v0.3.1)" = 0.3.2 ]'
commit "feat: a thing"
check "feat: minor bump" '[ "$(suggest_from v0.3.1)" = 0.4.0 ]'
commit "feat(core)!: break it"
check "breaking below 1.0: minor bump" '[ "$(suggest_from v0.3.1)" = 0.4.0 ]'

fresh; git switch -q develop; git tag v1.2.3
commit "feat(core)!: break it"
check "breaking from 1.0 on: major bump" '[ "$(suggest_from v1.2.3)" = 2.0.0 ]'
fresh; git switch -q develop; git tag v1.2.3
git commit -q --allow-empty -m "refactor: tidy" -m "BREAKING CHANGE: the old flag is gone"
check "a BREAKING CHANGE footer counts as breaking" '[ "$(suggest_from v1.2.3)" = 2.0.0 ]'

fresh; git switch -q develop; git tag v0.9.0
commit "feat!: break it"
check "never suggests 1.0.0" '[ "$(suggest_from v0.9.0)" = 0.10.0 ]'
fresh; git switch -q develop; git tag v0.3.1
commit "docs: words"; commit "test: more"
check "only non-user-facing commits: patch bump" '[ "$(suggest_from v0.3.1)" = 0.3.2 ]'

fresh; git switch -q develop; git tag v0.3.1; commit "fix: x"
git tag vv.0.0.1; git tag vbump-0.3.1
check "odd tag shapes are ignored" '[ "$(rlib last_release_tag develop)" = v0.3.1 ]'
fresh; git switch -q develop; mkdir .claude-plugin
printf '{\n  "name": "x",\n  "version": "0.2.0"\n}\n' > .claude-plugin/plugin.json
check "no tag: no last release tag" '[ -z "$(rlib last_release_tag develop)" ]'
check "the manifest version is the fallback" '[ "$(rlib current_manifest_version)" = 0.2.0 ]'

fresh; git switch -q develop; git tag v0.3.1
commit "Fix typo"; commit "feat: a thing"
git switch -q -c side; commit "fix: on a side branch"; git switch -q develop
git merge -q --no-ff side -m "Merge branch 'side'"
counts="$(rlib eval 'classify_commits v0.3.1..HEAD; echo "$feat_count $fix_count $unclassified_count"')"
check "unclassified counted, merge commits skipped" '[ "$counts" = "1 1 1" ]'
check "a given version that understates the commits is flagged" \
  'rlib eval "classify_commits v0.3.1..HEAD && understates 0.3.1 0.3.2"'
check "a given version that matches the commits is not flagged" \
  '! rlib eval "classify_commits v0.3.1..HEAD && understates 0.3.1 0.4.0"'

echo "$failures failure(s)"; [ "$failures" = 0 ]
