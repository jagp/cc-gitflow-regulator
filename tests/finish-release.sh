#!/usr/bin/env bash
# Behaviour tests for scripts/finish-release.sh (release and hotfix): checks,
# landing, resuming after a conflict, cleanup. One PASS/FAIL line per case,
# exit 1 on any failure. Run from anywhere: bash tests/finish-release.sh
source "$(dirname "$0")/lib.sh"
today="$(date +%F)"
# opened: release_repo with release/0.4.0 started (manifests bumped, entry drafted).
opened() { release_repo; startr release start >/dev/null 2>&1; }
# edit <file> <text> <message>: overwrite a file and commit it.
edit() { printf '%s\n' "$2" > "$1"; git add "$1"; git commit -q -m "$3"; }

# --- the happy path --------------------------------------------------------------------------
opened; release_tip="$(git rev-parse HEAD)"
out="$(finr release plan 2>&1)"
check "plan changes nothing" '[ "$(git rev-parse HEAD)" = "$release_tip" ] && ! git show-ref -q --verify refs/tags/v0.4.0 && echo "$out" | grep -q "plan: merge into main: will do"'
out="$(finr release finish 2>&1)"
check "finish exits 0 and asks before pushing the tag" 'echo "$out" | grep -q exit=0 && echo "$out" | grep -q "^ask: push-tag v0.4.0"'
check "main gets a --no-ff merge of the release" \
  '[ "$(git log -1 --format=%s main)" = "Merge branch '"'"'release/0.4.0'"'"'" ] && [ "$(git rev-list --parents -n1 main | wc -w)" = 3 ] && git merge-base --is-ancestor "$release_tip" main'
check "the tag sits on that merge commit" '[ "$(git rev-parse "v0.4.0^{commit}")" = "$(git rev-parse main)" ]'
check "develop gets the release too" 'git merge-base --is-ancestor v0.4.0 develop'
check "the entry is dated today" 'git show main:CHANGELOG.md | grep -q "^## 0.4.0 — $today"'
check "release branch deleted, ends on develop" '! git show-ref -q --verify refs/heads/release/0.4.0 && [ "$(git branch --show-current)" = develop ]'
check "main and develop pushed, tag not" \
  '[ "$(git ls-remote origin refs/heads/main | cut -f1)" = "$(git rev-parse main)" ] && ! git ls-remote --exit-code --tags origin v0.4.0 >/dev/null'

opened; before="$(git ls-remote origin refs/heads/main | cut -f1)"
CC_GITFLOW_REGULATOR_PUSH_MERGED=0 finr release finish >/dev/null 2>&1
check "PUSH_MERGED=0 pushes nothing" '[ "$(git ls-remote origin refs/heads/main | cut -f1)" = "$before" ] && git show-ref -q --verify refs/tags/v0.4.0'
opened; git remote remove origin
out="$(finr release finish 2>&1)"
check "no origin: lands locally and says nothing was pushed" 'echo "$out" | grep -q exit=0 && echo "$out" | grep -q "nothing pushed — no origin remote"'

# --- refusals --------------------------------------------------------------------------------
opened; echo dirty >> CHANGELOG.md
check "dirty tree refused" 'finr release finish 2>&1 | grep -q exit=2'
opened; mkdir tests; printf '#!/usr/bin/env bash\nexit 1\n' > tests/broken.sh; git add tests; git commit -q -m "test: broken"
out="$(finr release finish 2>&1)"
check "a failing test suite refuses" 'echo "$out" | grep -q exit=2 && echo "$out" | grep -q "tests: FAILED (tests/broken.sh)" && ! git show-ref -q --verify refs/tags/v0.4.0'
opened; sed -i 's/^## 0.4.0 — unreleased/## something else/' CHANGELOG.md; git commit -q -am "docs: lose the entry"
check "a missing changelog entry refuses" 'finr release finish 2>&1 | grep -q "CHANGELOG.md has no entry for 0.4.0"'
check "the changelog switch drops that check" 'CC_GITFLOW_REGULATOR_CHANGELOG=0 finr release finish 2>&1 | grep -q exit=0'
opened; sed -i 's/0.4.0/0.3.9/' .claude-plugin/plugin.json; git commit -q -am "chore: wrong version"
check "a manifest at another version refuses" 'finr release finish 2>&1 | grep -q "not at 0.4.0: .claude-plugin/plugin.json"'

# --- warnings --------------------------------------------------------------------------------
opened; mkdir scripts; edit README.md "Install 0.3.1 like this" "docs: install note"
edit scripts/tool.sh "echo tool" "feat: a tool"
out="$(finr release plan 2>&1)"
check "version sweep names files still saying 0.3.1" 'echo "$out" | grep -q "warn: still names 0.3.1: README.md:1"'
check "coverage names changed files no test mentions" 'echo "$out" | grep -q "warn: no test change mentions scripts/tool.sh"'

# --- conflicts and resuming ------------------------------------------------------------------
# develop and the release both change notes.txt: the back-merge conflicts.
release_repo; edit notes.txt base "docs: notes"; git push -q origin develop
startr release start >/dev/null 2>&1; edit notes.txt release "docs: release notes"
git switch -q develop; edit notes.txt develop "docs: develop notes"; git switch -q release/0.4.0
out="$(finr release finish 2>&1)"
check "back-merge conflict: exit 3, main merged and tagged locally" \
  'echo "$out" | grep -q exit=3 && echo "$out" | grep -q "conflict: notes.txt" && git show-ref -q --verify refs/tags/v0.4.0 && [ "$(git branch --show-current)" = release/0.4.0 ]'
tag_before="$(git rev-parse v0.4.0)"
git switch -q develop; git merge -q --no-ff release/0.4.0 -m "Merge release by hand" >/dev/null 2>&1
git checkout -q --theirs notes.txt; git add notes.txt; git commit -q --no-edit; git switch -q release/0.4.0
out="$(finr release finish 2>&1)"
check "re-run after resolving skips what is done" \
  'echo "$out" | grep -q exit=0 && [ "$(git rev-parse v0.4.0)" = "$tag_before" ] && ! git show-ref -q --verify refs/heads/release/0.4.0'

# main and the release both change notes.txt: the merge into main conflicts.
release_repo; edit notes.txt base "docs: notes"; git push -q origin develop
startr release start >/dev/null 2>&1; edit notes.txt release "docs: release notes"
git switch -q main; edit notes.txt main "docs: main-only fix"; git switch -q release/0.4.0
main_before="$(git rev-parse main)"
out="$(finr release finish 2>&1)"
check "main-merge conflict: exit 3, asks to sync main, main untouched, nothing tagged" \
  'echo "$out" | grep -q exit=3 && echo "$out" | grep -q "^ask: sync-main" && [ "$(git rev-parse main)" = "$main_before" ] && ! git show-ref -q --verify refs/tags/v0.4.0'
out="$(finr release sync-main 2>&1)"
check "sync-main stops on the conflict and names it" 'echo "$out" | grep -q exit=3 && echo "$out" | grep -q "conflict: notes.txt"'
git checkout -q --ours notes.txt; git add notes.txt; git commit -q --no-edit
check "after resolving, finish lands it" 'finr release finish 2>&1 | grep -q exit=0 && git merge-base --is-ancestor v0.4.0 develop'

# --- odd inputs ------------------------------------------------------------------------------
opened; printf '# Changelog\r\n\r\n## 0.4.0 — unreleased\r\n\r\n- a thing\r\n' > CHANGELOG.md; git commit -q -am "docs: crlf changelog"
finr release finish >/dev/null 2>&1
check "a CRLF changelog is dated with its line endings kept" \
  'git show main:CHANGELOG.md | grep -q "^## 0.4.0 — $today" && [ "$(git show main:CHANGELOG.md | tr -cd "\r" | wc -c)" = 5 ]'
opened; git switch -q -c feature/elsewhere develop
check "finish works from another branch and ends on develop" \
  'finr release finish 2>&1 | grep -q exit=0 && [ "$(git branch --show-current)" = develop ]'
opened; wt held release/0.4.0; git merge -q --no-ff feature/held -m "Merge feature/held into release"
finr release finish >/dev/null 2>&1
check "a feature held for the release is cleaned up with it" \
  '! git show-ref -q --verify refs/heads/feature/held && [ ! -e .claude/worktrees/held ]'

# --- hotfix ----------------------------------------------------------------------------------
opened; commit "feat: in the release"
startr hotfix start >/dev/null 2>&1; edit fix.txt fixed "fix: the urgent bug"
out="$(finr hotfix finish 2>&1)"
check "hotfix lands on main with its own tag" 'echo "$out" | grep -q exit=0 && [ "$(git rev-parse "v0.3.2^{commit}")" = "$(git rev-parse main)" ]'
check "with a release open, the fix goes into the release, not develop" \
  'git merge-base --is-ancestor v0.3.2 release/0.4.0 && ! git merge-base --is-ancestor v0.3.2 develop'
check "the empty entry was filled from the fix" 'git show main:CHANGELOG.md | grep -q "^- the urgent bug"'
release_repo; startr hotfix start >/dev/null 2>&1; edit fix.txt fixed "fix: the urgent bug"
finr hotfix finish >/dev/null 2>&1
check "with no release open, the fix goes into develop" 'git merge-base --is-ancestor v0.3.2 develop'

echo "$failures failure(s)"; [ "$failures" = 0 ]
