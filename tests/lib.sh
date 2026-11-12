# Shared fixture for the finish-feature.sh / start-feature.sh smoke tests.
# Sourced by the other tests/*.sh files; not run on its own.
#
#   fresh             new bare origin + clone (main and develop pushed), cd into
#                     the clone; .claude/worktrees is excluded like the hooks do
#   wt <name> [base]  managed worktree .claude/worktrees/<name> on
#                     feature/<name> (from base, default develop), one commit,
#                     base recorded the way /start-feature records it
#   fin <args...>     run finish-feature.sh, then print exit=<code>
#   commit <message>  an empty commit with that message on the current branch
#   release_repo      fresh, then main + develop at a released 0.3.1 (tag v0.3.1,
#                     plugin.json + marketplace.json, CHANGELOG.md) and one
#                     "feat:" commit on develop, so the suggestion is 0.4.0
#                     (gitflow.release.merge=push: merges into main locally)
#   startr / finr     run start-release.sh / finish-release.sh, print exit=<code>
#   fake_gh / reset_gh / merge_on_origin   a stand-in gh and GitHub's PRs
#
# Everything lives in a throwaway temp folder; job records go to a test jobs
# folder (CC_GITFLOW_REGULATOR_JOBS_DIR) so real ~/.claude/jobs is never read.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRATCH="$(mktemp -d "${TMPDIR:-/tmp}/cc-gitflow-tests.XXXXXX")"
export CC_GITFLOW_REGULATOR_JOBS_DIR="$SCRATCH/jobs"
trap 'cd /; rm -rf "${SCRATCH:?}"' EXIT

fresh() {
  rm -rf "${SCRATCH:?}/f" "${SCRATCH:?}/jobs"; mkdir -p "$SCRATCH/f" "$SCRATCH/jobs"
  git init -q --bare -b main "$SCRATCH/f/origin.git"
  git clone -q "$SCRATCH/f/origin.git" "$SCRATCH/f/clone" 2>/dev/null
  cd "$SCRATCH/f/clone" || return 1
  git config core.autocrlf false   # same line endings on every machine
  git commit -q --allow-empty -m init && git push -q origin main
  git branch develop && git push -q -u origin develop 2>/dev/null
  echo ".claude/worktrees/" >> .git/info/exclude
}

wt() {
  local name="$1" base="${2:-develop}" dir=".claude/worktrees/$1"
  git worktree add -q "$dir" -b "feature/$name" "$base"
  echo "$name" > "$dir/$name.txt"; git -C "$dir" add . && git -C "$dir" commit -q -m "add $name"
  git config "gitflow.branch.feature/$name.base" "$base"
}

fin() { bash "$REPO/scripts/finish-feature.sh" "$@"; echo "exit=$?"; }
startr() { bash "$REPO/scripts/start-release.sh" "$@"; echo "exit=$?"; }
finr() { bash "$REPO/scripts/finish-release.sh" "$@"; echo "exit=$?"; }
commit() { git commit -q --allow-empty -m "$1"; }

# release_repo: main and develop at a released 0.3.1 (tag, both manifests, a
# changelog), plus one feat commit on develop, so the suggestion is 0.4.0.
release_repo() {
  fresh; mkdir .claude-plugin
  printf '{\n  "name": "x",\n  "version": "0.3.1"\n}\n' > .claude-plugin/plugin.json
  printf '{\n  "plugins": [\n    {\n      "name": "x",\n      "version": "0.3.1"\n    }\n  ]\n}\n' > .claude-plugin/marketplace.json
  printf '# Changelog\n\n## 0.3.1 — 2026-01-01\n\n- old\n' > CHANGELOG.md
  git add . && git commit -q -m "chore: release 0.3.1" && git tag v0.3.1 && git push -q origin main v0.3.1
  git switch -q develop && git merge -q --ff-only main && commit "feat: a new thing" && git push -q origin develop
  # The merge into main defaults to a PR; most cases test the local merge,
  # so this repo merges and pushes. PR cases switch it back per case.
  git config gitflow.release.merge push
}

# fake_gh: put a stand-in gh first on PATH for the rest of the test file.
# It logs every call to $SCRATCH_LOG (and a --notes-file's text), exits
# $GH_STUB_EXIT, and plays GitHub's pull requests with marker files in
# $SCRATCH: "pr create" makes pr-open; "pr list --state open|merged" prints a
# URL while pr-open / pr-merged exists. merge_on_origin moves open to merged.
fake_gh() {
  mkdir -p "$SCRATCH/fakebin"
  cat > "$SCRATCH/fakebin/gh" <<'STUB'
#!/usr/bin/env bash
echo "gh $*" >> "$SCRATCH_LOG"
state_dir="$(dirname "$SCRATCH_LOG")"
case "$1 $2" in
  "pr create") : > "$state_dir/pr-open"; echo "https://example.test/pull/1" ;;
  "pr list") case "$*" in
      *"--state open"*) [ -f "$state_dir/pr-open" ] && echo "https://example.test/pull/1" ;;
      *"--state merged"*) [ -f "$state_dir/pr-merged" ] && echo "https://example.test/pull/1" ;;
    esac ;;
esac
while [ $# -gt 0 ]; do [ "$1" = --notes-file ] && cat "$2" >> "$SCRATCH_LOG"; shift; done
exit "${GH_STUB_EXIT:-0}"
STUB
  chmod +x "$SCRATCH/fakebin/gh"
  export PATH="$SCRATCH/fakebin:$PATH" SCRATCH_LOG="$SCRATCH/gh.log"
}
# reset_gh: forget earlier gh calls and PRs.
reset_gh() { rm -f "$SCRATCH_LOG" "$SCRATCH/pr-open" "$SCRATCH/pr-merged"; }

# merge_on_origin <merge|squash> <into> <from>: play GitHub merging the open
# PR from <from> into <into>, in a second clone: a merge commit, or a squash
# (one copied commit). Then the PR counts as merged for fake_gh.
merge_on_origin() {
  local github="$SCRATCH/f/github"
  rm -rf "$github"; git clone -q "$SCRATCH/f/origin.git" "$github" 2>/dev/null
  git -C "$github" switch -q "$2" 2>/dev/null
  if [ "$1" = merge ]; then git -C "$github" merge -q --no-ff -m "Merge pull request #1" "origin/$3"
  else git -C "$github" merge -q --squash "origin/$3" && git -C "$github" commit -q -m "squashed (#1)"; fi
  git -C "$github" push -q origin "$2"
  rm -f "$SCRATCH/pr-open"; : > "$SCRATCH/pr-merged"
}

# check <label> <condition>: one PASS/FAIL line; any FAIL makes the run exit 1.
failures=0
check() { if eval "$2"; then echo "PASS  $1"; else echo "FAIL  $1"; failures=$((failures + 1)); fi; }
