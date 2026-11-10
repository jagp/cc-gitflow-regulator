#!/usr/bin/env bash
# cc-gitflow-regulator finish-release — deterministic "Finish release" and
# "Finish hotfix" (the counterpart of start-release.sh).
#
# Usage: finish-release.sh release|hotfix plan|finish|sync-main|publish
#   plan       read-only: run the checks and show which landing steps are
#              done and which finish will do
#   finish     check, then land: merge into the production branch, tag,
#              merge back, push the branches, clean up. Ends with
#              `ask: push-tag v<version>`; the tag is never pushed here.
#   sync-main  after a conflict merging into production: merge production
#              into the release/hotfix branch so the conflict can be resolved
#              there, then run finish again
#   publish    after the user's yes: push the tag, create the GitHub Release
#              page, print rollback commands and the notify list
#
# Acts on the single local <type>/<version> branch. Landing is resumable:
# every step checks whether it is already done and skips it, so after a
# conflict the user resolves it and simply runs finish again.
#
# Where the branch is merged back after production:
#   release  the integration branch (develop)
#   hotfix   the open release/* branch if there is one, else develop — so the
#            next release cannot ship without the fix
#
# Exit codes: 0 ok   2 refused   3 merge conflict   4 cleanup incomplete
# Configuration: CC_GITFLOW_REGULATOR_BASE, CC_GITFLOW_REGULATOR_PUSH_MERGED,
#   CC_GITFLOW_REGULATOR_CHANGELOG / gitflow.release.changelog,
#   CC_GITFLOW_REGULATOR_GH_RELEASE / gitflow.release.githubRelease,
#   gitflow.testCommand
set -u

branch_type="${1:-}"; mode="${2:-}"
case "$branch_type:$mode" in release:*|hotfix:*) ;; *) mode="" ;; esac
case "$mode" in plan|finish|sync-main|publish) ;; *)
  echo "usage: finish-release.sh release|hotfix plan|finish|sync-main|publish" >&2; exit 2 ;;
esac
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"
source "$(dirname "${BASH_SOURCE[0]}")/release-lib.sh"

integration="$(integration_branch)"; production="$(production_branch)"
[ -n "$integration" ] || fail "no integration branch (develop/dev) — set CC_GITFLOW_REGULATOR_BASE"
[ -n "$production" ] || fail "no production branch (main/master) — set git config gitflow.branch.master"
has_origin=0; G remote get-url origin >/dev/null 2>&1 && has_origin=1
incomplete=0

# ============================== publish =======================================================
# Runs after finish, once the user said yes to `ask: push-tag`. The branch is
# gone by now, so the release is found by its tag: the newest vX.Y.Z on the
# production branch.
#   1. push the tag
#   2. create the GitHub Release page (unless switched off); a missing or
#      failing gh is a warning with the exact command, never a failure
#   3. print the commands that would undo this release
#   4. print the notify list from RELEASING.md ("## Notify" bullets) and an
#      announcement to paste into each place. Nothing is sent.
if [ "$mode" = publish ]; then
  [ "$has_origin" = 1 ] || fail "no origin remote — nothing to publish to"
  tag="$(last_release_tag "$production")"
  [ -n "$tag" ] || fail "no vX.Y.Z tag on $production — run finish first"
  version="${tag#v}"; previous_tag="$(last_release_tag "$tag^")"
  G push -q origin "refs/tags/$tag" || fail "could not push $tag to origin"
  echo "ok: pushed $tag to origin"
  notes="$(release_notes "$version" "$tag" "${previous_tag:+$previous_tag..}$tag")"
  if switch_on CC_GITFLOW_REGULATOR_GH_RELEASE gitflow.release.githubRelease; then
    notes_file="$(mktemp)"; printf '%s\n' "$notes" > "$notes_file"
    if command -v gh >/dev/null 2>&1 \
       && (cd "$root" && gh release create "$tag" --title "$tag" --notes-file "$notes_file") >/dev/null 2>&1; then
      echo "ok: created the GitHub Release $tag"
    else
      echo "warn: GitHub Release not created (gh missing, not logged in, or it failed) — run: gh release create $tag --title $tag --notes-from-tag"
    fi
    rm -f "$notes_file"
  else
    echo "ok: GitHub Release skipped (switched off)"
  fi
  production_merge="$(G rev-parse --short "$tag^{commit}")"
  echo "rollback: gh release delete $tag"
  echo "rollback: git push origin :refs/tags/$tag"
  echo "rollback: git tag -d $tag"
  echo "rollback: git revert -m 1 $production_merge   (on $production, then push it)"
  notify_list="$(awk '/^## Notify/ { inside = 1; next } inside && /^## / { exit } inside && /^- / { print substr($0, 3) }' "$here/RELEASING.md" 2>/dev/null | tr -d '\r')"
  if [ -n "$notify_list" ]; then
    printf '%s\n' "$notify_list" | sed 's/^/notify: /'
    echo "announce: $(basename "$root") $tag is out"
    printf '%s\n' "$notes" | sed 's/^/announce: /'
  else
    echo "note: no RELEASING.md \"## Notify\" list — add one to be reminded where to announce releases"
  fi
  exit 0
fi

# --- the branch being finished --------------------------------------------------------------
# Exactly one local <type>/* branch; its name carries the version.
open_branches="$(G for-each-ref --format='%(refname:short)' "refs/heads/$branch_type/")"
if [ -z "$open_branches" ]; then
  # Nothing left to land. If the last finish ended with the tag push
  # declined, the tag is still local only: offer it again.
  last_tag="$(last_release_tag "$production")"
  if [ -n "$last_tag" ] && [ "$has_origin" = 1 ] \
     && ! G ls-remote --exit-code --tags origin "refs/tags/$last_tag" >/dev/null 2>&1; then
    echo "ok: no $branch_type/* branch open — $last_tag is landed but not pushed yet"
    echo "ask: push-tag $last_tag — push the tag and publish the release?"
    exit 0
  fi
  fail "no $branch_type/* branch to finish"
fi
# -eq, not =: BSD wc (macOS) pads the count with spaces.
[ "$(printf '%s\n' "$open_branches" | wc -l)" -eq 1 ] \
  || fail "several $branch_type branches are open: $(printf '%s' "$open_branches" | paste -sd ' ' -) — finish them one at a time"
branch="$open_branches"; version="${branch#"$branch_type"/}"; tag="v$version"
valid_version "$version" || fail "$branch is not named $branch_type/X.Y.Z"

# Back-merge target: see the header. A hotfix prefers an open release branch.
merge_back_into="$integration"
if [ "$branch_type" = hotfix ]; then
  open_release="$(G for-each-ref --format='%(refname:short)' refs/heads/release/ | head -1)"
  [ -n "$open_release" ] && merge_back_into="$open_release"
fi
# The previous release: the version sweep looks for it, ranges start at it.
previous_tag="$(last_release_tag "$production")"
since="${previous_tag:+$previous_tag..}"

# --- landing state (what is already done) -----------------------------------------------------
# landed: the branch's work is in production. A tag that exists must sit on a
# production commit that contains the branch, or something else owns it.
landed=0; G merge-base --is-ancestor "$branch" "$production" 2>/dev/null && landed=1
tagged=0
if has_ref "refs/tags/$tag"; then
  tagged=1
  G merge-base --is-ancestor "$branch" "$tag" 2>/dev/null && G merge-base --is-ancestor "$tag" "$production" 2>/dev/null \
    || fail "tag $tag exists but does not mark this $branch_type on $production — remove it or pick another version"
fi
merged_back=0; G merge-base --is-ancestor "$branch" "$merge_back_into" 2>/dev/null && merged_back=1

# conflicted_files: the paths the in-progress merge in this checkout left unmerged.
conflicted_files() { W diff --name-only --diff-filter=U | sed 's/^/conflict: /'; }

# resolve_version_conflicts: settle the conflict every hotfix-into-release
# merge has — both branches bumped the version — and nothing more.
#   - manifests: in the base, ours and theirs copies, set this project's
#     version line to OURS (the release's version is the one going out next),
#     then re-run the three-way merge. With the version clash gone, the rest
#     of the hotfix's changes (a bumped dependency, say) merge normally. If
#     anything still conflicts, it is a real conflict: give up.
#   - changelog: keep both sides' lines (the hotfix entry and the release's).
#   - any other conflicted file: a real conflict, give up.
# Gives up with return 1 (the caller aborts the whole merge). All settled:
# commit the merge and return 0.
resolve_version_conflicts() {
  local file stage_copy ours_copy base_copy theirs_copy ours_version found
  for file in $(W diff --name-only --diff-filter=U); do
    case " $MANIFESTS $CHANGELOG_FILE " in *" $file "*) ;; *) return 1 ;; esac
  done
  for file in $(W diff --name-only --diff-filter=U); do
    ours_copy="$(mktemp)"; base_copy="$(mktemp)"; theirs_copy="$(mktemp)"
    W show ":2:$file" > "$ours_copy"
    W show ":1:$file" > "$base_copy" 2>/dev/null || : > "$base_copy"
    W show ":3:$file" > "$theirs_copy"
    if [ "$file" = "$CHANGELOG_FILE" ]; then
      git merge-file --union "$ours_copy" "$base_copy" "$theirs_copy"
    else
      ours_version="$(own_version_line "$file" "$ours_copy")"; ours_version="${ours_version#* }"
      for stage_copy in "$base_copy" "$theirs_copy"; do
        found="$(own_version_line "$file" "$stage_copy")"
        [ -n "$found" ] && replace_on_line "$stage_copy" "${found%% *}" "\"${found#* }\"" "\"$ours_version\""
      done
      if ! git merge-file "$ours_copy" "$base_copy" "$theirs_copy" 2>/dev/null; then
        rm -f "$ours_copy" "$base_copy" "$theirs_copy"; return 1
      fi
    fi
    cat "$ours_copy" > "$here/$file"; rm -f "$ours_copy" "$base_copy" "$theirs_copy"
    W add -- "$file"
    echo "ok: settled the version conflict in $file"
  done
  W commit -q --no-edit
}

# ============================== sync-main =====================================================
# Merge production into the branch, in the current checkout. On a conflict the
# merge is LEFT in progress: resolving it on the branch is the whole point.
if [ "$mode" = sync-main ]; then
  require_clean_tree "$here"
  W switch -q "$branch" || fail "could not switch to $branch"
  if W merge -q --no-ff -m "Merge branch '$production' into $branch" "$production" >/dev/null 2>&1; then
    echo "ok: merged $production into $branch — run finish again"
    exit 0
  fi
  conflicted_files
  echo "next: resolve these files on $branch, commit, then run finish again"
  exit 3
fi

# ============================== checks ========================================================
# Only before landing: once the branch is in production, re-checking it would
# block a resumed run for no gain.
# Uncommitted changes are refused on EVERY finish run, resumed ones too: the
# landing steps switch branches and may abort merges, which could lose them.
[ "$mode" = finish ] && require_clean_tree "$here"
if [ "$landed" = 0 ]; then
  # Refusals.
  if changelog_enabled && ! changelog_has_entry "$version" "$branch"; then
    fail "$CHANGELOG_FILE has no entry for $version on $branch — add \"## $version\" (or switch the changelog off)"
  fi
  wrong_manifests="$(manifests_not_at "$version" "$branch" | paste -sd ' ' -)"
  [ -z "$wrong_manifests" ] || fail "manifests not at $version: $wrong_manifests"

  # Warnings. Version sweep: tracked files still naming the previous version.
  if [ -n "$previous_tag" ]; then
    G grep -n -F "${previous_tag#v}" "$branch" -- . ":(exclude)$CHANGELOG_FILE" 2>/dev/null \
      | sed "s|^$branch:|warn: still names ${previous_tag#v}: |; s|^\(warn: [^:]*: [^:]*:[0-9]*\):.*|\1|"
  fi
  # Coverage: changed source files that no changed test file mentions by name.
  changed_files="$(G diff --name-only "${previous_tag:-$(G rev-list --max-parents=0 "$branch" | tail -1)}" "$branch")"
  changed_tests="$(printf '%s\n' "$changed_files" | grep -E '^(tests?)/' || true)"
  printf '%s\n' "$changed_files" | grep -vE '^(tests?/|\.)|\.md$|\.json$' | while read -r source_file; do
    [ -n "$source_file" ] || continue
    name="$(basename "${source_file%.*}")"
    mentioned=0
    for test_file in $changed_tests; do
      G show "$branch:$test_file" 2>/dev/null | grep -qF "$name" && { mentioned=1; break; }
    done
    [ "$mentioned" = 1 ] || echo "warn: no test change mentions $source_file"
  done
  production_only="$(G rev-list --no-merges --count "$integration..$production")"
  [ "$production_only" = 0 ] || echo "warn: $production has $production_only commit(s) $integration does not — the merge into $production may conflict"
fi

# ============================== plan ==========================================================
if [ "$mode" = plan ]; then
  state() { if [ "$1" = 1 ]; then echo done; else echo "will do"; fi; }
  echo "plan: $branch_type $branch -> $production (tag $tag), then -> $merge_back_into"
  [ "$landed" = 1 ] || echo "plan: tests: run on $branch before merging"
  echo "plan: merge into $production: $(state "$landed")"
  echo "plan: tag $tag: $(state "$tagged")"
  echo "plan: merge back into $merge_back_into: $(state "$merged_back")"
  echo "plan: then push $production and $merge_back_into, delete $branch, and ask before pushing $tag"
  exit 0
fi

# ============================== finish: preflight =============================================
# 1. Every branch finish switches to must be free here: one checked out in
#    ANOTHER checkout (main clone or worktree) can't be switched to, and
#    moving it under that checkout would leave its files stale.
for needed in "$branch" "$production" "$merge_back_into"; do
  folder="$(checked_out_at "$needed")"
  [ -z "$folder" ] || same_folder "$folder" "$here"     || fail "$needed is checked out at $folder — run /finish-$branch_type there, or switch that checkout to another branch first"
done
# 2. Before landing, production and the merge-back branch must not be behind
#    origin: merging and tagging a stale copy would be rejected on push, or
#    silently leave a teammate's commits out of the release.
if [ "$landed" = 0 ] && [ "$has_origin" = 1 ]; then
  G fetch -q origin 2>/dev/null || echo "warn: fetch from origin failed (offline?) — checking against the refs already here"
  for needed in "$production" "$merge_back_into"; do
    has_ref "refs/remotes/origin/$needed" || continue
    behind="$(G rev-list --count "$needed..origin/$needed")"
    [ "$behind" = 0 ] || fail "$needed is behind origin by $behind commit(s) — bring it up to date (git pull on $needed) and run finish again"
  done
fi

# ============================== finish: land ==================================================
# 1. On the branch: run the tests, then finish the changelog entry.
if [ "$landed" = 0 ]; then
  W switch -q "$branch" || fail "could not switch to $branch"
  run_tests "$here" || fail "tests failed on $branch — fix them before finishing"
  if changelog_enabled; then
    [ "$branch_type" = hotfix ] && changelog_fill_empty "$version" "$since$branch"
    changelog_set_date "$version"
    # Stage first, then commit only if git sees a real change (line-ending
    # normalisation can make an untouched file look modified).
    [ -f "$here/$CHANGELOG_FILE" ] && W add -- "$CHANGELOG_FILE"
    if ! W diff --cached --quiet; then
      W commit -q -m "docs(changelog): date $version" && echo "ok: dated the $version changelog entry"
    fi
  fi
  # 2. Merge into production. A conflict aborts the merge and changes nothing.
  W switch -q "$production" || fail "could not switch to $production"
  if ! W merge -q --no-ff -m "Merge branch '$branch'" "$branch" >/dev/null 2>&1; then
    conflicted_files
    W merge --abort; W switch -q "$branch"
    echo "ask: sync-main — merging $branch into $production conflicts; merge $production into $branch to resolve it there, then finish again"
    exit 3
  fi
  echo "ok: merged $branch into $production (--no-ff)"
fi
# 3. Tag the production merge.
if [ "$tagged" = 0 ]; then
  G tag -a "$tag" -m "$tag" -m "$(release_notes "$version" "$branch" "$since$branch")" "$production" \
    || fail "could not create tag $tag"
  echo "ok: tagged $production as $tag (local)"
fi
# 4. Merge back. A conflict aborts; production and the tag stay as they are.
if [ "$merged_back" = 0 ]; then
  W switch -q "$merge_back_into" || fail "could not switch to $merge_back_into"
  # The TAG is merged (git-flow's default), not the branch: that brings the
  # production merge commit along, so $merge_back_into stays a superset of
  # $production and the next release's "commits only on production" check
  # stays quiet.
  if ! W merge -q --no-ff -m "Merge tag '$tag' into $merge_back_into" "$tag" >/dev/null 2>&1 \
     && ! resolve_version_conflicts; then
    conflicted_files
    W merge --abort; W switch -q "$branch"
    echo "next: merge $branch into $merge_back_into by hand and resolve the conflict, then finish again ($production and $tag are done, local only)"
    exit 3
  fi
  echo "ok: merged $tag into $merge_back_into (--no-ff)"
fi
W switch -q "$merge_back_into" 2>/dev/null

# 5. Push the branches (never the tag here).
if [ "$has_origin" = 0 ]; then
  echo "ok: nothing pushed — no origin remote"
elif ! switch_on CC_GITFLOW_REGULATOR_PUSH_MERGED gitflow.release.pushMerged; then
  echo "ok: nothing pushed (CC_GITFLOW_REGULATOR_PUSH_MERGED is off)"
else
  # Push production, plus the merge-back branch when it is the integration
  # branch or already on origin: a hotfix merged into a release branch nobody
  # pushed yet does not publish that release branch. --atomic: all or none.
  push_list="$production"
  if [ "$merge_back_into" = "$integration" ] || has_ref "refs/remotes/origin/$merge_back_into"; then
    push_list="$push_list $merge_back_into"
  fi
  if G push -q --atomic origin $push_list 2>/dev/null; then
    echo "ok: pushed $push_list to origin"
  else
    echo "warn: could not push $push_list (rejected or offline) — nothing was pushed; push them yourself" >&2
    incomplete=1
  fi
fi

# ============================== finish: clean up ==============================================
# The work is in production and merged back, so the branch can go.
if G branch -D "$branch" >/dev/null 2>&1; then
  G config --remove-section "gitflow.branch.$branch" 2>/dev/null
  echo "ok: deleted branch $branch"
else
  echo "warn: could not delete $branch" >&2; incomplete=1
fi
if [ "$has_origin" = 1 ] && has_ref "refs/remotes/origin/$branch"; then
  echo "ask: delete-remote $branch $(G rev-parse "refs/remotes/origin/$branch") — origin still has $branch; delete it too?"
fi
# Features /finish-feature kept "until $branch lands" (their recorded base):
# it has landed, so finish-feature can now clean them up (merge = no-op).
if [ "$branch_type" = release ]; then
  G for-each-ref --format='%(refname:short)' "refs/heads/" | while read -r held; do
    [ "$(G config --get "gitflow.branch.$held.base" 2>/dev/null)" = "$branch" ] || continue
    echo "ok: cleaning up $held (it was held for $branch)"
    CC_GITFLOW_REGULATOR_PUSH_MERGED=0 bash "$PLUGIN_SCRIPTS/finish-feature.sh" finish "$held" 2>&1 | sed 's/^/  /'
  done
fi

if [ "$has_origin" = 1 ]; then
  echo "ask: push-tag $tag — push the tag and publish the release?"
else
  echo "ok: $tag is local — add an origin remote, then run publish"
fi
echo "done: $branch -> $production ($tag) and $merge_back_into at $(G rev-parse --short "$production")"
[ "$incomplete" = 1 ] && exit 4
exit 0
