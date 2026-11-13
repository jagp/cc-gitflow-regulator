#!/usr/bin/env bash
# Behaviour tests for scripts/cc-gitflow-regulator.sh, the hook script
# (rename / notify / end). One PASS/FAIL line per case, exit 1 on any failure.
# Run from anywhere: bash tests/hooks.sh
#
# Side effects are fenced off:
#   - desktop alerts: fake powershell.exe / osascript / notify-send scripts sit
#     first on PATH and append their arguments to $SCRATCH/alerts instead
source "$(dirname "$0")/lib.sh"
mkdir -p "$SCRATCH/fakebin"
for tool in powershell.exe osascript notify-send; do
  printf '#!/usr/bin/env bash\necho "%s" >> "%s/alerts"\n' "$tool" "$SCRATCH" > "$SCRATCH/fakebin/$tool"
  chmod +x "$SCRATCH/fakebin/$tool"
done
export PATH="$SCRATCH/fakebin:$PATH"
W=.claude/worktrees

# hook <mode> <dir>: feed the hook the JSON Claude Code sends ({"cwd": ...})
hook() { printf '{"cwd": "%s"}' "$2" | bash "$REPO/scripts/cc-gitflow-regulator.sh" "$1"; }
# new_worktree <name> [start]: what EnterWorktree creates — worktree-<name> off HEAD
new_worktree() { git worktree add -q "$W/$1" -b "worktree-$1" "${2:-main}"; }
alerts() { cat "$SCRATCH/alerts" 2>/dev/null | wc -l | tr -d ' '; }
valid_json() { python -I -c 'import json,sys; json.loads(sys.stdin.read())' 2>/dev/null; }

# --- rename ---------------------------------------------------------------------------
fresh; git switch -q develop; git commit -q --allow-empty -m "develop moves ahead"; git switch -q main
new_worktree a; dir="$(pwd)/$W/a"; out="$(hook rename "$dir")"; code=$?
check "rename: worktree-a becomes feature/a" '[ "$(git -C "$dir" branch --show-current)" = feature/a ]'
check "rename: a fresh worktree is re-forked onto develop" '[ "$(git -C "$dir" rev-parse HEAD)" = "$(git rev-parse develop)" ]'
check "rename: prints valid JSON naming the new branch" 'echo "$out" | valid_json && echo "$out" | grep -q "feature/a"'
check "rename: exits 0" '[ "$code" = 0 ]'

new_worktree b; echo work > "$W/b/work.txt"; git -C "$W/b" add . && git -C "$W/b" commit -q -m work
before="$(git -C "$W/b" rev-parse HEAD)"; hook rename "$(pwd)/$W/b" >/dev/null
check "rename: a worktree with commits is renamed but never reset" \
  '[ "$(git -C "$W/b" rev-parse HEAD)" = "$before" ] && [ "$(git -C "$W/b" branch --show-current)" = feature/b ]'

new_worktree c; echo dirty > "$W/c/dirty.txt"; hook rename "$(pwd)/$W/c" >/dev/null
check "rename: a fresh but dirty worktree is not reset" '[ "$(git -C "$W/c" rev-parse HEAD)" = "$(git rev-parse main)" ] && [ -f "$W/c/dirty.txt" ]'

git worktree add -q "$W/d" -b feature/d main; out="$(hook rename "$(pwd)/$W/d")"
check "rename: a branch that already has a gitflow prefix is left alone" '[ "$(git -C "$W/d" branch --show-current)" = feature/d ] && [ -z "$out" ]'

git branch feature/e main; new_worktree e; out="$(hook rename "$(pwd)/$W/e")"; code=$?
check "rename: a name collision keeps the branch and says so" \
  '[ "$(git -C "$W/e" branch --show-current)" = worktree-e ] && echo "$out" | grep -q "could not rename" && [ "$code" = 0 ]'

new_worktree f; out="$(CC_GITFLOW_REGULATOR_PREFIX='we"ird\' hook rename "$(pwd)/$W/f")"
check "rename: a prefix with quotes and backslashes still prints valid JSON" 'echo "$out" | valid_json'

new_worktree g; winpath="$(cd "$W/g" && pwd -W 2>/dev/null || pwd)"; json_path="$(printf '%s' "$winpath" | sed 's|/|\\\\|g')"
out="$(printf '{"cwd": "%s"}' "$json_path" | bash "$REPO/scripts/cc-gitflow-regulator.sh" rename)"
check "rename: a backslash Windows path in the hook input works" '[ "$(git -C "$W/g" branch --show-current)" = feature/g ]'
# seven renames ran above; the fixture's own entry is removed first so only the hook's count
sed -i '/^\.claude\/worktrees\/$/d' .git/info/exclude; hook rename "$(pwd)/$W/a" >/dev/null; hook rename "$(pwd)/$W/b" >/dev/null
check "rename: .claude/worktrees/ is excluded exactly once across renames" '[ "$(grep -c "^\.claude/worktrees/$" .git/info/exclude)" = 1 ]'

# --- outside managed worktrees ---------------------------------------------------------------
before="$(git branch --show-current)"; out="$(hook rename "$(pwd)")"; code=$?
check "outside .claude/worktrees: no output, nothing changed, exit 0" \
  '[ -z "$out" ] && [ "$code" = 0 ] && [ "$(git branch --show-current)" = "$before" ]'
out="$(hook rename "/nonexistent/.claude/worktrees/x")"; code=$?
check "a missing worktree folder: exit 0, no output" '[ -z "$out" ] && [ "$code" = 0 ]'

# --- notify ---------------------------------------------------------------------------------
fresh; new_worktree n; dir="$(pwd)/$W/n"; hook rename "$dir" >/dev/null; rm -f "$SCRATCH/alerts"
hook notify "$dir"
check "notify: no alert when HEAD hasn't moved since the rename" '[ "$(alerts)" = 0 ]'
echo x > "$W/n/x.txt"; git -C "$W/n" add . && git -C "$W/n" commit -q -m x; echo y > "$W/n/y.txt"
hook notify "$dir"
check "notify: no alert while the tree is dirty" '[ "$(alerts)" = 0 ]'
rm "$W/n/y.txt"; hook notify "$dir"
check "notify: one alert for a new clean commit" '[ "$(alerts)" = 1 ]'
hook notify "$dir"
check "notify: no repeat alert for the same commit" '[ "$(alerts)" = 1 ]'
check "notify: never pushes" '! git ls-remote --exit-code ../origin.git feature/n >/dev/null'

# --- end ----------------------------------------------------------------------------------
fresh; new_worktree e1; hook rename "$(pwd)/$W/e1" >/dev/null; hook end "$(pwd)/$W/e1"
check "end: a clean worktree is detached, freeing the branch" \
  '[ -z "$(git -C "$W/e1" branch --show-current)" ] && git switch -q feature/e1 && git switch -q main'
new_worktree e2; hook rename "$(pwd)/$W/e2" >/dev/null; echo d > "$W/e2/d.txt"; hook end "$(pwd)/$W/e2"
check "end: a dirty worktree keeps its branch" '[ "$(git -C "$W/e2" branch --show-current)" = feature/e2 ]'

# --- gitflow.branch.develop -------------------------------------------------------------
# A repo can name its integration branch (here: trunk) the way git-flow does.
fresh; git branch trunk main; git switch -q trunk; git commit -q --allow-empty -m "trunk moves ahead"; git switch -q main
git config gitflow.branch.develop trunk
new_worktree t; hook rename "$(pwd)/$W/t" >/dev/null
check "rename: a fresh worktree forks from gitflow.branch.develop when set" '[ "$(git -C "$W/t" rev-parse HEAD)" = "$(git rev-parse trunk)" ]'

echo "$failures failure(s)"
[ "$failures" = 0 ]
