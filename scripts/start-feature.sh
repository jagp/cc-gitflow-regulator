#!/usr/bin/env bash
# cc-gitflow-regulator start-feature — deterministic "Start feature" (the
# counterpart of finish-feature.sh).
#
# Modes (wired to the /start-feature command in commands/start-feature.md):
#   plan  <name> [--create-base]
#                 read-only: resolve the branch name, base branch, base sync
#                 state, open work branches and test suite, and print exactly
#                 what `start` would do. Makes NO changes (no fetch, no refs).
#   start <name> [--create-base]
#                 fetch origin, fast-forward the base if it is strictly behind
#                 origin, then create <prefix><name> from the base and switch
#                 the CURRENT checkout to it. Never pushes.
#
# The process, step by step:
#   1. Turn <name> into a git-safe slug and prepend the feature prefix.
#   2. Refuse if the branch already exists locally or on origin (that is
#      existing work: check it out instead of starting over).
#   3. Refuse if tracked files have uncommitted changes. Carrying dirty work
#      onto a new branch is /feature-dirty's job, not this command's.
#   4. Resolve the gitflow base (same rules as finish-feature.sh).
#      If the repo has no develop/dev yet, --create-base creates `develop`
#      from the trunk (main/master). That is the one-time GitFlow bootstrap
#      the /finish-feature merge needs; it is local only.
#   5. Sync the base with origin (fast-forward only; anything else is
#      reported, never forced).
#   6. Create the branch from the base, switch to it, and record the base in
#      git config (gitflow.branch.<branch>.base) for finish-feature.sh.
#   7. Report the test command(s) found, so the caller can run a baseline
#      before any changes are made.
#
# Exit codes: 0 ok   2 refused/preflight failed
#
# Configuration: CC_GITFLOW_REGULATOR_PREFIX, CC_GITFLOW_REGULATOR_BASE (same
# meaning as in finish-feature.sh and the hooks).
set -u

mode="${1:-}"; shift 2>/dev/null || true
PREFIX="${CC_GITFLOW_REGULATOR_PREFIX:-feature/}"
BASE_OVERRIDE="${CC_GITFLOW_REGULATOR_BASE:-}"

name_arg=""; create_base=0
for a in "$@"; do
  case "$a" in
    --create-base) create_base=1 ;;
    --*) echo "error: unknown flag $a" >&2; exit 2 ;;
    *) name_arg="${name_arg:+$name_arg }$a" ;;   # multi-word names are joined, then slugged
  esac
done

case "$mode" in plan|start) ;; *)
  echo "usage: start-feature.sh plan|start <name> [--create-base]" >&2
  exit 2 ;;
esac

# --- repo roots ---------------------------------------------------------------
# common.sh sets root (the main clone: shared refs live there, even when invoked
# in a worktree) and here (the checkout we are standing in; the new branch is
# switched to HERE), and provides fail / G / has_ref / detect_tests.
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

# --- 1. branch name ------------------------------------------------------------
# Lowercase, drop a prefix the user typed themselves (feature/x -> x), then
# collapse every run of non-alphanumerics into one hyphen and trim the ends.
# Same slug rules as /feature-dirty, so both commands name branches alike.
slug="$(printf '%s' "$name_arg" | tr '[:upper:]' '[:lower:]')"
slug="${slug#"$PREFIX"}"; slug="${slug#feature/}"
slug="$(printf '%s' "$slug" | sed -E 's/[^a-z0-9]+/-/g; s/^-+//; s/-+$//')"
[ -n "$slug" ] || fail "provide a feature name, e.g. /start-feature add login form"
branch="${PREFIX}${slug}"
git check-ref-format --branch "$branch" >/dev/null 2>&1 || fail "invalid branch name: $branch"

# --- 2. fetch (start only), then refuse existing work ----------------------------
# plan stays read-only, so it judges origin by the remote-tracking refs it
# already has; start refreshes them first so the check is current.
has_origin=0; G remote get-url origin >/dev/null 2>&1 && has_origin=1
if [ "$mode" = "start" ] && [ "$has_origin" = "1" ]; then
  G fetch -q origin 2>/dev/null || echo "warn: fetch from origin failed (offline?) — using local refs as they are"
fi
has_ref "refs/heads/$branch" \
  && fail "$branch already exists locally — check it out instead (git switch $branch)"
has_ref "refs/remotes/origin/$branch" \
  && fail "$branch already exists on origin — someone started it; check it out instead (git switch $branch)"

# --- 3. clean tracked tree -------------------------------------------------------
# Untracked files are ignored on purpose: they ride along a branch switch
# harmlessly (e.g. a local .claude/ folder) and would block every run.
if [ -n "$(git -C "$here" status --porcelain --untracked-files=no)" ]; then
  fail "uncommitted changes in $here — commit or stash them, or use /feature-dirty to carry them onto the new branch"
fi

# --- 4. base branch --------------------------------------------------------------
# Override first, else the first of develop/dev (matches finish-feature.sh).
# Neither exists: find the trunk so --create-base can bootstrap `develop`.
base=""; base_created=0
if [ -n "$BASE_OVERRIDE" ]; then
  has_ref "refs/heads/$BASE_OVERRIDE" \
    || fail "CC_GITFLOW_REGULATOR_BASE=$BASE_OVERRIDE is not a local branch"
  base="$BASE_OVERRIDE"
else
  for b in develop dev; do
    if has_ref "refs/heads/$b"; then base="$b"; break; fi
  done
fi
if [ -z "$base" ]; then
  # origin/develop exists but was never checked out locally: adopt it rather
  # than inventing a second, unrelated develop from the trunk.
  for b in develop dev; do
    if has_ref "refs/remotes/origin/$b"; then
      if [ "$mode" = "start" ]; then
        G branch --track "$b" "origin/$b" >/dev/null 2>&1 || fail "could not create local $b from origin/$b"
        echo "ok: created local $b from origin/$b"
      else
        echo "plan: base $b exists only on origin — start will create the local branch from origin/$b"
      fi
      base="$b"; break
    fi
  done
fi
if [ -z "$base" ]; then
  trunk=""
  for t in main master; do
    if has_ref "refs/heads/$t"; then trunk="$t"; break; fi
  done
  [ -n "$trunk" ] || fail "no base branch (develop/dev) and no trunk (main/master) — set CC_GITFLOW_REGULATOR_BASE"
  if [ "$create_base" = "1" ]; then
    if [ "$mode" = "start" ]; then
      G branch develop "$trunk" || fail "could not create develop from $trunk"
      echo "ok: created develop from $trunk (local only — push it when you're ready)"
    else
      echo "plan: base MISSING — start --create-base will create develop from $trunk (local only)"
    fi
    base="develop"; base_created=1
  else
    echo "plan: base MISSING — this repo has no develop/dev branch"
    echo "plan:   rerun with --create-base to create develop from $trunk (local only)"
    [ "$mode" = "start" ] && fail "no gitflow base branch — rerun with --create-base, or set CC_GITFLOW_REGULATOR_BASE"
  fi
fi

# --- 5. sync base with origin ------------------------------------------------------
# Only a strict fast-forward is applied. Ahead or diverged is reported and the
# local base is used as-is: reconciling it is the user's call, not ours.
# A base that is checked out somewhere can't be moved with update-ref, so:
#   checked out HERE      -> merge --ff-only (tree is clean, step 3)
#   checked out ELSEWHERE -> warn, use local
base_ref="$base"
if [ "$base_created" = "0" ] && [ "$has_origin" = "1" ] && [ -n "$base" ] \
   && has_ref "refs/remotes/origin/$base"; then
  behind="$(G rev-list --count "$base..origin/$base")"
  ahead="$(G rev-list --count "origin/$base..$base")"
  if [ "$behind" = "0" ] && [ "$ahead" = "0" ]; then
    echo "plan: base $base is up to date with origin/$base"
  elif [ "$behind" = "0" ]; then
    echo "plan: base $base is $ahead commit(s) ahead of origin/$base (unpushed) — branching from local $base"
  elif [ "$ahead" != "0" ]; then
    echo "warn: $base has diverged from origin/$base ($ahead ahead, $behind behind) — branching from local $base; reconcile it separately"
  else
    checked_out_at="$(G worktree list --porcelain | awk -v ref="branch refs/heads/$base" '/^worktree /{wt=substr($0,10)} $0==ref{print wt}')"
    if [ "$mode" = "plan" ]; then
      echo "plan: base $base is $behind commit(s) behind origin/$base — start will fast-forward it"
    elif [ -z "$checked_out_at" ]; then
      G update-ref "refs/heads/$base" "refs/remotes/origin/$base" || fail "could not fast-forward $base"
      echo "ok: fast-forwarded $base by $behind commit(s) from origin/$base"
    elif [ "$(git -C "$checked_out_at" rev-parse --show-toplevel)" = "$here" ]; then
      git -C "$here" merge -q --ff-only "origin/$base" || fail "could not fast-forward $base"
      echo "ok: fast-forwarded $base by $behind commit(s) from origin/$base"
    else
      echo "warn: $base is $behind behind origin/$base but checked out at $checked_out_at — branching from local $base"
    fi
  fi
fi

# --- open work branches --------------------------------------------------------------
# Shown so a duplicate or forgotten branch for the same idea gets noticed
# before a second one is started.
open="$(G for-each-ref --format='%(refname:short)' \
  "refs/heads/${PREFIX}" refs/heads/feature refs/heads/bugfix refs/heads/hotfix | sort -u | paste -sd ' ' -)"
echo "plan: open work branches: ${open:-(none)}"

# --- 6. create + switch ------------------------------------------------------------------
if [ "$mode" = "plan" ]; then
  echo "plan: start will create $branch from ${base:-develop (once --create-base makes it)} and switch $here to it"
else
  git -C "$here" switch -q -c "$branch" "$base_ref" || fail "could not create $branch from $base"
  echo "ok: created $branch from $base at $(git -C "$here" rev-parse --short HEAD) — now checked out in $here (not pushed)"
  # Record the base so finish-feature.sh merges back into it rather than
  # guessing. Git itself never remembers what a branch was created from.
  # The key is git-flow's own (gitflow.branch.<branch>.base), so git-flow
  # tooling reads the same record.
  G config "gitflow.branch.$branch.base" "$base"
  echo "ok: recorded base $base for $branch (git config gitflow.branch.$branch.base)"
fi

# --- 7. test suite detection ----------------------------------------------------------------
# Report every recognized runner (common.sh detect_tests); the caller runs the
# first as a baseline.
detect_tests "$here"
exit 0
