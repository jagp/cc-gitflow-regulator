#!/usr/bin/env bash
# cc-gitflow-regulator finish-feature — deterministic Sourcetree-style "Finish Feature".
#
# Modes (wired to the /finish-feature command in commands/finish-feature.md):
#   plan   <branch>   read-only: resolve branch/base/worktree/session and print
#                     exactly what `finish` would do; makes NO changes (no refs
#                     created, no fetch)
#   finish <branch> [--keep-branch] [--stash-changes|--discard-changes]
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
# The remote branch is NEVER deleted: finish runs `git fetch --prune` to drop
# stale remote-tracking refs and reports whether origin/<branch> still exists.
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

branch_arg=""; keep_branch=0; stash_changes=0; discard_changes=0
for a in "$@"; do
  case "$a" in
    --keep-branch) keep_branch=1 ;;
    --stash-changes) stash_changes=1 ;;
    --discard-changes) discard_changes=1 ;;
    --*) echo "error: unknown flag $a" >&2; exit 2 ;;
    *) branch_arg="$a" ;;
  esac
done
[ "$stash_changes$discard_changes" = "11" ] \
  && { echo "error: --stash-changes and --discard-changes are mutually exclusive" >&2; exit 2; }

case "$mode" in plan|finish) ;; *)
  echo "usage: finish-feature.sh plan|finish <branch> [--keep-branch] [--stash-changes|--discard-changes]" >&2
  exit 2 ;;
esac

fail() { echo "error: $*" >&2; exit 2; }

# --- main checkout root (works when invoked from a worktree) ----------------
common="$(git rev-parse --path-format=absolute --git-common-dir 2>/dev/null)" \
  || fail "not inside a git repository"
root="${common%/.git}"
G() { git -C "$root" "$@"; }

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
    st="clean"; [ -n "$(git -C "$wt_dir" status --porcelain -- . ':(exclude).claude' 2>/dev/null)" ] && st="DIRTY"
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
      echo "plan: remote        origin/$branch exists — finish will fetch --prune and report it; remote branches are NEVER auto-deleted"
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
  leftovers="$(git -C "$wt_dir" status --porcelain -- . ':(exclude).claude' 2>/dev/null)"
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
  if [ "$wt_attached" = "1" ]; then
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

**When this PR is merged, the finish is not done yet** — run \`/finish-feature $branch\` again to resume it. The command will detect the branch is now contained in \`$base\` and complete the remaining steps: verify the worktree lock is released, and (with your go-ahead) kill the attached session and delete the branch."
      url="$(cd "$root" && gh pr create --base "$base" --head "$branch" \
        --title "Merge $branch into $base" \
        --body "$pr_body" 2>/dev/null)"
      [ -n "$url" ] && echo "conflict: PR opened: $url" || echo "conflict: branch pushed; open the PR manually (gh pr create failed)"
    else
      echo "conflict: branch pushed to origin; open a PR into $base manually (gh not installed)"
    fi
    echo "conflict: branch and worktree left intact — re-run /finish-feature $branch after the PR merges to resume"
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

# stop_job: end the background job whose session holds the worktree.
#   1. find every process whose command line carries the job's session id
#      (never this script itself) and stop it
#   2. pause so Windows releases the folder handles the dead processes held
#   3. delete the job's record directory
# Called from the worktree-removal step only (Phase 5), when removal failed.
stop_job() {
  if [ -n "$job_session" ]; then
    if command -v powershell.exe >/dev/null 2>&1; then
      SID="$job_session" powershell.exe -NoProfile -Command '
        Get-CimInstance Win32_Process |
          Where-Object { $_.CommandLine -match [regex]::Escape($env:SID) -and $_.ProcessId -ne $PID } |
          ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }' >/dev/null 2>&1
    elif command -v pgrep >/dev/null 2>&1; then
      for process_id in $(pgrep -f "$job_session" 2>/dev/null); do
        [ "$process_id" != "$$" ] && kill "$process_id" 2>/dev/null
      done
    fi
    sleep 1   # let the OS release the dead processes' cwd handles (Windows EBUSY)
  fi
  rm -rf "$job_dir"
}

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
    elif [ "$wt_attached" = "0" ]; then
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
      removed=0
      for _try in 1 2 3; do
        if G worktree remove "$wt_dir" 2>/dev/null || G worktree remove --force "$wt_dir" 2>/dev/null; then
          removed=1; break
        fi
        sleep 1   # transient EBUSY: handles can take a beat to release after a kill
      done
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
    echo "ok: deleted branch $branch (its work is in $long_lived_holder)"
  else
    echo "warn: could not delete $branch — left in place" >&2
    incomplete=1
  fi
fi

# Phase 6: sync remote-tracking refs — report, never touch, the remote branch.
if G remote get-url origin >/dev/null 2>&1; then
  if G fetch --prune --quiet origin 2>/dev/null; then
    if G show-ref --verify -q "refs/remotes/origin/$branch"; then
      echo "note: origin/$branch still exists on the remote — left alone (finish never deletes remote branches); remove it yourself with: git push origin --delete $branch"
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
