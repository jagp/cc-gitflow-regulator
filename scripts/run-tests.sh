#!/usr/bin/env bash
# cc-gitflow-regulator run-tests — run this repo's test suites the way the
# start/finish scripts do (scripts/common.sh run_tests). Printed by
# detect_tests as the command for plain shell-script suites.
# Exit codes: 0 passed or no suite found   1 a suite failed   2 not a git repo
set -u
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
run_tests "$here"
