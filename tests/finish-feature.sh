#!/usr/bin/env bash
# Behaviour tests for scripts/finish-feature.sh: one PASS/FAIL line per case,
# exit 1 if any case fails. Run from anywhere: bash tests/finish-feature.sh
source "$(dirname "$0")/lib.sh"
W=.claude/worktrees
gone() { ! git show-ref -q --verify "refs/heads/$1"; }

# --- cleanup defaults -----------------------------------------------------------
fresh; wt a 2>/dev/null; out="$(fin finish feature/a 2>&1)"
check "default: merged, base pushed, branch and worktree gone" \
  'gone feature/a && [ ! -e $W/a ] && echo "$out" | grep -q "pushed develop" && echo "$out" | grep -q exit=0'
check "deleting the branch clears its recorded base" '! git config --get gitflow.branch.feature/a.base >/dev/null'

wt b 2>/dev/null; fin finish feature/b --keep-branch >/dev/null 2>&1
check "--keep-branch keeps branch and worktree" '! gone feature/b && [ -d $W/b ]'

fresh; git branch release/x develop; wt r release/x 2>/dev/null; out="$(fin finish feature/r 2>&1)"
check "merges into the recorded base" '[ "$(git rev-list --count release/x..feature/r)" = 0 ]'
check "temporary base keeps the branch" '! gone feature/r && echo "$out" | grep -q "temporary branch"'
git switch -q develop && git merge -q --no-ff --no-edit release/x; fin finish feature/r >/dev/null 2>&1
check "re-run after the base lands deletes it" 'gone feature/r && [ ! -e $W/r ]'

# --- worktree leftovers -----------------------------------------------------------
fresh; wt d 2>/dev/null; echo x > $W/d/new.txt; out="$(fin finish feature/d 2>&1)"
check "leftovers refuse before the merge" \
  'echo "$out" | grep -q exit=2 && [ "$(git rev-list --count develop..feature/d)" = 1 ]'
fin finish feature/d --stash-changes >/dev/null 2>&1
check "--stash-changes keeps the work in a stash" 'gone feature/d && git stash list | grep -q "leftovers from feature/d"'

fresh; wt e 2>/dev/null; echo x > $W/e/new.txt; fin finish feature/e --discard-changes >/dev/null 2>&1
check "--discard-changes removes it" 'gone feature/e && [ ! -e $W/e ]'

fresh; wt c 2>/dev/null; mkdir -p $W/c/.claude && echo "{}" > $W/c/.claude/settings.local.json
fin finish feature/c >/dev/null 2>&1
check ".claude/ files are not leftovers" 'gone feature/c'

out="$(fin finish feature/c --stash-changes --discard-changes 2>&1)"
check "--stash-changes and --discard-changes conflict" 'echo "$out" | grep -q "mutually exclusive"'

# --- running inside the worktree ---------------------------------------------------
fresh; wt s 2>/dev/null; out="$(cd $W/s && fin finish feature/s 2>&1)"
check "run from inside: branch kept for the re-run" '! gone feature/s && echo "$out" | grep -q exit=4'
fin finish feature/s >/dev/null 2>&1
check "re-run from the main checkout cleans up" 'gone feature/s && [ ! -e $W/s ]'

# --- pushing the base ---------------------------------------------------------------
fresh; wt p 2>/dev/null; CC_GITFLOW_REGULATOR_FEATURE_MERGE=local fin finish feature/p >/dev/null 2>&1
check "merge mode local leaves origin/develop alone" '[ "$(git -C ../origin.git rev-parse develop)" != "$(git rev-parse develop)" ]'

fresh; git remote remove origin; wt n 2>/dev/null; out="$(fin finish feature/n 2>&1)"
check "no origin: says it checked" 'echo "$out" | grep -q "none configured"'

# --- merge conflict -------------------------------------------------------------------
fresh; wt x 2>/dev/null; git switch -q develop; echo theirs > x.txt; git add x.txt; git commit -q -m "develop edits x"
git push -q origin develop; before="$(git -C ../origin.git rev-parse develop)"; out="$(fin finish feature/x 2>&1)"
check "conflict: exit 3, base not pushed, branch pushed, nothing deleted, no ask" \
  'echo "$out" | grep -q exit=3 && [ "$(git -C ../origin.git rev-parse develop)" = "$before" ] \
   && git ls-remote --exit-code ../origin.git feature/x >/dev/null && ! gone feature/x && [ -d $W/x ] \
   && ! echo "$out" | grep -q "^ask:"'

# --- the branch on origin ----------------------------------------------------------------
fresh; wt o 2>/dev/null; git push -q origin feature/o 2>/dev/null; out="$(fin finish feature/o 2>&1)"
ask="$(echo "$out" | grep "^ask: delete-remote")"
check "offers the origin delete when origin holds nothing new" '[ -n "$ask" ]'
set -- $ask
fin delete-remote "$3" "$(git rev-parse main)" >/dev/null 2>&1
check "delete-remote refuses a stale sha" 'git ls-remote --exit-code ../origin.git feature/o >/dev/null'
fin delete-remote "$3" "$4" >/dev/null 2>&1
check "delete-remote deletes at the checked sha" '! git ls-remote --exit-code ../origin.git feature/o >/dev/null'

fresh; wt t 2>/dev/null; git push -q origin feature/t 2>/dev/null
git clone -q ../origin.git ../other 2>/dev/null
(cd ../other && git switch -q feature/t && git commit -q --allow-empty -m theirs && git push -q)
out="$(fin finish feature/t 2>&1)"
check "someone else's commits on origin: no offer" '! echo "$out" | grep -q "^ask:" && echo "$out" | grep -q "never had"'

# --- merge mode pr (CC_GITFLOW_REGULATOR_FEATURE_MERGE / gitflow.feature.merge) -----------------
fake_gh
fresh; reset_gh; wt q 2>/dev/null; git config gitflow.feature.merge pr; develop_before="$(git rev-parse develop)"
out="$(fin plan feature/q 2>&1)"
check "mode pr: plan says the merge goes through a PR" 'echo "$out" | grep -q "plan: merge         via a PR"'
out="$(fin finish feature/q 2>&1)"
check "mode pr: finish pushes the branch, opens a PR into develop and stops"   'echo "$out" | grep -q exit=0 && grep -q "^gh pr create --base develop --head feature/q" "$SCRATCH_LOG" && echo "$out" | grep -q "^next: .*merge commit" && [ "$(git ls-remote origin refs/heads/feature/q | cut -f1)" = "$(git rev-parse feature/q)" ]'
check "mode pr: develop untouched, branch and worktree kept"   '[ "$(git rev-parse develop)" = "$develop_before" ] && [ "$(git ls-remote origin refs/heads/develop | cut -f1)" = "$develop_before" ] && ! gone feature/q && [ -d $W/q ]'
out="$(fin finish feature/q 2>&1)"
check "mode pr: a re-run while the PR is open opens no second PR" '[ "$(grep -c "^gh pr create" "$SCRATCH_LOG")" = 1 ] && echo "$out" | grep -q "already open"'
merge_on_origin merge develop feature/q
out="$(fin finish feature/q 2>&1)"
check "mode pr: after the merge, finish catches develop up and cleans up"   'echo "$out" | grep -q exit=0 && gone feature/q && [ ! -e $W/q ] && git merge-base --is-ancestor "$(git ls-remote origin refs/heads/develop | cut -f1)" develop && echo "$out" | grep -q "happened on GitHub"'
fresh; reset_gh; wt v 2>/dev/null; git config gitflow.feature.merge pr; fin finish feature/v >/dev/null 2>&1
merge_on_origin squash develop feature/v
out="$(fin finish feature/v 2>&1)"
check "mode pr: a squash-merged PR refuses and keeps the branch" 'echo "$out" | grep -q exit=2 && echo "$out" | grep -q "squashed or rebased" && ! gone feature/v'
fresh; reset_gh; wt u 2>/dev/null; git config gitflow.feature.merge pr
out="$(GH_STUB_EXIT=1 fin finish feature/u 2>&1)"
check "mode pr: gh unusable refuses before pushing" 'echo "$out" | grep -q exit=2 && ! git ls-remote --exit-code origin refs/heads/feature/u >/dev/null && ! gone feature/u'
fresh; wt y 2>/dev/null; git config gitflow.feature.merge sideways
check "an unknown merge mode refuses" 'fin finish feature/y 2>&1 | grep -q "expected pr, push or local"'

echo "$failures failure(s)"
[ "$failures" = 0 ]
