#!/usr/bin/env bash
# cc-gitflow-regulator finish-branch — deterministic Sourcetree-style "Finish Feature".
#
# Modes (wired to the /finish-branch command in commands/finish-branch.md):
#   plan   <branch>   read-only: resolve branch/base/worktree/session and print
#                     exactly what `finish` would do; makes NO changes (no refs
#                     created, no fetch)
#   finish <branch> [--kill-session] [--delete-branch]
#                     merge <branch> into the gitflow base with --no-ff.
#                     On conflict: abort, push the branch and open a PR instead
#                     (the only case where anything is pushed). Destructive
#                     steps are OFF unless their flag is passed:
#                       --kill-session   kill the Claude session attached to the
#                                        branch's worktree and delete its job dir
#                       --delete-branch  remove the worktree and delete the branch
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
# CC_GITFLOW_REGULATOR_JOBS_DIR (job-state location; default ~/.claude/jobs — meant
# for tests).
set -u

mode="${1:-}"; shift 2>/dev/null || true
PREFIX="${CC_GITFLOW_REGULATOR_PREFIX:-feature/}"
BASE_OVERRIDE="${CC_GITFLOW_REGULATOR_BASE:-}"
JOBS_DIR="${CC_GITFLOW_REGULATOR_JOBS_DIR:-$HOME/.claude/jobs}"

branch_arg=""; kill_session=0; delete_branch=0
for a in "$@"; do
  case "$a" in
    --kill-session) kill_session=1 ;;
    --delete-branch) delete_branch=1 ;;
    --*) echo "error: unknown flag $a" >&2; exit 2 ;;
    *) branch_arg="$a" ;;
  esac
done

case "$mode" in plan|finish) ;; *)
  echo "usage: finish-branch.sh plan|finish <branch> [--kill-session] [--delete-branch]" >&2
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
base=""
if [ -n "$BASE_OVERRIDE" ]; then
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
  echo "plan: base          $base"
  if [ -n "$wt_dir" ]; then
    st="clean"; [ -n "$(git -C "$wt_dir" status --porcelain 2>/dev/null)" ] && st="DIRTY"
    lk=""; [ "$wt_locked" = "1" ] && lk=", git-locked"
    att=""; [ "$wt_attached" = "0" ] && att=", DETACHED — matched by managed-worktree name"
    slf=""; [ "$wt_is_self" = "1" ] && slf=" (this session's own worktree)"
    echo "plan: worktree      $wt_dir ($st$lk$att)$slf"
    if [ "$st" = "DIRTY" ]; then
      if [ "$ahead" = "0" ]; then
        echo "plan: NOTE          uncommitted worktree changes are NOT in $base — --delete-branch will DISCARD them"
      else
        echo "plan: NOTE          worktree is DIRTY — finish will refuse until the work is committed"
      fi
    fi
  else
    echo "plan: worktree      none — branch is not checked out anywhere"
  fi
  if [ "$job_matches" -gt 1 ]; then
    echo "plan: session       AMBIGUOUS — jobs matching this worktree:$job_ids — finish will refuse --kill-session"
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
  if G remote get-url origin >/dev/null 2>&1; then
    if G show-ref --verify -q "refs/remotes/origin/$branch"; then
      echo "plan: remote        origin/$branch exists — finish will fetch --prune and report it; remote branches are NEVER auto-deleted"
    else
      echo "plan: remote        no origin/$branch known locally — finish will fetch --prune to sync"
    fi
  fi
  echo "plan: kill-session  $( [ "$job_matches" -gt 1 ] && echo "refuse (ambiguous match)" || { [ -n "$job_dir" ] && echo "kill session process + delete $(basename "$job_dir")" || echo "nothing to do"; } ) [requires --kill-session]"
  echo "plan: delete-branch remove worktree (if any) + git branch -d $branch [requires --delete-branch]"
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
wt_discard=0
if [ -n "$wt_dir" ]; then
  if [ -n "$(git -C "$wt_dir" status --porcelain 2>/dev/null)" ]; then
    # Dirty means unfinished — except when the branch is already contained in
    # the base and the user consented to --delete-branch: the leftovers go
    # with the worktree (the /finish-branch consent prompt spells this out).
    if [ "$ahead" != "0" ] || [ "$delete_branch" != "1" ]; then
      fail "worktree $wt_dir has uncommitted changes — the branch is not finished"
    fi
    wt_discard=1
    echo "warn: worktree has uncommitted changes — discarding them with the worktree (--delete-branch on an already-merged branch)"
  fi
  [ "$wt_is_managed" = "1" ] \
    || fail "worktree $wt_dir was not created by Claude — release it yourself, then re-run"
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
      pr_body="Opened by /finish-branch: the local --no-ff merge of \`$branch\` into \`$base\` hit conflicts, so the finish switched to the PR route.

**When this PR is merged, the finish is not done yet** — run \`/finish-branch $branch\` again to resume it. The command will detect the branch is now contained in \`$base\` and complete the remaining steps: verify the worktree lock is released, and (with your go-ahead) kill the attached session and delete the branch."
      url="$(cd "$root" && gh pr create --base "$base" --head "$branch" \
        --title "Merge $branch into $base" \
        --body "$pr_body" 2>/dev/null)"
      [ -n "$url" ] && echo "conflict: PR opened: $url" || echo "conflict: branch pushed; open the PR manually (gh pr create failed)"
    else
      echo "conflict: branch pushed to origin; open a PR into $base manually (gh not installed)"
    fi
    echo "conflict: branch and worktree left intact — re-run /finish-branch $branch after the PR merges to resume"
  else
    echo "conflict: no remote — resolve the merge manually (branch and worktree left intact)"
  fi
  exit 3
fi

incomplete=0

# Phase 4: kill the attached session (opt-in via --kill-session).
if [ "$kill_session" = "1" ] && [ "$job_matches" -gt 1 ]; then
  echo "warn: multiple jobs match this worktree:$job_ids — ambiguous, refusing to kill; inspect $JOBS_DIR and clean up manually" >&2
  incomplete=1
elif [ "$kill_session" = "1" ] && [ -n "$job_dir" ]; then
  if [ "$job_is_self" = "1" ]; then
    echo "warn: refusing to kill this session's own job ($(basename "$job_dir")) — end the session normally"
  else
    if [ -n "$job_session" ]; then
      if command -v powershell.exe >/dev/null 2>&1; then
        SID="$job_session" powershell.exe -NoProfile -Command '
          Get-CimInstance Win32_Process |
            Where-Object { $_.CommandLine -match [regex]::Escape($env:SID) -and $_.ProcessId -ne $PID } |
            ForEach-Object { Stop-Process -Id $_.ProcessId -Force -ErrorAction SilentlyContinue }' >/dev/null 2>&1
      elif command -v pgrep >/dev/null 2>&1; then
        for p in $(pgrep -f "$job_session" 2>/dev/null); do
          [ "$p" != "$$" ] && kill "$p" 2>/dev/null
        done
      fi
      sleep 1   # let the OS release the dead processes' cwd handles (Windows EBUSY)
    fi
    rm -rf "$job_dir" && echo "ok: session killed and job $(basename "$job_dir") deleted"
  fi
elif [ "$kill_session" = "1" ]; then
  if [ -n "$wt_dir" ]; then
    echo "warn: no session/job matched $wt_dir — nothing killed; if worktree removal fails below, some process still holds the folder (any process whose cwd is inside locks it on Windows)" >&2
  else
    echo "ok: no session/job found for $branch — nothing to kill"
  fi
fi

# Phase 5: delete worktree + branch (opt-in via --delete-branch).
if [ "$delete_branch" = "1" ]; then
  if [ -n "$wt_dir" ]; then
    keep_wt=0
    if [ "$wt_is_self" = "1" ]; then
      echo "warn: not removing $wt_dir — this session is running inside it"
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
        echo "warn: could not remove worktree $wt_dir — some process is holding it (any process whose cwd is inside locks the folder on Windows); close sessions/terminals there or re-run with --kill-session" >&2
        incomplete=1
      fi
    fi
    G worktree prune 2>/dev/null
  fi
  # -d only: git itself verifies the branch is fully merged; never force.
  if G branch -d "$branch" >/dev/null 2>&1; then
    echo "ok: deleted branch $branch"
  else
    echo "warn: git refused to delete $branch (not fully merged?) — left in place" >&2
    incomplete=1
  fi
else
  echo "ok: branch $branch kept (deletion requires --delete-branch)"
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
