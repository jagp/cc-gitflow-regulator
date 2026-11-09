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

# --- start-release.sh ------------------------------------------------------------------------
# release_repo: main and develop at a released 0.3.1 (tag, both manifests, a
# changelog), plus one feat commit on develop, so the suggestion is 0.4.0.
release_repo() {
  fresh; mkdir .claude-plugin
  printf '{\n  "name": "x",\n  "version": "0.3.1"\n}\n' > .claude-plugin/plugin.json
  printf '{\n  "plugins": [\n    {\n      "name": "x",\n      "version": "0.3.1"\n    }\n  ]\n}\n' > .claude-plugin/marketplace.json
  printf '# Changelog\n\n## 0.3.1 — 2026-01-01\n\n- old\n' > CHANGELOG.md
  git add . && git commit -q -m "chore: release 0.3.1" && git tag v0.3.1 && git push -q origin main v0.3.1
  git switch -q develop && git merge -q --ff-only main && commit "feat: a new thing" && git push -q origin develop
}
startr() { bash "$REPO/scripts/start-release.sh" "$@"; echo "exit=$?"; }

release_repo; before="$(git rev-parse HEAD)"
out="$(startr release plan 2>&1)"
check "plan suggests 0.4.0 and names the evidence" \
  'echo "$out" | grep -q "plan: version 0.4.0 (suggested from v0.3.1: 0 breaking, 1 feat" && echo "$out" | grep -q "feat: a new thing"'
check "plan changes nothing" '[ "$(git rev-parse HEAD)" = "$before" ] && ! git show-ref -q --verify refs/heads/release/0.4.0'
out="$(startr release start 2>&1)"
check "start creates release/0.4.0 from develop and switches to it" \
  'echo "$out" | grep -q exit=0 && [ "$(git branch --show-current)" = release/0.4.0 ] && git merge-base --is-ancestor develop HEAD'
check "manifests bumped to 0.4.0" \
  'grep -q "\"version\": \"0.4.0\"" .claude-plugin/plugin.json && grep -q "\"version\": \"0.4.0\"" .claude-plugin/marketplace.json'
check "changelog entry drafted above the old one" \
  '[ "$(grep -n "^## " CHANGELOG.md | head -1)" = "3:## 0.4.0 — unreleased" ] && grep -q "^### Added" CHANGELOG.md && grep -q "^- a new thing" CHANGELOG.md'
check "the bump is committed" '[ "$(git log -1 --format=%s)" = "chore(release): bump version to 0.4.0" ] && [ -z "$(git status --porcelain --untracked-files=no)" ]'
check "nothing pushed" '! git ls-remote --exit-code origin refs/heads/release/0.4.0 >/dev/null'

release_repo
sed -i 's/0.3.1/0.4.0/' .claude-plugin/plugin.json .claude-plugin/marketplace.json
printf '# Changelog\n\n## 0.4.0 — unreleased\n\n- written by hand\n' > CHANGELOG.md
git commit -q -am "chore: prepare 0.4.0"; before="$(git rev-parse HEAD)"
out="$(startr release start 0.4.0 2>&1)"
check "already bumped and entry present: no extra commit" \
  'echo "$out" | grep -q exit=0 && [ "$(git rev-parse HEAD)" = "$before" ] && grep -q "written by hand" CHANGELOG.md'

release_repo; git rm -q CHANGELOG.md; git commit -q -m "chore: no changelog"
CC_GITFLOW_REGULATOR_CHANGELOG=0 startr release start >/dev/null 2>&1
check "changelog off by env: no CHANGELOG.md written" '[ ! -e CHANGELOG.md ]'
release_repo; git config gitflow.release.changelog false
startr release start >/dev/null 2>&1
check "changelog off by git config: entry not drafted" '! grep -q "0.4.0" CHANGELOG.md'

release_repo; echo dirty >> CHANGELOG.md
check "dirty tree refused" 'startr release start 2>&1 | grep -q exit=2'
release_repo; git branch release/0.9.0
check "an open release is refused" 'startr release start 2>&1 | grep -q "release/0.9.0 is still open"'
release_repo; git tag v0.4.0 "$(git commit-tree "HEAD^{tree}" -m "released elsewhere")"
check "an existing local tag is refused" 'startr release start 2>&1 | grep -q "tag v0.4.0 already exists"'
release_repo; git tag v0.4.0; git push -q origin v0.4.0; git tag -d v0.4.0 >/dev/null
check "a tag only on origin is refused" 'startr release start 2>&1 | grep -q "tag v0.4.0 already exists"'
release_repo
for bad in 1.2.0-rc.1 v1.2.0 1.2; do
  check "malformed version $bad refused" 'startr release start '"$bad"' 2>&1 | grep -q "expected X.Y.Z"'
done
out="$(startr release plan 0.3.2 2>&1)"
check "an understated version warns" 'echo "$out" | grep -q "warn: 0.3.2 understates the commits (suggested 0.4.0)"'

# --- hotfix ----------------------------------------------------------------------------------
release_repo; startr release start >/dev/null 2>&1
out="$(startr hotfix start 2>&1)"
check "hotfix starts from main while a release is open" \
  'echo "$out" | grep -q exit=0 && [ "$(git branch --show-current)" = hotfix/0.3.2 ] && [ "$(git merge-base HEAD main)" = "$(git rev-parse main)" ] && ! git merge-base --is-ancestor develop HEAD'
check "hotfix bumps manifests and adds a bare entry" \
  'grep -q "\"version\": \"0.3.2\"" .claude-plugin/plugin.json && grep -q "^## 0.3.2 — unreleased" CHANGELOG.md && ! grep -q "^### " CHANGELOG.md'
check "a second hotfix is refused" 'startr hotfix start 0.3.3 2>&1 | grep -q "hotfix/0.3.2 is still open"'

echo "$failures failure(s)"; [ "$failures" = 0 ]
