#!/usr/bin/env bash
# Behaviour tests for scripts/prune-merged.sh: one PASS/FAIL line per case,
# exit 1 if any case fails. Run from anywhere: bash tests/prune-merged.sh
#
# The rule under test: a local branch is deleted only when origin's long-lived
# branches already hold its work AND its tip sits on no long-lived branch's
# first-parent line (a branch that never got its own commits looks "merged"
# but is just new). Everything else is kept.
source "$(dirname "$0")/lib.sh"
W=.claude/worktrees

prune() { bash "$REPO/scripts/prune-merged.sh" "$@"; echo "exit=$?"; }
# session <dir>: feed the hook the JSON Claude Code sends at SessionStart.
session() { printf '{"cwd": "%s", "source": "startup"}' "$1" | bash "$REPO/scripts/prune-merged.sh" session; echo "exit=$?"; }
gone() { ! git show-ref -q --verify "refs/heads/$1"; }
kept() { git show-ref -q --verify "refs/heads/$1"; }
# merge_no_ff <branch>: merge <branch> into the current branch, gitflow style.
merge_no_ff() { git merge -q --no-ff --no-edit "$1"; }

# --- the scene ------------------------------------------------------------------
# 1. feature/done: own commit, merged into develop, pushed      -> deleted
# 2. feature/busy: same, but checked out in a worktree          -> kept, reported
# 3. a release on main, merged back into develop, both pushed
# 4. feature/fresh, feature/fresh-main: no commits of their own -> kept
#    (fresh-main sits on main, which develop holds via the back-merge)
# 5. feature/wip: own commit, never merged                      -> kept
# 6. feature/unpushed: merged into local develop only           -> kept
# 7. dev: a long-lived name, even pointing at merged work       -> kept
fresh
git switch -q -c feature/done develop && commit "feat: done"
git config gitflow.branch.feature/done.base develop
git switch -q develop && merge_no_ff feature/done
git worktree add -q $W/busy -b feature/busy develop && git -C $W/busy commit -q --allow-empty -m busy
merge_no_ff feature/busy
git switch -q main && commit "release" && git switch -q develop && merge_no_ff main
# dev: merged work of its own, off every other first-parent line.
git switch -q -c feature/old develop && commit "feat: old" && git switch -q develop && merge_no_ff feature/old
git branch -m feature/old dev
git push -q origin main develop
git branch feature/fresh develop; git branch feature/fresh-main main
git switch -q -c feature/wip develop && commit "wip" && git switch -q develop
git switch -q -c feature/unpushed develop && commit "unpushed" && git switch -q develop && merge_no_ff feature/unpushed

refs_before="$(git for-each-ref refs/heads)"
out="$(prune plan 2>&1)"
check "plan names the merged branch and where its work is" 'echo "$out" | grep -q "plan: delete feature/done (in origin/develop)"'
check "plan changes nothing" '[ "$(git for-each-ref refs/heads)" = "$refs_before" ]'

out="$(prune run 2>&1)"
check "run deletes the merged, pushed branch" 'gone feature/done && echo "$out" | grep -q "deleted feature/done"'
check "run clears the deleted branch's recorded base" '! git config --get gitflow.branch.feature/done.base >/dev/null'
check "a merged branch checked out in a worktree is kept and reported" \
  'kept feature/busy && [ -d $W/busy ] && echo "$out" | grep -q "feature/busy is merged but checked out"'
check "a branch with no commits of its own is kept" 'kept feature/fresh'
check "a branch cut from main is kept, though develop holds main" 'kept feature/fresh-main'
check "an unmerged branch is kept" 'kept feature/wip'
check "a branch merged only locally (not on origin) is kept" 'kept feature/unpushed'
check "long-lived names are never deleted" 'kept dev && kept main && kept develop'
check "run exits 0" 'echo "$out" | grep -q exit=0'

# --- the SessionStart hook --------------------------------------------------------
# GitHub merges a pushed branch; only a fetch can tell this clone. The hook
# fetches, deletes, and says so in one systemMessage.
fresh
git switch -q -c feature/pr develop && commit "feat: pr" && git push -q origin feature/pr && git switch -q develop
merge_on_origin merge develop feature/pr
out="$(session "$PWD")"
check "session fetches first, then deletes what GitHub merged" \
  'gone feature/pr && echo "$out" | grep -q "\"systemMessage\":\"gitflow: deleted feature/pr"'

git switch -q -c feature/off develop && commit "feat: off" && git push -q origin feature/off && git switch -q develop
merge_on_origin merge develop feature/off
git config gitflow.prune false
out="$(session "$PWD")"
check "gitflow.prune=false: the session hook does nothing" 'kept feature/off && [ "$out" = exit=0 ]'
git config --unset gitflow.prune
out="$(CC_GITFLOW_REGULATOR_PRUNE=off session "$PWD")"
check "CC_GITFLOW_REGULATOR_PRUNE=off: the session hook does nothing" 'kept feature/off && [ "$out" = exit=0 ]'

out="$(session "$PWD")"
out="$(session "$PWD")"
check "nothing to do: the session hook prints nothing" '[ "$out" = exit=0 ]'

# A branch name git allows but JSON must escape: the message stays valid JSON.
# Windows can't hold the name (refs are files; " is not a legal file name
# character there), so the case runs where it can: Linux CI.
if git branch 'feature/say"hi' develop 2>/dev/null; then
  git switch -q 'feature/say"hi' && commit "feat: quote" && git push -q origin 'feature/say"hi' && git switch -q develop
  merge_on_origin merge develop 'feature/say"hi'
  out="$(session "$PWD")"
  check "a quote in a branch name: still one valid JSON message" \
    'gone "feature/say\"hi" && printf "%s" "${out%exit=0}" | python3 -c "import json,sys; json.loads(sys.stdin.read())"'
else
  echo "SKIP  a quote in a branch name (this platform can't create one)"
fi

# gitflow.branch.develop names the integration branch: it is protected, and
# origin's copy of it counts as holding merged work.
git config gitflow.branch.develop trunk
git switch -q -c trunk develop && git push -q origin trunk
git switch -q -c feature/t trunk && commit "feat: t" && git switch -q trunk && merge_no_ff feature/t && git push -q origin trunk
git switch -q develop
out="$(prune run 2>&1)"
check "gitflow.branch.develop=trunk: merged into origin/trunk is deleted, trunk kept" \
  'gone feature/t && kept trunk && echo "$out" | grep -q "deleted feature/t (its work is in origin/trunk)"'
git config --unset gitflow.branch.develop

# An unreachable origin (offline, moved repo): the fetch fails, the hook still
# finishes quietly with exit 0 instead of breaking the session start.
real_origin="$(git remote get-url origin)"
git remote set-url origin "$SCRATCH/nowhere.git"
out="$(session "$PWD")"
check "an unreachable origin: the session hook still exits 0" 'echo "$out" | grep -q exit=0'
git remote set-url origin "$real_origin"

mkdir -p "$SCRATCH/not-a-repo"
out="$(session "$SCRATCH/not-a-repo")"
check "outside a git repo: silent, exit 0" '[ "$out" = exit=0 ]'

git remote remove origin
out="$(session "$PWD")"
check "no origin: silent, exit 0" '[ "$out" = exit=0 ]'

echo "$failures failure(s)"; [ "$failures" = 0 ]
