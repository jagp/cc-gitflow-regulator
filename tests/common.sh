#!/usr/bin/env bash
# Behaviour tests for scripts/common.sh, the library the start/finish scripts
# share: test detection and running, on/off switches, branch resolution.
# One PASS/FAIL line per case, exit 1 on any failure.
# Run from anywhere: bash tests/common.sh
source "$(dirname "$0")/lib.sh"
# lib <function> [args...]: source common.sh in a subshell (it resolves the
# repo from the current folder) and call one of its functions.
lib() { ( source "$REPO/scripts/common.sh" && "$@" ); }

# --- shell-script suites ---------------------------------------------------------------------
# a.sh and b.sh are tests; helper.sh is only ever sourced by b.sh, so it is not.
fresh; mkdir tests
printf '#!/usr/bin/env bash\nexit 0\n' > tests/a.sh
printf '#!/usr/bin/env bash\nsource "$(dirname "$0")/helper.sh"\ntouch ran-b\n' > tests/b.sh
printf 'helper_loaded=1\n' > tests/helper.sh
suites="$(lib shell_test_suites .)"
check "shell suites found, sourced helper skipped" \
  '[ "$suites" = "$(printf "tests/a.sh\ntests/b.sh")" ]'
out="$(lib detect_tests .)"
check "detect_tests reports shell suites through run-tests.sh" \
  'echo "$out" | grep -q "run-tests.sh" && echo "$out" | grep -qF "(from tests/*.sh shell suites)"'

git config gitflow.testCommand true
out="$(lib detect_tests .)"
check "gitflow.testCommand replaces detection" '[ "$out" = "test: true   (from git config gitflow.testCommand)" ]'
git config --unset gitflow.testCommand

# --- running them ----------------------------------------------------------------------------
printf '#!/usr/bin/env bash\nexit 1\n' > tests/a.sh
out="$(lib run_tests . 2>&1)"; code=$?
check "a failing suite fails the run, the others still run" \
  '[ "$code" = 1 ] && [ -e ran-b ] && echo "$out" | grep -q "tests: FAILED (tests/a.sh)"'
rm -f ran-b; printf '#!/usr/bin/env bash\nexit 0\n' > tests/a.sh
out="$(lib run_tests . 2>&1)"; code=$?
check "all suites passing passes" '[ "$code" = 0 ] && echo "$out" | grep -q "tests: passed"'

fresh
out="$(lib run_tests . 2>&1)"; code=$?
check "no suite found warns and passes" '[ "$code" = 0 ] && echo "$out" | grep -q "warn: no tests ran"'

# --- switches --------------------------------------------------------------------------------
check "switch defaults to on" 'lib switch_on TEST_SWITCH test.switch'
check "env 0 turns it off" '! TEST_SWITCH=0 lib switch_on TEST_SWITCH test.switch'
git config test.switch false
check "git config false turns it off" '! lib switch_on TEST_SWITCH test.switch'
check "env yes wins over git config" 'TEST_SWITCH=yes lib switch_on TEST_SWITCH test.switch'
git config test.switch off
check "git config off turns it off" '! lib switch_on TEST_SWITCH test.switch'

# --- branches --------------------------------------------------------------------------------
check "production branch is main" '[ "$(lib production_branch)" = main ]'
check "integration branch is develop" '[ "$(lib integration_branch)" = develop ]'
git branch -m main master
check "production branch falls back to master" '[ "$(lib production_branch)" = master ]'
git branch trunk; git config gitflow.branch.master trunk
check "gitflow.branch.master names the production branch" '[ "$(lib production_branch)" = trunk ]'
git config gitflow.branch.develop trunk
check "gitflow.branch.develop names the integration branch" '[ "$(lib integration_branch)" = trunk ]'

echo "$failures failure(s)"; [ "$failures" = 0 ]
