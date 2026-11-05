#!/usr/bin/env bash
# cc-gitflow-regulator finish-feature — deterministic Sourcetree-style "Finish Feature".
#
# Modes (wired to the /finish-feature command in commands/finish-feature.md):
#   plan   <branch>   read-only: resolve branch/base/worktree/session and print
#                     exactly what `finish` would do; makes NO changes (no refs
#                     created, no fetch)
#   finish <branch> [--keep-branch] [--stash-changes|--discard-changes] [--kill-stalled-session]
#                     merge <branch> into the gitflow base with --no-ff, then
#                     push the base to origin (CC_GITFLOW_REGULATOR_PUSH_MERGED=0
#                     turns that off). On conflict: abort, push the branch and
#                     open a PR instead. Then the worktree is removed and
#                     the local branch deleted, unless:
#                       --keep-branch    keep the worktree and the local branch
#                     Leftover (uncommitted/untracked) files in the worktree make
#                     finish refuse before merging, unless one of:
#                       --stash-changes    stash them (outlives the worktree)
#                       --discard-changes  let them go with the worktree
#                     If a BLOCKED background job holds the worktree, finish
#                     prints `ask: kill-stalled ...`; the re-run after the
#                     user's yes adds:
#                       --kill-stalled-session  stop that job, then remove
#
# Branch resolution is local-first: if no local branch matches but an
# origin/<candidate> does (background sessions publish to origin without ever
# creating a local branch), `plan` announces it and `finish` creates the local
# branch from the remote-tracking ref before proceeding.
#
# Worktree resolution knows about DETACHED worktrees: both the regulator's
# SessionEnd hook and harness background sessions leave managed worktrees on a
# detached HEAD (releasing the branch locally IS the delivery), so the branch
# is never checked out there. Those are recovered via the plugin's own naming
# contract (rename hook): .claude/worktrees/<name> <-> <prefix><name>.
#
# What reaches origin, exactly:
#   - pushed:  the base branch after a clean merge (CC_GITFLOW_REGULATOR_PUSH_MERGED=0
#              turns this off); the feature branch on a merge conflict, for its PR
#   - deleted: origin/<branch> only via the delete-remote mode, which the
#              /finish-feature command runs only after the user says yes to the
#              `ask: delete-remote` line, and only if origin hasn't moved
#   - never:   a force push, or any other branch
#
#   delete-remote <branch> <sha>
#                     delete origin/<branch> if it still points at <sha>
#
# Unlike the hook script (cc-gitflow-regulator.sh), this is user-invoked and
# MUST fail loudly. Exit codes:
#   0 ok   2 refused/preflight failed   3 merge conflict (PR route taken)
#   4 cleanup incomplete
#
# Configuration: CC_GITFLOW_REGULATOR_PREFIX, CC_GITFLOW_REGULATOR_BASE (same as hooks),
# CC_GITFLOW_REGULATOR_PUSH_MERGED (default on; 0 keeps the merge local),
# CC_GITFLOW_REGULATOR_JOBS_DIR (job-state location; default ~/.claude/jobs — meant
# for tests).
set -u

mode="${1:-}"; shift 2>/dev/null || true
PREFIX="${CC_GITFLOW_REGULATOR_PREFIX:-feature/}"
BASE_OVERRIDE="${CC_GITFLOW_REGULATOR_BASE:-}"
JOBS_DIR="${CC_GITFLOW_REGULATOR_JOBS_DIR:-$HOME/.claude/jobs}"
# Push the merged base to origin unless switched off (0/false/off/no).
case "$(printf '%s' "${CC_GITFLOW_REGULATOR_PUSH_MERGED:-1}" | tr '[:upper:]' '[:lower:]')" in
  0|false|off|no) push_merged=0 ;;
  *) push_merged=1 ;;
esac

# delete-remote takes two positionals (branch, sha) and no flags: take them
# here so the flag loop below sees nothing.
remote_branch=""; remote_sha=""
if [ "$mode" = "delete-remote" ]; then
  remote_branch="${1:-}"; remote_sha="${2:-}"; set --
fi

branch_arg=""; keep_branch=0; kill_stalled=0; stash_changes=0; discard_changes=0
for a in "$@"; do
  case "$a" in
    --keep-branch) keep_branch=1 ;;
    --kill-stalled-session) kill_stalled=1 ;;
    --stash-changes) stash_changes=1 ;;
    --discard-changes) discard_changes=1 ;;
    --*) echo "error: unknown flag $a" >&2; exit 2 ;;
    *) branch_arg="$a" ;;
  esac
done
[ "$stash_changes$discard_changes" = "11" ] \
  && { echo "error: --stash-changes and --discard-changes are mutually exclusive" >&2; exit 2; }

case "$mode" in plan|finish|delete-remote) ;; *)
  echo "usage: finish-feature.sh plan|finish <branch> [--keep-branch] [--stash-changes|--discard-changes] [--kill-stalled-session]" >&2
  echo "       finish-feature.sh delete-remote <branch> <sha>" >&2
  exit 2 ;;
esac

fail() { echo "error: $*" >&2; exit 2; }

# --- main checkout root (works when invoked from a worktree) ----------------
common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
  || fail "not inside a git repository"
root="${common%/.git}"
G() { git -C "$root" "$@"; }

# ============================== delete-remote ================================
# Run only after the user said yes to an `ask: delete-remote <branch> <sha>`
# line from finish. Deletes origin/<branch>, but only if origin still points
# at <sha> — the commit finish checked. If anyone pushed to the branch since,
# git rejects the delete and nothing is lost (--force-with-lease).
if [ "$mode" = "delete-remote" ]; then
  [ -n "$remote_branch" ] && [ -n "$remote_sha" ] \
    || fail "usage: finish-feature.sh delete-remote <branch> <sha>"
  G remote get-url origin >/dev/null 2>&1 || fail "no origin remote"
  if G push -q --force-with-lease="refs/heads/$remote_branch:$remote_sha" origin ":refs/heads/$remote_branch" 2>/dev/null; then
    echo "ok: deleted origin/$remote_branch (it was still at ${remote_sha:0:7})"
    exit 0
  fi
  fail "origin/$remote_branch was not deleted — it moved since finish checked it (someone pushed), or origin is unreachable"
fi

# --- resolve target branch ---------------------------------------------------
print_candidates() {
  local list; list="$(G for-each-ref --format='%(refname:short)' \
    "refs/heads/${PREFIX}" refs/heads/feature refs/heads/bugfix refs/heads/hotfix | sort -u)"
  if [ -n "$list" ]; then
    echo "candidates:" >&2; printf '%s\n' "$list" >&2
  else
    echo "candidates: (none — no local feature/bugfix/hotfix branches)" >&2
    local rlist; rlist="$(G for-each-ref --format='%(refname:short)' \
      "refs/remotes/origin/${PREFIX}" refs/remotes/origin/feature \
      refs/remotes/origin/bugfix refs/remotes/origin/hotfix 2>/dev/null | sort -u)"
    if [ -n "$rlist" ]; then
      echo "candidates: origin-only work branches (name one and finish will adopt it locally):" >&2
      printf '%s\n' "$rlist" | sed 's/^/candidates:   /' >&2
    fi
  fi
}
resolve_branch() {
  local b="$1"
  if [ -n "$b" ]; then
    for c in "$b" "${PREFIX}${b}" "feature/$b" "bugfix/$b" "hotfix/$b"; do
      if G show-ref --verify -q "refs/heads/$c"; then printf '%s' "$c"; return 0; fi
    done
    # Local-first fallback: the branch may exist only as a remote-tracking ref
    # (a background session pushed it; no local branch was ever created).
    for c in "$b" "${PREFIX}${b}" "feature/$b" "bugfix/$b" "hotfix/$b"; do
      if G show-ref --verify -q "refs/remotes/origin/$c"; then printf 'remote:%s' "$c"; return 0; fi
    done
    print_candidates
    return 1
  fi
  # no argument: current branch if it looks like a gitflow work branch
  b="$(git symbolic-ref --short -q HEAD || true)"
  case "$b" in
    "$PREFIX"*|feature/*|bugfix/*|hotfix/*) printf '%s' "$b"; return 0 ;;
  esac
  # else: exactly one candidate branch in the repo
  local list; list="$(G for-each-ref --format='%(refname:short)' \
    "refs/heads/${PREFIX}" refs/heads/feature refs/heads/bugfix refs/heads/hotfix | sort -u)"
  if [ "$(printf '%s\n' "$list" | grep -c .)" = "1" ]; then printf '%s' "$list"; return 0; fi
  print_candidates
  return 1
}

resolved="$(resolve_branch "$branch_arg")" \
  || fail "cannot resolve a single work branch — pass one explicitly (see candidates above)"
branch_is_remote_only=0
case "$resolved" in
  remote:*) branch="${resolved#remote:}"; branch_is_remote_only=1 ;;
  *) branch="$resolved" ;;
esac

# --- resolve base branch -----------------------------------------------------
# 1. The base start-feature.sh recorded for this branch (git-flow's key), if
#    that branch still exists locally — it is where the feature came from.
# 2. Else CC_GITFLOW_REGULATOR_BASE, else the first of develop/dev.
base=""
recorded_base="$(G config --get "gitflow.branch.$branch.base" 2>/dev/null || true)"
if [ -n "$recorded_base" ] && G show-ref --verify -q "refs/heads/$recorded_base"; then
  base="$recorded_base"
elif [ -n "$BASE_OVERRIDE" ]; then
  G show-ref --verify -q "refs/heads/$BASE_OVERRIDE" \
    || fail "CC_GITFLOW_REGULATOR_BASE=$BASE_OVERRIDE is not a local branch"
  base="$BASE_OVERRIDE"
else
  for b in develop dev; do
    if G show-ref --verify -q "refs/heads/$b"; then base="$b"; break; fi
  done
fi
[ -n "$base" ] || fail "no local base branch (develop/dev) — set CC_GITFLOW_REGULATOR_BASE"
[ "$branch" = "$base" ] && fail "refusing: $branch is the base branch"

# --- adopt an origin-only branch (finish) / pick the computation ref ---------
# plan stays read-only: it computes against the remote-tracking ref and only
# announces the adoption; finish actually creates the local branch.
merge_ref="$branch"
if [ "$branch_is_remote_only" = "1" ]; then
  if [ "$mode" = "finish" ]; then
    G branch "$branch" "refs/remotes/origin/$branch" 2>/dev/null \
      || fail "could not create local branch $branch from origin/$branch"
    echo "ok: created local branch $branch from origin/$branch (no local branch existed)"
    branch_is_remote_only=0
  else
    merge_ref="refs/remotes/origin/$branch"
  fi
fi

ahead="$(G rev-list --count "$base..$merge_ref" 2>/dev/null || echo 0)"

# --- locate the worktree holding the branch ---------------------------------
wt_dir=""; wt_locked=0
while IFS= read -r line; do
  case "$line" in
    "worktree "*) cur="${line#worktree }" ;;
    "branch refs/heads/$branch") wt_dir="$cur" ;;
    "locked"*) [ "${cur:-}" = "$wt_dir" ] && [ -n "$wt_dir" ] && wt_locked=1 ;;
  esac
done <<EOF
$(G worktree list --porcelain)
EOF
[ "$wt_dir" = "$root" ] && wt_dir=""   # branch checked out in the main clone is not a lock

# norm: case/separator-insensitive path compare; -s squeezes the '//' left
# behind when a JSON-escaped '\\' path was read without jq.
norm() { printf '%s' "$1" | tr 'A-Z\\' 'a-z/' | tr -s '/'; }

# Fallback: managed worktrees on a DETACHED HEAD never match the scan above
# (the branch is not checked out anywhere — see header). Recover them by the
# rename hook's naming contract: .claude/worktrees/<name> <-> <prefix><name>.
# Only detached worktrees qualify; one holding a DIFFERENT branch is other work.
wt_attached=1
if [ -z "$wt_dir" ]; then
  short="$(norm "${branch##*/}")"
  cur=""
  while IFS= read -r line; do
    case "$line" in
      "worktree "*) cur="${line#worktree }" ;;
      detached)
        bn="$(basename "$(norm "$cur")")"; bn="${bn#worktree-}"
        if [ "$bn" = "$short" ]; then
          case "$(norm "$cur")" in
            "$(norm "$root")"/.claude/worktrees/*) wt_dir="$cur"; wt_attached=0 ;;
          esac
        fi ;;
      "locked"*) [ -n "$wt_dir" ] && [ "${cur:-}" = "$wt_dir" ] && wt_locked=1 ;;
    esac
  done <<EOF
$(G worktree list --porcelain)
EOF
fi

# Last fallback: an ORPHAN folder. A failed `git worktree remove` deregisters
# the worktree but can leave its (emptied) folder behind, so git no longer
# lists it. A folder for this branch under .claude/worktrees with no .git
# inside is that leftover: it holds no git data and finish only deletes it.
# Every `git -C "$wt_dir"` below is skipped for it — with no .git inside, git
# would run against the main checkout instead.
wt_orphan=0
if [ -z "$wt_dir" ]; then
  for candidate in "$root/.claude/worktrees/$short" "$root/.claude/worktrees/worktree-$short"; do
    if [ -d "$candidate" ] && [ ! -e "$candidate/.git" ]; then
      wt_dir="$candidate"; wt_attached=0; wt_orphan=1; break
    fi
  done
fi

wt_is_managed=0
case "$(norm "$wt_dir")" in */.claude/worktrees/*) wt_is_managed=1 ;; esac
here="$(pwd -W 2>/dev/null || pwd)"   # -W: Git Bash prints the Windows-style path
wt_is_self=0
if [ -n "$wt_dir" ]; then
  case "$(norm "$here")/" in "$(norm "$wt_dir")"/*) wt_is_self=1 ;; esac
fi

# --- locate the Claude job/session attached to the worktree ------------------
job_field() { # file key -> value
  if command -v jq >/dev/null 2>&1; then
    jq -r ".$2 // empty" <"$1" 2>/dev/null
  else
    sed -n 's/.*"'"$2"'": *"\([^"]*\)".*/\1/p' "$1" | head -1
  fi
}
# Match by exact worktree path, or — when no worktree was resolved (already
# pruned, but the session may live on) — by the naming contract, scoped to
# THIS repo's managed dir so a same-named worktree of another project can
# never match. More than one match is ambiguous: report and refuse to kill
# rather than pick one.
job_dir=""; job_session=""; job_matches=0; job_ids=""
short="$(norm "${branch##*/}")"
for st in "$JOBS_DIR"/*/state.json; do
  [ -f "$st" ] || continue
  jwt="$(job_field "$st" worktreePath)"
  [ -n "$jwt" ] || continue
  njwt="$(norm "$jwt")"
  match=0
  if [ -n "$wt_dir" ] && [ "$njwt" = "$(norm "$wt_dir")" ]; then
    match=1
  elif [ -z "$wt_dir" ]; then
    case "$njwt" in
      "$(norm "$root")"/.claude/worktrees/*)
        jbn="$(basename "$njwt")"; jbn="${jbn#worktree-}"
        [ "$jbn" = "$short" ] && match=1 ;;
    esac
  fi
  if [ "$match" = "1" ]; then
    job_matches=$((job_matches + 1))
    job_ids="$job_ids $(basename "$(dirname "$st")")"
    if [ -z "$job_dir" ]; then
      job_dir="$(dirname "$st")"
      job_session="$(job_field "$st" sessionId)"
    fi
  fi
done
job_is_self=0
if [ -n "$job_dir" ] && [ -n "${CLAUDE_JOB_DIR:-}" ]; then
  [ "$(basename "$job_dir")" = "$(basename "$CLAUDE_JOB_DIR")" ] && job_is_self=1
fi

# ============================== plan =========================================
if [ "$mode" = "plan" ]; then
  echo "plan: branch        $branch ($ahead commit(s) ahead of $base)"
  [ "$branch_is_remote_only" = "1" ] \
    && echo "plan: adopt         no local branch — finish will create $branch from origin/$branch first"
  src="default"; [ "$base" = "$recorded_base" ] && src="recorded by /start-feature"
  echo "plan: base          $base ($src)"
  if [ -n "$wt_dir" ]; then
    st="clean"
    if [ "$wt_orphan" = "1" ]; then st="ORPHAN — git already dropped this worktree; finish deletes the leftover folder"
    elif [ -n "$(git -C "$wt_dir" status --porcelain -- . ':(exclude).claude' 2>/dev/null)" ]; then st="DIRTY"
    fi
    lk=""; [ "$wt_locked" = "1" ] && lk=", git-locked"
    att=""; [ "$wt_attached" = "0" ] && att=", DETACHED — matched by managed-worktree name"
    slf=""; [ "$wt_is_self" = "1" ] && slf=" (this session's own worktree)"
    echo "plan: worktree      $wt_dir ($st$lk$att)$slf"
    if [ "$st" = "DIRTY" ]; then
      echo "plan: leftovers     uncommitted/untracked files — finish refuses before merging unless --stash-changes or --discard-changes"
    fi
  else
    echo "plan: worktree      none — branch is not checked out anywhere"
  fi
  if [ "$job_matches" -gt 1 ]; then
    echo "plan: session       AMBIGUOUS — jobs matching this worktree:$job_ids — finish will not kill any of them"
  elif [ -n "$job_dir" ]; then
    slf=""; [ "$job_is_self" = "1" ] && slf=" (this session — will refuse to kill)"
    echo "plan: session       job $(basename "$job_dir"), session $job_session$slf"
  elif [ -n "$wt_dir" ]; then
    echo "plan: session       none found — if worktree removal fails (EBUSY), some process still holds the folder"
  else
    echo "plan: session       none found for this worktree"
  fi
  if [ "$ahead" = "0" ]; then
    echo "plan: merge         nothing to merge (already in $base) — finish = cleanup only"
  elif G merge-tree --write-tree "$base" "$merge_ref" >/dev/null 2>&1; then
    echo "plan: merge         clean --no-ff merge into $base expected"
  elif G merge-tree --write-tree "$base" "$merge_ref" 2>/dev/null | grep -q .; then
    echo "plan: merge         CONFLICTS expected — finish will push + open a PR instead"
  else
    echo "plan: merge         conflict prediction unavailable (git < 2.38) — finish will try and abort safely"
  fi
  if [ "$push_merged" = "0" ]; then
    echo "plan: push          off (CC_GITFLOW_REGULATOR_PUSH_MERGED) — $base stays local"
  elif G remote get-url origin >/dev/null 2>&1; then
    echo "plan: push          finish will push $base to origin after the merge"
  else
    echo "plan: push          no origin remote — nothing will be pushed"
  fi
  if G remote get-url origin >/dev/null 2>&1; then
    if G show-ref --verify -q "refs/remotes/origin/$branch"; then
      echo "plan: remote        origin/$branch exists — after cleanup finish will ask before deleting it (only if it holds nothing beyond your branch)"
    else
      echo "plan: remote        no origin/$branch known locally — finish will fetch --prune to sync"
    fi
  fi
  if [ "$keep_branch" = "1" ]; then
    echo "plan: cleanup       keep worktree and $branch (--keep-branch)"
  else
    case " develop dev main master $BASE_OVERRIDE " in
      *" $base "*) echo "plan: cleanup       remove worktree (if any) + delete $branch (--keep-branch skips this)" ;;
      *) echo "plan: cleanup       keep worktree and $branch — $base is temporary; deleted on a re-run once $base lands in develop/main" ;;
    esac
  fi
  exit 0
fi

# ============================== finish =======================================
# Phase 1: preflight — never start a merge we may not be able to complete.
# -uno: untracked files (e.g. .claude/worktrees/ itself) never block a finish;
# tracked modifications do. .claude/worktrees is excluded entirely: worktrees
# accidentally committed as gitlinks (git add -A) must not brick the finish.
[ -n "$(G status --porcelain -uno -- . ':(exclude).claude/worktrees' 2>/dev/null)" ] \
  && fail "main checkout has uncommitted changes — commit or stash them first"
G rev-parse -q --verify MERGE_HEAD >/dev/null 2>&1 \
  && fail "main checkout has a merge in progress"
# Leftovers in the worktree (uncommitted or untracked files) are checked
# BEFORE the merge, so forgotten work can still be committed and merged.
# The script cannot tell which kind of leftover it is looking at, so it only
# acts on an explicit flag:
#   none               -> refuse and list the files (commit them, then re-run)
#   --stash-changes    -> stash them; the stash lives in the shared repo refs,
#                         so it outlives the worktree; apply it on a new branch
#   --discard-changes  -> let them go with the worktree
# .claude/ is excluded: Claude Code writes local settings there.
if [ -n "$wt_dir" ]; then
  [ "$wt_is_managed" = "1" ] \
    || fail "worktree $wt_dir was not created by Claude — release it yourself, then re-run"
  leftovers=""; stash_sha=""
  [ "$wt_orphan" = "1" ] || leftovers="$(git -C "$wt_dir" status --porcelain -- . ':(exclude).claude' 2>/dev/null)"
  if [ -n "$leftovers" ]; then
    if [ "$stash_changes" = "1" ]; then
      git -C "$wt_dir" stash push -u -q -m "finish-feature: leftovers from $branch" -- . ':(exclude).claude' \
        || fail "could not stash the leftovers in $wt_dir"
      stash_sha="$(G rev-parse -q --verify stash@{0})"   # the sha stays valid as other stashes land
      echo "ok: stashed the worktree's leftovers as $stash_sha — to continue them: /start-feature <name>, then git stash apply $stash_sha"
    elif [ "$discard_changes" = "1" ]; then
      echo "warn: discarding the worktree's leftovers (--discard-changes)"
    else
      echo "leftover: $wt_dir has uncommitted or untracked files:" >&2
      printf '%s\n' "$leftovers" | head -20 | sed 's/^/leftover:   /' >&2
      fail "leftovers in the worktree — commit them to $branch and re-run, or re-run with --stash-changes or --discard-changes"
    fi
  fi
fi

# Phase 2: release the lock — detach the worktree so the branch is free.
if [ -n "$wt_dir" ]; then
  [ "$wt_locked" = "1" ] && G worktree unlock "$wt_dir" 2>/dev/null
  if [ "$wt_orphan" = "1" ]; then
    echo "ok: $wt_dir is a leftover folder git already dropped — no branch lock to release"
  elif [ "$wt_attached" = "1" ]; then
    git -C "$wt_dir" switch --detach -q || fail "could not detach worktree $wt_dir"
    echo "ok: released $branch from $wt_dir"
  else
    echo "ok: $branch is not checked out in $wt_dir (already detached) — no branch lock to release"
  fi
fi

# Phase 3: merge into base (or PR route on conflict).
G switch -q "$base" || fail "could not switch main checkout to $base"
if G rev-parse -q --verify "@{upstream}" >/dev/null 2>&1; then
  G pull --ff-only -q 2>/dev/null || echo "warn: $base diverged from upstream; merging into local $base"
fi
if [ "$ahead" = "0" ]; then
  echo "ok: $branch is already contained in $base — skipping merge"
elif G merge --no-ff --no-edit -m "Merge branch '$branch' into $base" "$branch" >/dev/null 2>&1; then
  echo "ok: merged $branch into $base (--no-ff): $(G rev-parse --short HEAD)"
else
  conflicts="$(G diff --name-only --diff-filter=U 2>/dev/null)"
  G merge --abort 2>/dev/null
  echo "conflict: merge of $branch into $base conflicts on:"
  printf '%s\n' "$conflicts" | sed 's/^/conflict:   /'
  if G remote get-url origin >/dev/null 2>&1; then
    G push -u origin "$branch" || fail "conflict + push failed — resolve manually"
    if command -v gh >/dev/null 2>&1; then
      pr_body="Opened by /finish-feature: the local --no-ff merge of \`$branch\` into \`$base\` hit conflicts, so the finish switched to the PR route.

**When this PR is merged, the finish is not done yet** — run \`/finish-feature $branch\` again to resume it. The command will detect the branch is now contained in \`$base\` and complete the remaining steps: remove the worktree, delete the local branch, and ask whether to delete this branch on origin too."
      url="$(cd "$root" && gh pr create --base "$base" --head "$branch" \
        --title "Merge $branch into $base" \
        --body "$pr_body" 2>/dev/null)"
      [ -n "$url" ] && echo "conflict: PR opened: $url" || echo "conflict: branch pushed; open the PR manually (gh pr create failed)"
    else
      echo "conflict: branch pushed to origin; open a PR into $base manually (gh not installed)"
    fi
    echo "conflict: branch and worktree left intact — re-run /finish-feature $branch after the PR merges to resume"
    [ -n "${stash_sha:-}" ] && echo "conflict: the worktree's leftovers are in stash $stash_sha, not in the worktree (git stash apply $stash_sha to bring them back)"
  else
    echo "conflict: no remote — resolve the merge manually (branch and worktree left intact)"
  fi
  exit 3
fi

incomplete=0

# Phase 3b: publish the merged base to origin, so the merge exists off this
# machine. Plain push only: if origin has moved, the push is rejected and we
# report it — never force. Off when CC_GITFLOW_REGULATOR_PUSH_MERGED=0.
if [ "$push_merged" = "0" ]; then
  echo "ok: $base not pushed (CC_GITFLOW_REGULATOR_PUSH_MERGED is off)"
elif ! G remote get-url origin >/dev/null 2>&1; then
  echo "ok: checked for an origin remote to push $base to — none configured, nothing pushed"
elif G push -q origin "$base" 2>/dev/null; then
  echo "ok: pushed $base to origin"
else
  echo "warn: could not push $base to origin (rejected or offline) — the merge is local only; push it yourself" >&2
  incomplete=1
fi

# remove_worktree: delete the worktree folder; 0 once the folder is gone.
#   Up to three attempts, a second apart (Windows releases handles slowly):
#   - while git still lists it: `git worktree remove` (then --force)
#   - once git has dropped it: delete the leftover folder directly. A failed
#     `git worktree remove` on a held folder still deregisters the worktree
#     and empties what it can, leaving an unregistered folder git won't touch.
#     It is safe to delete: preflight confirmed it sits under .claude/worktrees.
remove_worktree() {
  local attempt
  # Hard guard for the folder delete below: only a named folder directly
  # under this repo's .claude/worktrees, never an empty or outside path.
  case "$(norm "$wt_dir")" in
    "$(norm "$root")"/.claude/worktrees/?*) ;;
    *) echo "warn: refusing to delete $wt_dir — not under $root/.claude/worktrees" >&2; return 1 ;;
  esac
  for attempt in 1 2 3; do
    if G worktree list --porcelain | grep -qxF "worktree $wt_dir"; then
      G worktree remove "$wt_dir" 2>/dev/null || G worktree remove --force "$wt_dir" 2>/dev/null
    else
      rm -rf "$wt_dir" 2>/dev/null
    fi
    [ -e "$wt_dir" ] || return 0
    sleep 1
  done
  return 1
}

# stop_job: end the background job whose session holds the worktree.
#   1. list this script's own ancestors (its shell, the Claude session that
#      ran it, ...). They are never stopped: a session resumed from the job
#      (`claude --resume <id>`) carries the same id in its command line
#   2. find every other process whose command line carries the session id
#   3. add all their descendants: a session's tool shells (and their console
#      hosts) run inside the worktree but don't carry the session id
#   4. stop them all, then pause so Windows releases the folder handles
#   5. delete the job's record directory
# Called from the worktree-removal step only (Phase 5), when removal failed.
stop_job() {
  if [ -n "$job_session" ]; then
    if command -v powershell.exe >/dev/null 2>&1; then
      # Git Bash keeps its own process tree; Windows parent ids stop at its
      # boundary. So collect our Git Bash ancestors' Windows pids here
      # (/proc/<pid>/winpid) and let PowerShell walk up from each of them too.
      own_chain=""; walk="$$"
      while [ -r "/proc/$walk/winpid" ]; do
        own_chain="$own_chain $(cat "/proc/$walk/winpid")"
        walk="$(cat "/proc/$walk/ppid" 2>/dev/null)"
        [ "${walk:-0}" -gt 1 ] 2>/dev/null || break
      done
      SID="$job_session" OWN_CHAIN="$own_chain" powershell.exe -NoProfile -Command '
        $all = @(Get-CimInstance Win32_Process)
        $byId = @{}; $all | ForEach-Object { $byId[[int]$_.ProcessId] = $_ }
        $ancestors = @()
        $starts = @([int]$PID) + @(($env:OWN_CHAIN -split " ") | Where-Object { $_ } | ForEach-Object { [int]$_ })
        foreach ($start in $starts) {   # from each, up to the root
          $walk = $start
          while ($byId.ContainsKey($walk) -and $ancestors -notcontains $walk) {
            $ancestors += $walk; $walk = [int]$byId[$walk].ParentProcessId
          }
        }
        $ids = @($all | Where-Object { $_.CommandLine -match [regex]::Escape($env:SID) -and $ancestors -notcontains $_.ProcessId } |
                 ForEach-Object { $_.ProcessId })
        do {   # walk down the tree until no new children turn up
          $children = @($all | Where-Object { $ids -contains $_.ParentProcessId -and $ids -notcontains $_.ProcessId -and $ancestors -notcontains $_.ProcessId } |
                        ForEach-Object { $_.ProcessId })
          $ids += $children
        } while ($children.Count -gt 0)
        $ids | ForEach-Object { Stop-Process -Id $_ -Force -ErrorAction SilentlyContinue }' >/dev/null 2>&1
    elif command -v pgrep >/dev/null 2>&1; then
      ancestors=" "; walk="$$"
      while [ -n "$walk" ] && [ "$walk" -gt 1 ] 2>/dev/null; do   # up to init
        ancestors="$ancestors$walk "; walk="$(ps -o ppid= -p "$walk" 2>/dev/null | tr -d ' ')"
      done
      for process_id in $(pgrep -f "$job_session" 2>/dev/null); do
        case "$ancestors" in *" $process_id "*) continue ;; esac
        pkill -P "$process_id" 2>/dev/null   # its direct children first
        kill "$process_id" 2>/dev/null
      done
    fi
    sleep 1   # let the OS release the dead processes' cwd handles (Windows EBUSY)
  fi
  rm -rf "$job_dir"
}

# The branch's tip, remembered before Phase 5 may delete it: Phase 6 compares
# origin's copy against it.
branch_tip="$(G rev-parse -q --verify "refs/heads/$branch")"
branch_deleted=0

# Phase 5: delete worktree + branch (default; --keep-branch skips it).
# Deletion waits until a LONG-LIVED branch holds the work: develop, dev, main,
# master, or CC_GITFLOW_REGULATOR_BASE. A release/hotfix base is temporary and
# gets deleted itself, so a feature merged only into one is kept until that
# base lands in a long-lived branch.
long_lived_holder=""
for candidate in develop dev main master $BASE_OVERRIDE; do
  if G show-ref --verify -q "refs/heads/$candidate"      && G merge-base --is-ancestor "$branch" "$candidate" 2>/dev/null; then
    long_lived_holder="$candidate"; break
  fi
done
if [ "$keep_branch" = "1" ]; then
  echo "ok: worktree and branch $branch kept (--keep-branch)"
elif [ -z "$long_lived_holder" ]; then
  echo "ok: worktree and branch $branch kept — its work is only in $base, a temporary branch; re-run /finish-feature $branch once $base is merged into develop or main"
else
  wt_remaining=0   # 1 when the worktree survives; the branch then stays too (below)
  if [ -n "$wt_dir" ]; then
    keep_wt=0; removed=1   # removed is set to 0 only by a failed removal attempt
    if [ "$wt_is_self" = "1" ]; then
      echo "warn: not removing $wt_dir — this session is running inside it; to finish the cleanup, run /finish-feature $branch from a session in $root"
      incomplete=1; keep_wt=1
    elif [ "$wt_attached" = "0" ] && [ "$wt_orphan" = "0" ]; then
      # A detached worktree may hold committed work that no branch name
      # protects — `git branch -d` below guards the BRANCH, nothing guards a
      # detached tip. Refuse rather than lose commits.
      wt_head="$(git -C "$wt_dir" rev-parse HEAD 2>/dev/null || true)"
      if [ -n "$wt_head" ] \
         && ! G merge-base --is-ancestor "$wt_head" "$base" 2>/dev/null \
         && ! G merge-base --is-ancestor "$wt_head" "$branch" 2>/dev/null; then
        echo "warn: $wt_dir is detached at $(G rev-parse --short "$wt_head" 2>/dev/null || echo "$wt_head") with commits not in $base or $branch — refusing to remove (they would be lost); inspect: git log $wt_head" >&2
        incomplete=1; keep_wt=1
      fi
    fi
    if [ "$keep_wt" = "0" ]; then
      remove_worktree && removed=1 || removed=0
      # Removal failed: something holds the folder. If that is a background
      # job (the only kind of session with a record to match), act on the
      # job's recorded state:
      #   done/failed -> it is over but still holds the lock: stop it, retry
      #   blocked     -> it may be waiting on the user: stop it only with
      #                  --kill-stalled-session, otherwise ask (ask: line)
      #   anything else, several matches, or this session -> never stop it
      if [ "$removed" = "0" ] && [ "$job_matches" = "1" ] && [ "$job_is_self" = "0" ]; then
        job_state="$(job_field "$job_dir/state.json" state)"
        job_id="$(basename "$job_dir")"
        stop_it=0
        case "$job_state" in
          done|failed) stop_it=1 ;;
          blocked)
            if [ "$kill_stalled" = "1" ]; then stop_it=1
            else echo "ask: kill-stalled $job_id ($job_state) — background job holds $wt_dir; re-run with the same flags plus --kill-stalled-session to stop it"
            fi ;;
          *) echo "warn: background job $job_id ($job_state) holds $wt_dir and may still be working — not stopped" >&2 ;;
        esac
        if [ "$stop_it" = "1" ]; then
          stop_job
          if remove_worktree; then
            removed=1
            echo "ok: stopped background job $job_id ($job_state) that held the worktree, and removed it"
          else
            echo "warn: stopped background job $job_id ($job_state), but the folder is still held — something else has it open" >&2
          fi
        fi
      elif [ "$removed" = "0" ] && [ "$job_matches" -gt 1 ]; then
        echo "warn: several background jobs match $wt_dir:$job_ids — not stopping any" >&2
      fi
      if [ "$removed" = "0" ]; then
        echo "warn: could not remove worktree $wt_dir — some process is holding it (any process whose cwd is inside locks the folder on Windows); close sessions/terminals there and re-run" >&2
        incomplete=1
      fi
    fi
    [ "$keep_wt" = "1" ] || [ "$removed" = "0" ] && wt_remaining=1
    G worktree prune 2>/dev/null
  fi
  # A surviving worktree keeps its branch: the re-run that cleans the worktree
  # up finds it through the branch name.
  if [ "$wt_remaining" = "1" ]; then
    echo "ok: branch $branch kept until its worktree is removed — re-run /finish-feature $branch to finish the cleanup"
  # -D, not -d: git's own -d check compares against whatever the main checkout
  # has checked out, not develop/main. The long-lived containment check above
  # is the real guard, and it already passed.
  elif G branch -D "$branch" >/dev/null 2>&1; then
    G config --remove-section "gitflow.branch.$branch" 2>/dev/null   # branch -d only clears branch.<name>.*
    branch_deleted=1
    echo "ok: deleted branch $branch (its work is in $long_lived_holder)"
  else
    echo "warn: could not delete $branch — left in place" >&2
    incomplete=1
  fi
fi

# Phase 6: the branch on origin. Finish never deletes it itself.
#   1. fetch --prune so origin/<branch> reflects origin right now
#   2. local branch deleted AND origin/<branch> holds nothing the deleted
#      branch lacked -> print `ask: delete-remote <branch> <sha>`; on the
#      user's yes the command runs the delete-remote mode, which only goes
#      through if origin is still at <sha>
#   3. origin has commits the local branch never had -> leave it, say so
#   4. local branch kept -> leave origin's copy too
if G remote get-url origin >/dev/null 2>&1; then
  if G fetch --prune --quiet origin 2>/dev/null; then
    if G show-ref --verify -q "refs/remotes/origin/$branch"; then
      remote_tip="$(G rev-parse "refs/remotes/origin/$branch")"
      if [ "$branch_deleted" = "0" ]; then
        echo "note: origin/$branch left alone — the local branch was kept too"
      elif G merge-base --is-ancestor "$remote_tip" "$branch_tip" 2>/dev/null; then
        echo "ask: delete-remote $branch $remote_tip — origin/$branch holds nothing beyond the merged work; delete it too?"
      else
        echo "note: origin/$branch has $(G rev-list --count "$branch_tip..$remote_tip") commit(s) the local branch never had (someone else pushed) — left alone"
      fi
    else
      echo "ok: origin/$branch is not on the remote — stale tracking refs pruned"
    fi
  else
    echo "warn: git fetch --prune origin failed (offline?) — remote-tracking refs may be stale"
  fi
fi

echo "done: $branch -> $base on $(G rev-parse --short "$base")"
[ "$incomplete" = "1" ] && exit 4
exit 0
