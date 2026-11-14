#!/usr/bin/env bash
# prune-merged — delete local branches whose work origin already holds.
#
# Usage: prune-merged.sh plan | run | session
#   plan     say what run would delete; change nothing
#   run      delete those branches
#   session  the SessionStart hook (hooks/hooks.json): read the session's cwd
#            from the hook's JSON, run quietly, report in one systemMessage,
#            and ALWAYS exit 0 — a guardrail must never break a session start.
#            Off with CC_GITFLOW_REGULATOR_PRUNE=off or git config gitflow.prune false.
#
# Why: work merged on GitHub (a PR, or the release pipeline finishing a
# release) leaves the local branch behind. git's own `branch -d` can't tell
# it is safe — with no upstream it compares against whatever is checked out —
# so leftovers pile up. This asks origin directly.
#
# The process, step by step:
#   1. Fetch origin (with --prune, bounded by a timeout, never prompting), so
#      origin's branches reflect what GitHub merged. A failed fetch is fine:
#      stale refs know LESS, so they can only mean fewer deletions.
#   2. Long-lived names: common.sh long_lived_branches (develop, main, their
#      gitflow.branch.* names, ...). They are never deleted themselves.
#   3. The "first-parent line" of every long-lived branch, local and origin:
#      the commits made ON that branch, not merged into it. A branch whose tip
#      sits there has no commits of its own (cut from it, never worked on), so
#      it only LOOKS merged — it is kept.
#   4. For each other local branch, delete it only when ALL hold:
#        - origin/<long-lived> contains its tip (the work is on GitHub)
#        - its tip is on no first-parent line from step 3
#        - it is checked out nowhere (a session may be working in it) —
#          a merged one that is checked out is reported, not touched;
#          /finish-feature removes its worktree
#      Squash-merged or fast-forwarded branches fail the first two checks and
#      are kept: git can't prove they landed.
#   5. Deleting also clears the branch's recorded base (gitflow.branch.<b>.base).
# Nothing is pushed and no worktree is removed.
set -u
mode="${1:-}"
case "$mode" in plan|run|session) ;; *) echo "usage: prune-merged.sh plan|run|session" >&2; exit 2 ;; esac

# --- session: find the repo from the hook's JSON; never fail ----------------
if [ "$mode" = session ]; then
  input="$(cat 2>/dev/null || true)"
  dir="$(printf '%s' "$input" | sed -n 's/.*"cwd" *: *"\([^"]*\)".*/\1/p' | head -1)"
  dir="${dir//\\\\//}"; dir="${dir//\\//}"          # JSON / Windows backslashes -> /
  cd "${dir:-.}" 2>/dev/null || exit 0
  git rev-parse --git-dir >/dev/null 2>&1 || exit 0
fi
git rev-parse --git-dir >/dev/null 2>&1 || { echo "error: not inside a git repository" >&2; exit 2; }
source "$(dirname "${BASH_SOURCE[0]}")/common.sh"

if [ "$mode" = session ]; then
  switch_on CC_GITFLOW_REGULATOR_PRUNE gitflow.prune || exit 0
fi
if ! G remote get-url origin >/dev/null 2>&1; then
  [ "$mode" = session ] || echo "ok: no origin remote — nothing to compare against"
  exit 0
fi

# --- 1. fetch ------------------------------------------------------------------
# GIT_TERMINAL_PROMPT=0: a credential prompt would hang the session start.
fetch_timeout=""; command -v timeout >/dev/null 2>&1 && fetch_timeout="timeout 20"
GIT_TERMINAL_PROMPT=0 $fetch_timeout git -C "$root" fetch -q --prune origin >/dev/null 2>&1 || true

# --- 2 + 3. long-lived names and their first-parent lines -----------------------
long_lived=" $(long_lived_branches | tr -s ' ') "
first_parent_line="$(mktemp)"; trap 'rm -f "$first_parent_line"' EXIT
origin_holders=""
for name in $long_lived; do
  has_ref "refs/heads/$name" && G rev-list --first-parent "refs/heads/$name" >> "$first_parent_line"
  if has_ref "refs/remotes/origin/$name"; then
    G rev-list --first-parent "refs/remotes/origin/$name" >> "$first_parent_line"
    origin_holders="$origin_holders $name"
  fi
done

# --- 4 + 5. decide, then act -----------------------------------------------------
messages=()
while read -r branch tip; do
  case "$long_lived" in *" $branch "*) continue ;; esac              # long-lived: never
  holder=""
  for name in $origin_holders; do
    if G merge-base --is-ancestor "$tip" "refs/remotes/origin/$name" 2>/dev/null; then holder="$name"; break; fi
  done
  [ -n "$holder" ] || continue                                        # not on GitHub yet
  grep -qxF "$tip" "$first_parent_line" && continue                   # no commits of its own
  folder="$(checked_out_at "$branch")"
  if [ -n "$folder" ]; then                                           # someone may be in it
    case "$folder" in
      */.claude/worktrees/*) messages+=("$branch is merged but checked out at $folder — /finish-feature $branch removes it") ;;
      *) messages+=("$branch is merged but checked out at $folder — switch off it and the next session deletes it") ;;
    esac
    continue
  fi
  case "$mode" in
    plan) messages+=("plan: delete $branch (in origin/$holder)") ;;
    *)
      if G branch -q -D "$branch" >/dev/null 2>&1; then
        G config --unset "gitflow.branch.$branch.base" >/dev/null 2>&1 || true
        messages+=("deleted $branch (its work is in origin/$holder)")
      fi ;;
  esac
done < <(G for-each-ref --format='%(refname:short) %(objectname)' refs/heads/)

# --- report ----------------------------------------------------------------------
# session: one systemMessage for the user, or nothing at all.
if [ "$mode" = session ]; then
  [ "${#messages[@]}" = 0 ] && exit 0
  joined="$(printf '%s; ' "${messages[@]}")"; joined="${joined%; }"
  joined="${joined//\\/\\\\}"; joined="${joined//\"/\\\"}"            # JSON-escape
  printf '{"systemMessage":"gitflow: %s"}\n' "$joined"
  exit 0
fi
if [ "${#messages[@]}" = 0 ]; then echo "ok: no merged local branches"; else printf 'ok: %s\n' "${messages[@]}" | sed 's/^ok: plan:/plan:/'; fi
exit 0
