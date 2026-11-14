#!/usr/bin/env bash
# Behaviour tests for scripts/start-feature.sh: one PASS/FAIL line per case,
# exit 1 if any case fails. Run from anywhere: bash tests/start-feature.sh
source "$(dirname "$0")/lib.sh"
start() { bash "$REPO/scripts/start-feature.sh" "$@"; echo "exit=$?"; }

# a repo with only main: no gitflow base yet
fresh; git switch -q main; git branch -D develop -q; git push -q origin --delete develop 2>/dev/null
git update-ref -d refs/remotes/origin/develop
out="$(start plan "Add Login Form" 2>&1)"
check "plan without develop explains --create-base" 'echo "$out" | grep -q "base MISSING" && echo "$out" | grep -q exit=0'
out="$(start start "Add Login Form" 2>&1)"
check "start without develop refuses" 'echo "$out" | grep -q exit=2 && ! git show-ref -q --verify refs/heads/develop'
out="$(start start "Add Login Form" --create-base 2>&1)"
check "--create-base makes develop, branches off it, switches to it" \
  'git show-ref -q --verify refs/heads/develop && [ "$(git branch --show-current)" = feature/add-login-form ]'
check "records the base for finish" '[ "$(git config --get gitflow.branch.feature/add-login-form.base)" = develop ]'
out="$(start start "add login form" 2>&1)"
check "an existing branch is refused by the guard" 'echo "$out" | grep -q "already exists locally — check it out instead" && echo "$out" | grep -q exit=2'

# a branch that exists only on origin: git alone would happily create a second one
fresh; git switch -q develop; git push -q origin develop:refs/heads/feature/theirs
out="$(start start theirs 2>&1)"
check "a branch that exists only on origin is refused" \
  'echo "$out" | grep -q "already exists on origin" && ! git show-ref -q --verify refs/heads/feature/theirs'

# dirty tracked files are refused (that is /feature-dirty's job)
fresh; git switch -q develop; echo x > tracked.txt; git add tracked.txt; git commit -q -m t; echo y >> tracked.txt
out="$(start start other 2>&1)"
check "uncommitted tracked changes are refused" 'echo "$out" | grep -q exit=2 && ! git show-ref -q --verify refs/heads/feature/other'

# develop behind origin is fast-forwarded before branching
fresh; git clone -q ../origin.git ../other 2>/dev/null
(cd ../other && git switch -q develop && git commit -q --allow-empty -m ahead && git push -q)
start start ff >/dev/null 2>&1
check "develop behind origin is fast-forwarded first" '[ "$(git rev-parse develop)" = "$(git -C ../origin.git rev-parse develop)" ]'

# a repo with no develop at all that names main as its integration branch
fresh; git switch -q main; git branch -D develop -q; git push -q origin --delete develop 2>/dev/null
git update-ref -d refs/remotes/origin/develop; git config gitflow.branch.develop main
git commit -q --allow-empty -m "main moves"
out="$(start start onmain 2>&1)"
check "gitflow.branch.develop=main: branches off main, no --create-base needed" \
  'echo "$out" | grep -q exit=0 && [ "$(git branch --show-current)" = feature/onmain ] && [ "$(git merge-base HEAD main)" = "$(git rev-parse main)" ] && ! git show-ref -q --verify refs/heads/develop'

echo "$failures failure(s)"
[ "$failures" = 0 ]
