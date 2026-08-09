#!/usr/bin/env bash
# cc-gitflow-regulator — gitflow guardrails for Claude Code worktrees.
#
# Subcommands (wired in hooks/hooks.json):
#   rename  PostToolUse[EnterWorktree]  rename the worktree branch to <prefix><name> and,
#                                       for a FRESH worktree only, re-fork it from the
#                                       gitflow base branch (develop by default); stamps
#                                       HEAD so later alerts fire only on new commits
#   notify  Stop                        desktop notification + optional IFTTT webhook when
#                                       new committed work exists (deduped by HEAD sha)
#   end     SessionEnd                  notify, then detach the worktree HEAD so the
#                                       feature branch is free for the main checkout
#                                       (your git client can check it out / merge it)
#
# Delivery model: your own repo is the "remote" — nothing is pushed anywhere.
# Releasing the branch locally IS the delivery.
#
# Configuration (env vars, e.g. via "env" in settings.json):
#   CC_GITFLOW_REGULATOR_PREFIX          branch prefix        (default: feature/)
#   CC_GITFLOW_REGULATOR_BASE            base branch to fork  (default: auto-detect
#                                    develop, dev, origin/develop, origin/dev)
#   CC_GITFLOW_REGULATOR_IFTTT_EVENT     IFTTT Maker event    (default: claude_work_done)
#   CC_GITFLOW_REGULATOR_IFTTT_KEY_FILE  IFTTT key location   (default: ~/.claude/ifttt-key.txt)
#
# Guardrails must never break a session: this script always exits 0 and only
# ever touches directories under .claude/worktrees/.
set -u
mode="${1:-notify}"
input="$(cat 2>/dev/null || true)"

PREFIX="${CC_GITFLOW_REGULATOR_PREFIX:-feature/}"
BASE_OVERRIDE="${CC_GITFLOW_REGULATOR_BASE:-}"
IFTTT_EVENT="${CC_GITFLOW_REGULATOR_IFTTT_EVENT:-claude_work_done}"
IFTTT_KEY_FILE="${CC_GITFLOW_REGULATOR_IFTTT_KEY_FILE:-$HOME/.claude/ifttt-key.txt}"

# --- resolve the worktree directory from hook input (fallback: process cwd) --
if command -v jq >/dev/null 2>&1; then
  dir="$(printf '%s' "$input" | jq -r '.cwd // empty' 2>/dev/null)"
else
  dir="$(printf '%s' "$input" | sed -n 's/.*"cwd" *: *"\([^"]*\)".*/\1/p' | head -1)"
fi

# Escape a string for safe embedding in JSON output (branch prefix is
# user-controlled and may contain quotes/backslashes).
json_esc() { local s="${1//\\/\\\\}"; printf '%s' "${s//\"/\\\"}"; }
[ -z "$dir" ] && dir="$PWD"
dir="${dir//\\\\//}"   # JSON-escaped backslashes -> /
dir="${dir//\\//}"     # plain backslashes -> /

case "$dir" in
  */.claude/worktrees/*) ;;
  *) exit 0 ;;
esac
git -C "$dir" rev-parse --git-dir >/dev/null 2>&1 || exit 0

branch="$(git -C "$dir" symbolic-ref --short -q HEAD || true)"
common="$(git -C "$dir" rev-parse --path-format=absolute --git-common-dir 2>/dev/null)"
repo_root="${common%/.git}"
repo_name="$(basename "$repo_root")"
wtname="$(basename "$dir")"
stampdir="$common/cc-gitflow-regulator"
stampfile="$stampdir/notified-$wtname"

stamp_head() {
  mkdir -p "$stampdir" 2>/dev/null || return 0
  git -C "$dir" rev-parse HEAD 2>/dev/null > "$stampfile" || true
}

# Keep .claude/worktrees/ out of the index: a `git add -A` run inside the repo
# would otherwise record each worktree as a gitlink, leaving the main checkout
# permanently "dirty" and blocking /finish-branch. info/exclude is per-clone,
# so the user's repo needs no committed .gitignore change.
ensure_worktrees_excluded() {
  ex="$common/info/exclude"
  mkdir -p "$common/info" 2>/dev/null || return 0
  grep -qs '^\.claude/worktrees/$' "$ex" 2>/dev/null && return 0
  printf '.claude/worktrees/\n' >> "$ex" 2>/dev/null || true
}

# Gitflow base branch: explicit override first, then common conventions.
detect_base() {
  if [ -n "$BASE_OVERRIDE" ]; then
    if git -C "$dir" rev-parse --verify -q "$BASE_OVERRIDE^{commit}" >/dev/null 2>&1; then
      printf '%s' "$BASE_OVERRIDE"
    fi
    return 0
  fi
  local b
  for b in develop dev; do
    if git -C "$dir" show-ref --verify -q "refs/heads/$b"; then printf '%s' "$b"; return 0; fi
  done
  for b in origin/develop origin/dev; do
    if git -C "$dir" show-ref --verify -q "refs/remotes/$b"; then printf '%s' "$b"; return 0; fi
  done
  return 0
}

notify_user() {
  title="$1"; body="$2"
  if command -v powershell.exe >/dev/null 2>&1; then
    # Windows toast — sticky in Action Center.
    TOAST_TITLE="$title" TOAST_BODY="$body" powershell.exe -NoProfile -Command '
      $null=[Windows.UI.Notifications.ToastNotificationManager,Windows.UI.Notifications,ContentType=WindowsRuntime]
      $x=[Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent([Windows.UI.Notifications.ToastTemplateType]::ToastText02)
      $t=$x.GetElementsByTagName("text")
      $null=$t.Item(0).AppendChild($x.CreateTextNode($env:TOAST_TITLE))
      $null=$t.Item(1).AppendChild($x.CreateTextNode($env:TOAST_BODY))
      $appid="{1AC14E77-02E7-4E5D-B744-2EB1AE5198B7}\WindowsPowerShell\v1.0\powershell.exe"
      [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier($appid).Show([Windows.UI.Notifications.ToastNotification]::new($x))
    ' >/dev/null 2>&1 || true
  elif command -v osascript >/dev/null 2>&1; then
    # macOS notification center.
    t="$(json_esc "$title")"; b="$(json_esc "$body")"
    osascript -e "display notification \"$b\" with title \"$t\"" >/dev/null 2>&1 || true
  elif command -v notify-send >/dev/null 2>&1; then
    # Linux desktop notification.
    notify-send "$title" "$body" >/dev/null 2>&1 || true
  fi
  # IFTTT Maker webhook — enabled by dropping your key in $IFTTT_KEY_FILE.
  # Applet trigger: event $IFTTT_EVENT; value1=repo, value2=branch, value3=detail.
  if [ -s "$IFTTT_KEY_FILE" ]; then
    key="$(tr -cd 'A-Za-z0-9_-' < "$IFTTT_KEY_FILE")"
    event="$(printf '%s' "$IFTTT_EVENT" | tr -cd 'A-Za-z0-9_-')"
    # URL via --config on stdin so the key never appears in process arguments.
    printf 'url = "https://maker.ifttt.com/trigger/%s/with/key/%s"\n' "$event" "$key" | \
      curl -fsS -m 10 --config - \
        --data-urlencode "value1=$repo_name" \
        --data-urlencode "value2=${branch:-detached}" \
        --data-urlencode "value3=$body" >/dev/null 2>&1 || true
  fi
}

case "$mode" in
rename)
  ensure_worktrees_excluded
  # Gitflow: features always fork from the base branch. Only a FRESH worktree
  # branch is re-pointed (exactly one reflog entry, "branch: Created from ..."),
  # so a re-entered worktree that already carries commits is never reset.
  refork=""
  if [ -n "$branch" ]; then
    fresh=0
    if [ "$(git -C "$dir" reflog show --format=%gs "$branch" 2>/dev/null | wc -l | tr -d ' ')" = "1" ]; then
      case "$(git -C "$dir" reflog show --format=%gs "$branch" 2>/dev/null)" in
        "branch: Created from"*) fresh=1 ;;
      esac
    fi
    base="$(detect_base)"
    if [ "$fresh" = "1" ] && [ -n "$base" ] && [ -z "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
      if [ "$(git -C "$dir" rev-parse HEAD 2>/dev/null)" != "$(git -C "$dir" rev-parse --verify "$base" 2>/dev/null)" ]; then
        git -C "$dir" reset --hard -q "$base" 2>/dev/null && refork=" and re-forked from $base"
      fi
    fi
  fi
  stamp_head
  [ -z "$branch" ] && exit 0
  case "$branch" in
    "$PREFIX"*|feature/*|release/*|hotfix/*|bugfix/*) exit 0 ;;
    worktree-*) new="${PREFIX}${branch#worktree-}" ;;
    *) new="${PREFIX}${branch}" ;;
  esac
  b="$(json_esc "$branch")"; n="$(json_esc "$new")"; r="$(json_esc "$refork")"
  if git -C "$dir" branch -m "$branch" "$new" 2>/dev/null; then
    printf '{"hookSpecificOutput":{"hookEventName":"PostToolUse","additionalContext":"Gitflow guardrail: the worktree branch was renamed from %s to %s%s. Use %s for all git operations from now on and when reporting results."},"systemMessage":"gitflow: worktree branch renamed to %s%s"}\n' \
      "$b" "$n" "$r" "$n" "$n" "$r"
  else
    printf '{"systemMessage":"gitflow: could not rename %s to %s (target may already exist); branch name kept"}\n' "$b" "$n"
  fi
  ;;
notify|end)
  # Alert only when the tree is clean (work committed) and HEAD moved since last alert.
  if [ -z "$(git -C "$dir" status --porcelain 2>/dev/null)" ] && [ -n "$branch" ]; then
    head_sha="$(git -C "$dir" rev-parse HEAD 2>/dev/null || true)"
    last="$(cat "$stampfile" 2>/dev/null || true)"
    if [ -n "$head_sha" ] && [ "$head_sha" != "$last" ]; then
      notify_user "Claude: work ready" "$repo_name - $branch is committed and ready to review/merge"
      mkdir -p "$stampdir" 2>/dev/null && printf '%s' "$head_sha" > "$stampfile"
    fi
  fi
  if [ "$mode" = "end" ] && [ -n "$branch" ] && [ -z "$(git -C "$dir" status --porcelain 2>/dev/null)" ]; then
    # Release the branch to the main checkout: your git client can now use it.
    git -C "$dir" switch --detach -q 2>/dev/null || true
  fi
  ;;
esac
exit 0
