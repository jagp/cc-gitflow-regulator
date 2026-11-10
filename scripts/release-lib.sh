# cc-gitflow-regulator release-lib — versions, manifests and the changelog for
# the release/hotfix scripts. Sourced after common.sh, never run on its own.
#
# Files are read and written in $here, the checkout the user is standing in
# (which may be a worktree), never in the main clone. Refs are read with G.
#
# Versions:
#   last_release_tag <ref>       newest vX.Y.Z tag reachable from <ref>
#   current_manifest_version     the version this project declares
#   classify_commits <range>     sort the range's commits by Conventional Commits
#   suggest_version <X.Y.Z>      next version from the classified commits
#   understates <last> <given>   is <given> a smaller bump than the commits call for?
#   valid_version <text>         exactly X.Y.Z (no "v", no pre-release suffix)
# Manifests:   bump_manifests, manifests_not_at, own_version_line
# Changelog:   changelog_* (draft, entry checks, dating, filling, notes)

VERSION_PATTERN='^[0-9]+\.[0-9]+\.[0-9]+$'
valid_version() { [[ "$1" =~ $VERSION_PATTERN ]]; }
# version_regex <X.Y.Z>: the version with its dots escaped, for grep -E
# (an unescaped dot would match any character).
version_regex() { printf '%s' "$1" | sed 's/\./\\./g'; }
CARRIAGE_RETURN=$'\r'

# --- line editing (pure bash) -----------------------------------------------------------------
# Git Bash's sed and awk drop a CRLF line's \r and macOS sed has no plain -i,
# so the edits that must keep a file byte-for-byte use `read -r`, which keeps
# the \r. Replacements are spliced with prefix/suffix expansions: bash 3.2
# (macOS) would keep the quotes of a quoted ${line/old/"new"} replacement.

# replace_first <text> <old> <new>: <text> with its first <old> replaced.
replace_first() {
  local text="$1" old="$2" new="$3"
  case "$text" in *"$old"*) printf '%s' "${text%%"$old"*}$new${text#*"$old"}" ;; *) printf '%s' "$text" ;; esac
}

# replace_in_matching_lines <file> <regex> <old> <new>: in every line matching
# the bash regex, replace the first <old> with <new>.
replace_in_matching_lines() {
  local file="$1" pattern="$2" old="$3" new="$4" line
  while IFS= read -r line || [ -n "$line" ]; do
    [[ "$line" =~ $pattern ]] && line="$(replace_first "$line" "$old" "$new")"
    printf '%s\n' "$line"
  done < "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# replace_on_line <file> <line number> <old> <new>: same, on one line only.
replace_on_line() {
  local file="$1" target="$2" old="$3" new="$4" line number=0
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    [ "$number" = "$target" ] && line="$(replace_first "$line" "$old" "$new")"
    printf '%s\n' "$line"
  done < "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# insert_after_first_match <file> <regex> <text>: put <text>'s lines right
# after the first line matching the bash regex. When that line ends in \r
# (a CRLF file), every inserted line gets one too, so the file stays CRLF.
insert_after_first_match() {
  local file="$1" pattern="$2" text="$3" line inserted=0 ending added
  while IFS= read -r line || [ -n "$line" ]; do
    printf '%s\n' "$line"
    if [ "$inserted" = 0 ] && [[ "$line" =~ $pattern ]]; then
      ending=""; [ "${line%"$CARRIAGE_RETURN"}" != "$line" ] && ending="$CARRIAGE_RETURN"
      while IFS= read -r added || [ -n "$added" ]; do printf '%s%s\n' "$added" "$ending"; done <<< "$text"
      inserted=1
    fi
  done < "$file" > "$file.tmp" && mv "$file.tmp" "$file"
}

# --- versions ---------------------------------------------------------------------------------
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

# understates: true when <given> is lower than the suggestion, i.e. the user
# picked a smaller bump than the commits call for (a warning, never a refusal).
# Compared number by number (no sort -V, which not every platform has).
understates() {
  local given_major given_minor given_patch suggested_major suggested_minor suggested_patch
  IFS=. read -r given_major given_minor given_patch <<< "$2"
  IFS=. read -r suggested_major suggested_minor suggested_patch <<< "$(suggest_version "$1")"
  [ "$given_major" -ne "$suggested_major" ] && { [ "$given_major" -lt "$suggested_major" ]; return; }
  [ "$given_minor" -ne "$suggested_minor" ] && { [ "$given_minor" -lt "$suggested_minor" ]; return; }
  [ "$given_patch" -lt "$suggested_patch" ]
}

# --- manifests --------------------------------------------------------------------------------
# The files that declare a version. Only their own version line is bumped;
# everything else that still names the old version is reported by finish's
# version sweep.
MANIFESTS=".claude-plugin/plugin.json .claude-plugin/marketplace.json package.json"
VERSION_KEY_PATTERN='^[[:space:]]*"version"[[:space:]]*:[[:space:]]*"([^"]*)"'
NAME_KEY_PATTERN='^[[:space:]]*"name"[[:space:]]*:[[:space:]]*"([^"]*)"'

# own_name: this project's name, from plugin.json (or package.json).
own_name() {
  local manifest line
  for manifest in .claude-plugin/plugin.json package.json; do
    [ -f "$here/$manifest" ] || continue
    while IFS= read -r line; do
      [[ "$line" =~ $NAME_KEY_PATTERN ]] && { echo "${BASH_REMATCH[1]}"; return 0; }
    done < "$here/$manifest"
  done
}

# own_version_line <manifest path> <content file>: "<line number> <version>"
# for the version line that belongs to THIS project in <content file>:
#   - marketplace.json: the first "version" after the entry named own_name
#     (a marketplace may list other plugins; their versions are not ours)
#   - other manifests: the first "version" line
# A "version" line whose value can't be read prints "<line number> ?", so a
# corrupted value counts as a mismatch instead of being skipped.
own_version_line() {
  local manifest="$1" content="$2" line number=0 in_entry=1 wanted_name
  if [ "$manifest" = .claude-plugin/marketplace.json ]; then
    wanted_name="$(own_name)"; [ -n "$wanted_name" ] && in_entry=0
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    number=$((number + 1))
    if [ "$in_entry" = 0 ]; then
      [[ "$line" =~ $NAME_KEY_PATTERN ]] && [ "${BASH_REMATCH[1]}" = "$wanted_name" ] && in_entry=1
      continue
    fi
    case "$line" in *'"version"'*) ;; *) continue ;; esac
    if [[ "$line" =~ $VERSION_KEY_PATTERN ]] && [ -n "${BASH_REMATCH[1]}" ]; then
      echo "$number ${BASH_REMATCH[1]}"
    else
      echo "$number ?"
    fi
    return 0
  done < "$content"
}

# current_manifest_version: the version this project declares (plugin.json,
# else package.json), for repos with no release tag yet.
current_manifest_version() {
  local manifest found
  for manifest in .claude-plugin/plugin.json package.json; do
    [ -f "$here/$manifest" ] || continue
    found="$(own_version_line "$manifest" "$here/$manifest")"
    [ -n "$found" ] && { echo "${found#* }"; return 0; }
  done
}

# bump_manifests <version>: set this project's version line in every manifest
# that declares the current version. Other lines (other plugins, dependencies)
# are never touched. Prints one "ok:" line per file changed.
bump_manifests() {
  local new_version="$1" old_version manifest found
  old_version="$(current_manifest_version)"
  [ -n "$old_version" ] && [ "$old_version" != "$new_version" ] || return 0
  for manifest in $MANIFESTS; do
    [ -f "$here/$manifest" ] || continue
    found="$(own_version_line "$manifest" "$here/$manifest")"
    [ "${found#* }" = "$old_version" ] || continue
    replace_on_line "$here/$manifest" "${found%% *}" "\"$old_version\"" "\"$new_version\""
    echo "ok: $manifest $old_version -> $new_version"
  done
}

# manifests_not_at <version> <ref>: the manifests on <ref> whose own version
# is not <version> (or can't be read), one per line; empty = all agree. Read
# straight from git, so finish's plan can check a branch without a checkout.
manifests_not_at() {
  local manifest found content
  content="$(mktemp)"
  for manifest in $MANIFESTS; do
    G show "$2:$manifest" > "$content" 2>/dev/null || continue
    found="$(own_version_line "$manifest" "$content")"
    [ -n "$found" ] && [ "${found#* }" != "$1" ] && echo "$manifest"
  done
  rm -f "$content"
  return 0
}

# --- changelog --------------------------------------------------------------------------------
CHANGELOG_FILE="CHANGELOG.md"
changelog_enabled() { switch_on CC_GITFLOW_REGULATOR_CHANGELOG gitflow.release.changelog; }

# changelog_content [ref]: the changelog's text — from <ref> when given (no
# checkout needed), else from the current checkout. Prints nothing if absent.
changelog_content() {
  if [ -n "${1:-}" ]; then G show "$1:$CHANGELOG_FILE" 2>/dev/null
  else cat "$here/$CHANGELOG_FILE" 2>/dev/null; fi
}

# changelog_has_entry <version> [ref]: is there a "## <version>" heading?
# Anything may follow after a space; a CRLF line ending is fine.
changelog_has_entry() {
  local escaped_version; escaped_version="$(version_regex "$1")"
  changelog_content "${2:-}" | grep -qE "^## ${escaped_version}( |\$|${CARRIAGE_RETURN})"
}

# changelog_entry_text <version> [ref]: the entry's lines without its heading,
# up to the next "## " heading; \r stripped, outer blank lines trimmed.
changelog_entry_text() {
  changelog_content "${2:-}" | tr -d '\r' | HEADING_PATTERN="^## $(version_regex "$1")( |$)" awk '
    $0 ~ ENVIRON["HEADING_PATTERN"] { inside = 1; next }
    inside && /^## / { exit }
    inside { lines[++count] = $0 }
    END { first = 1; while (first <= count && lines[first] == "") first++
          last = count; while (last >= first && lines[last] == "") last--
          for (line = first; line <= last; line++) print lines[line] }'
}

# changelog_set_date <version>: "## <version> — unreleased" becomes
# "## <version> — <today>" in the checkout, keeping a \r line ending.
# An entry that already carries a date is left exactly as it is.
changelog_set_date() {
  local file="$here/$CHANGELOG_FILE" pattern
  pattern="^## $(version_regex "$1") — unreleased${CARRIAGE_RETURN}?\$"
  # Only touch the file when there is something to change: rewriting it
  # anyway can change its line endings and leave it looking modified.
  grep -qE "$pattern" "$file" 2>/dev/null || return 0
  replace_in_matching_lines "$file" "$pattern" unreleased "$(date +%F)"
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

# changelog_fill_empty <version> <range>: an entry with no "- " bullets yet
# (a hotfix's bare heading) gets changelog_sections for <range> under it.
changelog_fill_empty() {
  local version="$1" sections
  changelog_entry_text "$version" | grep -q '^- ' && return 0
  classify_commits "$2"; sections="$(changelog_sections)"
  [ -n "$sections" ] || return 0
  insert_after_first_match "$here/$CHANGELOG_FILE" "^## $(version_regex "$version")( |\$|$CARRIAGE_RETURN)" \
    "$(printf '\n%s' "$sections")"
}

# release_notes <version> <ref> <range>: the text for the tag message and the
# GitHub Release page — the changelog entry on <ref> when the changelog is on
# and the entry has text, else the classified commits of <range>.
release_notes() {
  local notes=""
  changelog_enabled && notes="$(changelog_entry_text "$1" "$2")"
  if [ -z "$notes" ]; then classify_commits "$3"; notes="$(changelog_sections)"; fi
  printf '%s\n' "${notes:-Release $1}"
}

# changelog_draft <version> [range]: add "## <version> — unreleased" as the
# newest entry, right under the "# ..." title (creating the file with a
# "# Changelog" title if needed). With a range, the entry is filled with
# changelog_sections for it; without one it is a bare heading to fill in.
# An existing entry for <version> is never touched.
changelog_draft() {
  local version="$1" range="${2:-}" file="$here/$CHANGELOG_FILE" block
  changelog_has_entry "$version" && return 0
  [ -f "$file" ] || printf '# Changelog\n' > "$file"
  block="$(printf '\n## %s — unreleased' "$version")"
  if [ -n "$range" ]; then
    classify_commits "$range"
    [ -n "$(changelog_sections)" ] && block="$block$(printf '\n\n%s' "$(changelog_sections)")"
  fi
  insert_after_first_match "$file" '^# ' "$block"
  echo "ok: $CHANGELOG_FILE entry ## $version drafted — edit it before finishing"
}
