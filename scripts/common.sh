# cc-gitflow-regulator common — shared by the start/finish scripts. Sourced,
# never run on its own. Sourcing it from inside a git repo sets:
#   root            the main clone (shared refs live there, even in a worktree)
#   here            the checkout the caller is standing in
#   PLUGIN_SCRIPTS  this scripts/ folder, so printed commands can point back here
#
# Functions, roughly in the order a start/finish script needs them:
#   fail <message>             print "error: <message>" and exit 2 (refused)
#   G <git args...>            git, run against the main clone (refs, config)
#   W <git args...>            git, run in the current checkout (files, commits)
#   checked_out_at <branch>    the checkout folder that has <branch>, if any
#   same_folder <a> <b>        do two paths (C:/x vs /c/x) name one folder?
#   has_ref <full ref>         does refs/heads/x, refs/tags/x, ... exist?
#   switch_on <ENV> <git.key>  on/off settings: env var first, then git config,
#                              then on. 0/false/off/no (any case) mean off.
#   production_branch          gitflow.branch.master if set, else main, else master
#   integration_branch         CC_GITFLOW_REGULATOR_BASE if set, else develop, else dev
#   require_clean_tree <dir>   refuse when tracked files have uncommitted changes
#   shell_test_suites <dir>    the *.sh test scripts in tests/ or test/
#   detect_tests <dir>         one "test: <command>   (from <signal>)" line per runner
#   run_tests <dir>            run them; 0 = passed or none found, 1 = failed

fail() { echo "error: $*" >&2; exit 2; }

PLUGIN_SCRIPTS="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
common_dir="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
  || fail "not inside a git repository"
root="${common_dir%/.git}"
here="$(git rev-parse --show-toplevel)"
# MSYS_NO_PATHCONV: Git Bash on Windows rewrites arguments that look like
# paths, so "release/1.0.0:dir/file.json" would reach git as a Windows path
# list. Off for git calls only; no-op everywhere else.
G() { MSYS_NO_PATHCONV=1 git -C "$root" "$@"; }
# W: git in the checkout the user is standing in (a worktree, possibly).
# Anything that touches files — add, commit, merge, switch — goes through W,
# so it lands in that checkout and never in the main clone's.
W() { MSYS_NO_PATHCONV=1 git -C "$here" "$@"; }
has_ref() { G show-ref --verify -q "$1"; }

# checked_out_at <branch>: the folder of the checkout (main clone or any
# worktree) that has <branch> checked out; empty when none does.
checked_out_at() {
  G worktree list --porcelain | awk -v wanted="branch refs/heads/$1" '
    /^worktree / { folder = substr($0, 10) }
    $0 == wanted { print folder; exit }'
}

# same_folder <a> <b>: do two paths name the same folder? (git may print
# C:/x where the shell says /c/x, so compare them resolved.)
same_folder() { [ "$(cd "$1" 2>/dev/null && pwd -P)" = "$(cd "$2" 2>/dev/null && pwd -P)" ]; }

# switch_on: is an on-by-default setting on?
#   1. the env var, when set, decides (it is the "everywhere" switch)
#   2. else the git config key decides (the "this repo only" switch)
#   3. else on
switch_on() {
  local env_name="$1" config_key="$2" value
  value="${!env_name:-}"
  [ -n "$value" ] || value="$(G config --get "$config_key" 2>/dev/null || true)"
  case "$(printf '%s' "$value" | tr '[:upper:]' '[:lower:]')" in
    0|false|off|no) return 1 ;;
    *) return 0 ;;
  esac
}

# production_branch: where releases land and get tagged. git-flow's own
# setting (gitflow.branch.master) wins when it names a branch that exists.
production_branch() {
  local configured candidate
  configured="$(G config --get gitflow.branch.master 2>/dev/null || true)"
  for candidate in $configured main master; do
    if has_ref "refs/heads/$candidate"; then echo "$candidate"; return 0; fi
  done
}

# integration_branch: where features meet (develop). Same order as
# start-feature.sh and finish-feature.sh use.
integration_branch() {
  local candidate
  for candidate in ${CC_GITFLOW_REGULATOR_BASE:-} develop dev; do
    if has_ref "refs/heads/$candidate"; then echo "$candidate"; return 0; fi
  done
}

# require_clean_tree: untracked files are allowed on purpose (a local .claude/
# folder rides along harmlessly); tracked changes would be lost or carried.
require_clean_tree() {
  [ -z "$(git -C "$1" status --porcelain --untracked-files=no)" ] \
    || fail "uncommitted changes in $1 — commit or stash them first"
}

# shell_test_suites: plain shell-script test suites, the kind this plugin uses.
#   1. every *.sh directly in tests/ or test/
#   2. minus helpers: a file another script there sources ("source x.sh" or
#      ". x.sh") is shared setup, not a test of its own
# Prints paths relative to <dir>, one per line, sorted.
shell_test_suites() {
  local dir="$1" folder script name
  for folder in tests test; do
    [ -d "$dir/$folder" ] || continue
    for script in "$dir/$folder"/*.sh; do
      [ -f "$script" ] || continue
      name="$(basename "$script")"
      # Sourced by a sibling? Then it is a helper — skip it.
      if grep -qE "^[[:space:]]*(source|\.)[[:space:]].*${name//./\\.}" \
           $(ls "$dir/$folder"/*.sh | grep -vF "/$name") /dev/null 2>/dev/null; then
        continue
      fi
      echo "$folder/$name"
    done
  done
}

# detect_tests: name every test runner found, most specific signal first.
#   1. git config gitflow.testCommand, if set, is the only answer
#   2. package.json scripts.test, pytest config, Cargo.toml, go.mod, a
#      Makefile test target, *.bats files, plain shell-script suites
#   3. nothing: say whether a tests/ folder exists, so a human can look
detect_tests() {
  local dir="$1" configured package runner folder found=0
  emit() { echo "test: $1   (from $2)"; found=1; }
  configured="$(G config --get gitflow.testCommand 2>/dev/null || true)"
  if [ -n "$configured" ]; then emit "$configured" "git config gitflow.testCommand"; return 0; fi
  package="$dir/package.json"
  if [ -f "$package" ] && grep -Eq '"test"[[:space:]]*:' "$package" && ! grep -q 'no test specified' "$package"; then
    runner=npm                                                   # `run test` works for all four runners
    [ -f "$dir/pnpm-lock.yaml" ] && runner=pnpm
    [ -f "$dir/yarn.lock" ] && runner=yarn
    { [ -f "$dir/bun.lockb" ] || [ -f "$dir/bun.lock" ]; } && runner=bun
    emit "$runner run test" "package.json scripts.test"
  fi
  if [ -f "$dir/pytest.ini" ] || [ -f "$dir/conftest.py" ] \
     || grep -qs '^\[tool\.pytest' "$dir/pyproject.toml" \
     || grep -qs '^\[tool:pytest\]' "$dir/setup.cfg" \
     || grep -qs '^\[pytest\]' "$dir/tox.ini"; then
    emit "pytest" "pytest config"
  fi
  [ -f "$dir/Cargo.toml" ] && emit "cargo test" "Cargo.toml"
  [ -f "$dir/go.mod" ] && emit "go test ./..." "go.mod"
  grep -qs '^test:' "$dir/Makefile" && emit "make test" "Makefile test target"
  for folder in tests test; do
    if ls "$dir/$folder"/*.bats >/dev/null 2>&1; then emit "bats $folder" "$folder/*.bats"; fi
  done
  [ -n "$(shell_test_suites "$dir")" ] \
    && emit "bash \"$PLUGIN_SCRIPTS/run-tests.sh\"" "tests/*.sh shell suites"
  if [ "$found" = "0" ]; then
    if [ -d "$dir/tests" ] || [ -d "$dir/test" ]; then
      echo "test: a tests/ or test/ folder exists but no recognized runner — inspect it manually"
    else
      echo "test: none found"
    fi
  fi
  return 0
}

# run_tests: run what detect_tests found, from <dir>.
#   - gitflow.testCommand set: run just that
#   - shell suites: run each with bash, ALL of them even after one fails, so
#     the report names every failing suite
#   - other runners: run each detected command
#   - nothing found: warn and pass (a repo without tests can still release)
# Prints "tests: passed" or "tests: FAILED (<what failed>)".
run_tests() {
  local dir="$1" configured failed="" line command suite ran=0
  configured="$(G config --get gitflow.testCommand 2>/dev/null || true)"
  if [ -n "$configured" ]; then
    ran=1; (cd "$dir" && eval "$configured") || failed="$configured"
  else
    while IFS= read -r line; do
      case "$line" in "test: "*"   (from "*) ;; *) continue ;; esac
      command="${line#test: }"; command="${command%%   (from *}"
      ran=1
      case "$command" in
        *run-tests.sh*)                                          # shell suites, one by one
          for suite in $(shell_test_suites "$dir"); do
            (cd "$dir" && bash "$suite" >/dev/null 2>&1) || failed="${failed:+$failed, }$suite"
          done ;;
        *) (cd "$dir" && eval "$command") || failed="${failed:+$failed, }$command" ;;
      esac
    done <<< "$(detect_tests "$dir")"
  fi
  if [ "$ran" = "0" ]; then echo "warn: no tests ran — no test suite found"; return 0; fi
  if [ -n "$failed" ]; then echo "tests: FAILED ($failed)"; return 1; fi
  echo "tests: passed"
}
