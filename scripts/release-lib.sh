# cc-gitflow-regulator release-lib — versions, manifests and the changelog for
# the release/hotfix scripts. Sourced after common.sh, never run on its own.
#
# Versions:
#   last_release_tag <ref>       newest vX.Y.Z tag reachable from <ref>
#   current_manifest_version     the "version" in plugin.json or package.json
#   classify_commits <range>     sort the range's commits by Conventional Commits
#   suggest_version <X.Y.Z>      next version from the classified commits
#   understates <last> <given>   is <given> a smaller bump than the commits call for?
#   valid_version <text>         exactly X.Y.Z (no "v", no pre-release suffix)

VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'
valid_version() { [[ "$1" =~ $VERSION_PATTERN ]]; }

# last_release_tag: the last release, as a tag shaped exactly vX.Y.Z.
#   git describe finds the nearest tag matching a loose glob; anything it
#   finds that is not strictly vX.Y.Z (e.g. vbump-0.3.1) is not a release, so
#   step past it and look again from that tag's parent.
last_release_tag() {
  local start="$1" tag
  while tag="$(G describe --tags --abbrev=0 --match 'v[0-9]*' "$start" 2>/dev/null)"; do
    if valid_version "${tag#v}"; then echo "$tag"; return 0; fi
    start="$tag^"
  done
}

# current_manifest_version: the version a project declares, for repos with no
# release tag yet. First "version": "..." line of the first manifest found.
current_manifest_version() {
  local manifest
  for manifest in .claude-plugin/plugin.json package.json; do
    [ -f "$root/$manifest" ] || continue
    sed -nE 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$root/$manifest" | head -1
    return 0
  done
}

# classify_commits: read every non-merge commit in <range> and sort it by its
# Conventional Commits type. Sets, for the caller:
#   breaking_count feat_count fix_count other_count unclassified_count
#   breaking_subjects feat_subjects fix_subjects   (lines of "<subject> (<sha>)")
# Rules:
#   breaking      "type!:" / "type(scope)!:" subject, or a "BREAKING CHANGE:" body line
#   feat          "feat:" / "feat(scope):"
#   fix           "fix:" or "perf:" (with or without scope)
#   other         any other lowercase "type:" (docs, test, chore, ...)
#   unclassified  anything else — counted, never guessed at
classify_commits() {
  local range="$1" sha subject body entry
  breaking_count=0 feat_count=0 fix_count=0 other_count=0 unclassified_count=0
  breaking_subjects="" feat_subjects="" fix_subjects=""
  # One record per commit: sha, subject, body separated by \x1f, ended by \x1e.
  while IFS=$'\x1f' read -r -d $'\x1e' sha subject body; do
    sha="${sha#$'\n'}"
    entry="$subject ($sha)"
    if [[ "$subject" =~ ^[a-z]+(\([^\)]*\))?\!: ]] || [[ "$body" == *"BREAKING CHANGE:"* ]]; then
      breaking_count=$((breaking_count + 1)); breaking_subjects+="$entry"$'\n'
    elif [[ "$subject" =~ ^feat(\([^\)]*\))?: ]]; then
      feat_count=$((feat_count + 1)); feat_subjects+="$entry"$'\n'
    elif [[ "$subject" =~ ^(fix|perf)(\([^\)]*\))?: ]]; then
      fix_count=$((fix_count + 1)); fix_subjects+="$entry"$'\n'
    elif [[ "$subject" =~ ^[a-z]+(\([^\)]*\))?: ]]; then
      other_count=$((other_count + 1))
    else
      unclassified_count=$((unclassified_count + 1))
    fi
  done < <(G log --no-merges --format='%h%x1f%s%x1f%b%x1e' "$range")
}

# suggest_version: the next version after <X.Y.Z>, from the counts that
# classify_commits set. Highest bump wins:
#   breaking  -> major from 1.0 on; MINOR below 1.0 (0.x means "expect breaks")
#   feat      -> minor
#   otherwise -> patch (fixes, or nothing user-facing at all)
# A 0.x project is never bumped to 1.0.0 here: leaving 0.x is the user's call.
suggest_version() {
  local major minor patch
  IFS=. read -r major minor patch <<< "$1"
  if [ "$breaking_count" -gt 0 ] && [ "$major" -gt 0 ]; then
    echo "$((major + 1)).0.0"
  elif [ "$breaking_count" -gt 0 ] || [ "$feat_count" -gt 0 ]; then
    echo "$major.$((minor + 1)).0"
  else
    echo "$major.$minor.$((patch + 1))"
  fi
}

# understates: true when <given> sorts below the suggestion, i.e. the user
# picked a smaller bump than the commits call for (a warning, never a refusal).
understates() {
  local suggested lowest
  suggested="$(suggest_version "$1")"
  [ "$2" = "$suggested" ] && return 1
  lowest="$(printf '%s\n%s\n' "$2" "$suggested" | sort -V | head -1)"
  [ "$lowest" = "$2" ]
}

# --- manifests ------------------------------------------------------------------------------
# The files that declare a version. Only these are bumped; everything else
# that still names the old version is reported by finish's version sweep.
MANIFESTS=".claude-plugin/plugin.json .claude-plugin/marketplace.json package.json"

# bump_manifests: set every manifest that declares the current version to
# <version>. A manifest already at <version> (or declaring something else)
# is left alone. Prints one "ok:" line per file changed.
bump_manifests() {
  local new_version="$1" old_version manifest old_pattern
  old_version="$(current_manifest_version)"
  [ -n "$old_version" ] && [ "$old_version" != "$new_version" ] || return 0
  old_pattern="${old_version//./\.}"
  for manifest in $MANIFESTS; do
    [ -f "$root/$manifest" ] || continue
    grep -qE "\"version\"[[:space:]]*:[[:space:]]*\"$old_pattern\"" "$root/$manifest" || continue
    sed -i -E "s/(\"version\"[[:space:]]*:[[:space:]]*\")$old_pattern\"/\1$new_version\"/" "$root/$manifest"
    echo "ok: $manifest $old_version -> $new_version"
  done
}

# manifests_not_at <version>: the manifests that do NOT declare <version>, one per
# line (empty output = all agree). Used by finish as a refusal.
manifests_not_at() {
  local manifest declared
  for manifest in $MANIFESTS; do
    [ -f "$root/$manifest" ] || continue
    declared="$(sed -nE 's/^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]+)".*/\1/p' "$root/$manifest")"
    [ -z "$declared" ] && continue
    printf '%s\n' "$declared" | grep -qvxF "$1" && echo "$manifest"
  done
  return 0
}

# --- changelog ------------------------------------------------------------------------------
CHANGELOG_FILE="CHANGELOG.md"
changelog_enabled() { switch_on CC_GITFLOW_REGULATOR_CHANGELOG gitflow.release.changelog; }

# changelog_has_entry: is there a "## <version>" heading (any suffix, CRLF ok)?
changelog_has_entry() {
  [ -f "$root/$CHANGELOG_FILE" ] && grep -qE "^## ${1//./\.}( |$|"$'\r'")" "$root/$CHANGELOG_FILE"
}

# changelog_sections: the classified commits (classify_commits must have run)
# as Markdown sections, type prefix stripped from each subject:
#   ### Breaking / ### Added / ### Fixed, each "- <subject>" bullets.
# Empty sections are left out; prints nothing when there is nothing to list.
changelog_sections() {
  local title list printed=0
  for title in Breaking Added Fixed; do
    case "$title" in
      Breaking) list="$breaking_subjects" ;; Added) list="$feat_subjects" ;; Fixed) list="$fix_subjects" ;;
    esac
    [ -n "$list" ] || continue
    [ "$printed" = 1 ] && echo
    echo "### $title"; echo
    printf '%s' "$list" | sed -E 's/^[a-z]+(\([^)]*\))?!?:[[:space:]]*/- /; s/ \([0-9a-f]+\)$//'
    printed=1
  done
}

# changelog_draft <version> [range]: add "## <version> — unreleased" as the
# newest entry, right under the "# ..." title (creating the file with a
# "# Changelog" title if needed). With a range, the entry is filled with
# changelog_sections for it; without one it is a bare heading to fill in.
# An existing entry for <version> is never touched.
changelog_draft() {
  local version="$1" range="${2:-}" file="$root/$CHANGELOG_FILE" sections=""
  changelog_has_entry "$version" && return 0
  if [ -n "$range" ]; then classify_commits "$range"; sections="$(changelog_sections)"; fi
  [ -f "$file" ] || printf '# Changelog\n' > "$file"
  # Insert after the first "# " title line: blank, heading, blank, sections.
  # (Passed through the environment: awk -v rejects multi-line values.)
  HEADING="## $version — unreleased" SECTIONS="$sections" awk '
    !done && /^# / { print; print ""; print ENVIRON["HEADING"]
                     if (ENVIRON["SECTIONS"] != "") { print ""; print ENVIRON["SECTIONS"] }
                     done = 1; next }
    { print }' "$file" > "$file.tmp" && mv "$file.tmp" "$file"
  echo "ok: $CHANGELOG_FILE entry ## $version drafted — edit it before finishing"
}
