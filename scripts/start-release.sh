#!/usr/bin/env bash
# cc-gitflow-regulator start-release — deterministic "Start release" and
# "Start hotfix" (the counterpart of finish-release.sh).
#
# Usage: start-release.sh release|hotfix plan|start [X.Y.Z]
#   plan   read-only: work out the version and print exactly what start does
#   start  create <type>/<version>, bump the manifests, draft the changelog
#          entry, commit that, and run the tests as a baseline. Never pushes.
#
# The two types differ only in where they start and how the version is picked:
#   release  from the integration branch (develop); version suggested from
#            the Conventional Commits since the last vX.Y.Z tag
#   hotfix   from the production branch (main); version = next patch
#
# The process, step by step:
#   1. Pick the version: the one given (must be X.Y.Z), else the suggestion.
#   2. Refuse: uncommitted tracked changes; another <type>/* still open
#      (locally or on origin); a v<version> tag already existing anywhere.
#   3. release only: fetch, fast-forward develop if strictly behind origin;
#      warn about commits on main that develop lacks (they conflict at
#      finish) and about features not yet merged (they miss this release).
#   4. Create <type>/<version> and switch the current checkout to it.
#   5. Bump the manifests and draft the changelog entry (release: from the
#      commits; hotfix: a bare heading), then commit if anything changed.
#   6. Run the tests as a baseline: information, never a gate.
#
# Exit codes: 0 ok   2 refused
# Configuration: CC_GITFLOW_REGULATOR_BASE, CC_GITFLOW_REGULATOR_PREFIX,
#   CC_GITFLOW_REGULATOR_CHANGELOG / git config gitflow.release.changelog
set -u

branch_type="${1:-}"; mode="${2:-}"; given_version="${3:-}"
case "$branch_type:$mode" in release:plan|release:start|hotfix:plan|hotfix:start) ;; *)
  echo "usage: start-release.sh release|hotfix plan|start [X.Y.Z]" >&2; exit 2 ;;
esac
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/release-lib.sh"
FEATURE_PREFIX="${CC_GITFLOW_REGULATOR_PREFIX:-feature/}"

integration="$(integration_branch)"; production="$(production_branch)"
[ -n "$integration" ] || fail "no integration branch (develop/dev) — set CC_GITFLOW_REGULATOR_BASE"
[ -n "$production" ] || fail "no production branch (main/master) — set git config gitflow.branch.master"
# Where the new branch starts: releases cut develop, hotfixes patch main.
if [ "$branch_type" = release ]; then start_point="$integration"; else start_point="$production"; fi

# --- 1. version ------------------------------------------------------------------------------
# The last release: the newest vX.Y.Z tag reachable from the start point, else
# the version the manifests declare, else 0.0.0.
last_tag="$(last_release_tag "$start_point")"
last_version="${last_tag#v}"
[ -n "$last_version" ] || last_version="$(current_manifest_version)"
[ -n "$last_version" ] || last_version="0.0.0"
# Only a suggestion needs a usable current version; a named one doesn't
# (e.g. a manifest still saying 0.4.0-beta.1 while the user names 0.4.0).
if ! valid_version "$last_version"; then
  [ -n "$given_version" ] || fail "the current version '$last_version' is not X.Y.Z — name the new version explicitly"
  last_version="0.0.0"
fi

if [ "$branch_type" = release ]; then
  # Classify what develop gained since the last tag (all of develop if none).
  classify_commits "${last_tag:+$last_tag..}$integration"
  suggestion="$(suggest_version "$last_version")"
else
  # A hotfix has no commits yet to judge by: always the next patch.
  breaking_count=0 feat_count=0
  suggestion="$(suggest_version "$last_version")"
fi

if [ -n "$given_version" ]; then
  valid_version "$given_version" || fail "invalid version '$given_version' — expected X.Y.Z (e.g. 1.4.0)"
  version="$given_version"
  echo "plan: version $version (given; last release ${last_tag:-$last_version})"
  if [ "$branch_type" = release ] && understates "$last_version" "$version"; then
    echo "warn: $version understates the commits (suggested $suggestion) — breaking changes or features would ship in a smaller bump"
  fi
else
  version="$suggestion"
  if [ "$branch_type" = release ]; then
    echo "plan: version $version (suggested from ${last_tag:-$last_version}: $breaking_count breaking, $feat_count feat, $fix_count fix, $other_count other, $unclassified_count unclassified)"
    # The commits that drove the bump, so the user can judge the suggestion.
    printf '%s%s%s' "$breaking_subjects" "$feat_subjects" "$fix_subjects" | sed '/^$/d; s/^/plan:   - /'
  else
    echo "plan: version $version (hotfix: next patch after ${last_tag:-$last_version})"
  fi
fi
branch="$branch_type/$version"

# --- 2. refusals -----------------------------------------------------------------------------
require_clean_tree "$here"
has_origin=0; G remote get-url origin >/dev/null 2>&1 && has_origin=1
# Open branches: local ones, plus origin's asked live (ls-remote), so one a
# teammate pushed counts even before it was fetched.
open_branch="$(G for-each-ref --format='%(refname:short)' "refs/heads/$branch_type/" | head -1)"
if [ -z "$open_branch" ] && [ "$has_origin" = 1 ]; then
  open_branch="$(G ls-remote --heads origin "refs/heads/$branch_type/*" 2>/dev/null | head -1 | sed 's|.*refs/heads/||')"
fi
[ -z "$open_branch" ] || fail "$open_branch is still open — finish it first (one $branch_type at a time)"
if has_ref "refs/tags/v$version" \
   || { [ "$has_origin" = 1 ] && G ls-remote --exit-code --tags origin "refs/tags/v$version" >/dev/null 2>&1; }; then
  fail "tag v$version already exists — that version was released; pick another"
fi

# --- 3. release only: sync develop, then warn about what this release misses ----------------
if [ "$branch_type" = release ]; then
  if [ "$mode" = start ] && [ "$has_origin" = 1 ]; then
    G fetch -q origin 2>/dev/null || echo "warn: fetch from origin failed (offline?) — using local refs as they are"
  fi
  if has_ref "refs/remotes/origin/$integration"; then
    behind="$(G rev-list --count "$integration..origin/$integration")"
    ahead="$(G rev-list --count "origin/$integration..$integration")"
    # Strictly behind: fast-forward (common.sh fast_forward_to_origin) — but a
    # branch checked out in ANOTHER checkout can't be moved safely, so that
    # case only warns.
    if [ "$behind" != 0 ] && [ "$ahead" = 0 ]; then
      if [ "$mode" = plan ]; then
        echo "plan: $integration is $behind commit(s) behind origin — start will fast-forward it"
      else
        fast_forward_to_origin "$integration"
        case $? in
          0) echo "ok: fast-forwarded $integration from origin" ;;
          2) echo "warn: $integration is behind origin by $behind commit(s) but checked out at $(checked_out_at "$integration") — releasing local $integration; pull it there first if those commits belong in this release" ;;
        esac
      fi
    elif [ "$behind" != 0 ]; then
      echo "warn: $integration has diverged from origin ($ahead ahead, $behind behind) — releasing local $integration"
    fi
  fi
  production_only="$(G rev-list --no-merges --count "$integration..$production")"
  [ "$production_only" = 0 ] || echo "warn: $production has $production_only commit(s) $integration does not — expect a conflict at finish; merge $production into $integration first if you can"
  unmerged="$(G for-each-ref --format='%(refname:short)' "refs/heads/$FEATURE_PREFIX" | while read -r feature; do
    G merge-base --is-ancestor "$feature" "$integration" || echo "$feature"; done | paste -sd ' ' -)"
  [ -z "$unmerged" ] || echo "warn: not in this release (not merged into $integration yet): $unmerged"
fi

# --- 4-6. create, bump, draft, commit, baseline --------------------------------------------
if [ "$mode" = plan ]; then
  echo "plan: start will create $branch from $start_point, bump the manifests to $version, and draft the changelog entry"
  exit 0
fi
W switch -q -c "$branch" "$start_point" || fail "could not create $branch from $start_point"
echo "ok: created $branch from $start_point — now checked out in $here (not pushed)"
bump_manifests "$version"
if changelog_enabled; then
  if [ "$branch_type" = release ]; then
    changelog_draft "$version" "${last_tag:+$last_tag..}$integration"
  else
    changelog_draft "$version"
  fi
fi
for file in $MANIFESTS $CHANGELOG_FILE; do [ -f "$here/$file" ] && W add -- "$file"; done
if ! W diff --cached --quiet; then
  W commit -q -m "chore(release): bump version to $version" && echo "ok: committed the version bump"
fi
run_tests "$here"
echo "done: $branch started at $(W rev-parse --short HEAD)"
exit 0
