# Plan 1/3: Repo Hygiene Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Clean the repo before the npm channel lands — delete the duplicate shim, make `rename` race-safe, align the GitHub slug, and stand up CI.

**Architecture:** Pure bash + JSON edits; no new runtime components. Tests use bats-core invoked via `npx bats` (no package.json exists yet — plan 2 adds it; `npx` fetches bats standalone). CI is one workflow with three checks.

**Tech Stack:** bash, bats-core (via npx), GitHub Actions, shellcheck, gh CLI.

## Global Constraints

- Hook scripts always `exit 0` — a guardrail must never break a session (`scripts/cc-gitflow-regulator.sh:25-27`)
- Hooks only touch directories under `.claude/worktrees/`
- No version bumps in this plan — all four version refs change only at the release cut
- Commit messages follow semver `<action>:` prefixes
- Comments: compact, pseudo-code signposts per repo CLAUDE.md

---

### Task 1: Delete the duplicate shim

`scripts/claude-gitflow-regulator.sh` is a byte-identical 185-line copy of `scripts/cc-gitflow-regulator.sh` left over from the 0.3.0 rename. Nothing references it — `hooks/hooks.json` and `commands/finish-branch.md` point only at `cc-gitflow-regulator.sh` and `finish-branch.sh`.

**Files:**
- Delete: `scripts/claude-gitflow-regulator.sh`

**Interfaces:**
- Consumes: nothing
- Produces: nothing — later tasks assume only two scripts exist in `scripts/`

- [ ] **Step 1: Verify it is truly identical and unreferenced**

Run: `diff scripts/cc-gitflow-regulator.sh scripts/claude-gitflow-regulator.sh && grep -rn "claude-gitflow-regulator.sh" --include="*.json" --include="*.md" .`
Expected: `diff` silent (identical); grep finds no references outside the file itself (this plan file may match — that's fine).

- [ ] **Step 2: Delete and commit**

```bash
git rm scripts/claude-gitflow-regulator.sh
git commit -m "chore: delete claude-gitflow-regulator.sh shim (identical copy of cc-gitflow-regulator.sh)"
```

---

### Task 2: Race-safe `rename` (bats test first)

Sequential idempotence already exists — `scripts/cc-gitflow-regulator.sh:157` exits quietly when the branch already carries a gitflow prefix. The gap is concurrent duplicate registrations: both read `worktree-X`, both run `git branch -m`, the loser prints "target may already exist" (line 166) even though the desired end-state holds. Fix: after a failed rename, re-read the current branch; if it now equals the target, a racer won — quiet success.

**Files:**
- Create: `tests/rename.bats`
- Modify: `scripts/cc-gitflow-regulator.sh:162-167`

**Interfaces:**
- Consumes: `scripts/cc-gitflow-regulator.sh rename` reading `{"cwd": "<worktree>"}` on stdin
- Produces: `tests/rename.bats` — the file plan-2/3 tests sit beside; run with `npx bats tests/`

- [ ] **Step 1: Write the failing test**

Create `tests/rename.bats`:

```bash
#!/usr/bin/env bats
# rename subcommand: gitflow renaming of Claude worktree branches.
# Each test builds a throwaway repo with a develop base and a managed
# worktree, then drives the script exactly as the hook harness would:
# JSON {"cwd": ...} on stdin.

SCRIPT="$BATS_TEST_DIRNAME/../scripts/cc-gitflow-regulator.sh"

setup() {
  REPO="$BATS_TEST_TMPDIR/repo"
  git init -q -b main "$REPO"
  git -C "$REPO" -c user.email=t@t -c user.name=t commit -q --allow-empty -m init
  git -C "$REPO" branch develop
  git -C "$REPO" worktree add -q "$REPO/.claude/worktrees/demo" -b worktree-demo
  WT="$REPO/.claude/worktrees/demo"
}

run_rename() {  # $1 = worktree dir
  printf '{"cwd":"%s"}' "$1" | bash "$SCRIPT" rename
}

@test "renames worktree-demo to feature/demo" {
  run run_rename "$WT"
  [ "$status" -eq 0 ]
  [ "$(git -C "$WT" symbolic-ref --short HEAD)" = "feature/demo" ]
  [[ "$output" == *"renamed"* ]]
}

@test "second run is a quiet no-op" {
  run_rename "$WT"
  run run_rename "$WT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "race loser stays quiet when branch already at target" {
  # Simulate losing the race: the branch was renamed between the script
  # reading $branch and calling `git branch -m`. Recreate the end-state a
  # loser observes — current branch IS the target, stale source name gone —
  # by invoking with a hand-built stdin claiming the old name. Cheapest
  # faithful simulation: rename first, then make a decoy branch holding the
  # old name so the -m fails, pointed elsewhere? No — the loser's defining
  # observation is: -m failed AND symbolic-ref now reports the target.
  # Reproduce exactly that: pre-rename the branch, then re-create
  # worktree-demo as a *different* branch on the main checkout so
  # `git branch -m worktree-demo feature/demo` fails (source is not the
  # worktree's HEAD; target exists) while the worktree sits on feature/demo.
  git -C "$WT" branch -m worktree-demo feature/demo
  git -C "$REPO" branch worktree-demo   # decoy: forces -m to fail
  # Invoke rename: script reads branch=feature/demo -> prefix guard exits
  # quietly (sequential idempotence, already covered above). The racing
  # window is between read and -m, unreachable from outside the script —
  # so the loser path is exercised by the genuine-failure test below and
  # the post-failure re-check is asserted through code review of the diff.
  run run_rename "$WT"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "genuine rename failure still reports, still exits 0" {
  # feature/demo already exists as a DIFFERENT branch while the worktree
  # still sits on worktree-demo: -m fails, current branch is NOT the
  # target, so the error message must survive (this is a real conflict,
  # not a lost race) — but exit stays 0: guardrails never break sessions.
  git -C "$REPO" branch feature/demo
  run run_rename "$WT"
  [ "$status" -eq 0 ]
  [[ "$output" == *"could not rename"* ]]
  [ "$(git -C "$WT" symbolic-ref --short HEAD)" = "worktree-demo" ]
}
```

- [ ] **Step 2: Run tests — expect the suite to run, all four pass except none fail yet**

Run: `npx bats tests/rename.bats`
Expected: tests 1–3 PASS against current code (they cover existing behavior); test 4 PASSES too. This task's behavior change is unobservable from outside the process (the race window is internal), so the test suite pins current behavior and the diff below adds the re-check. If any of the four FAIL, the environment (git/bats) is broken — fix that first.

- [ ] **Step 3: Add the post-failure re-check**

In `scripts/cc-gitflow-regulator.sh`, replace the `else` branch of the rename attempt (lines 165–167):

```bash
  else
    # -m failed. If a concurrent duplicate registration completed the same
    # rename between our branch read and the -m, the desired end-state
    # already holds -> success, quietly (matches the prefix guard above).
    # Otherwise it is a genuine conflict: report it, but still exit 0.
    now="$(git -C "$dir" symbolic-ref --short -q HEAD || true)"
    [ "$now" = "$new" ] && exit 0
    printf '{"systemMessage":"gitflow: could not rename %s to %s (target may already exist); branch name kept"}\n' "$b" "$n"
  fi
```

- [ ] **Step 4: Run the suite — all four pass; shellcheck clean**

Run: `npx bats tests/rename.bats && (command -v shellcheck >/dev/null && shellcheck scripts/cc-gitflow-regulator.sh || echo "shellcheck not local; CI covers it")`
Expected: `4 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add tests/rename.bats scripts/cc-gitflow-regulator.sh
git commit -m "fix: rename treats losing a duplicate-registration race as quiet success"
```

---

### Task 3: Align the GitHub repo slug

`plugin.json` `homepage`/`repository` and README's install command all say `jagp/cc-gitflow-regulator`; the actual repo is `jagp/claude-gitflow`, so those references resolve to nothing today. Direction chosen in design: rename the repo (GitHub redirects the old slug, so existing clones and the marketplace entry keep working).

**Files:**
- Modify: none in-repo (manifests already carry the target slug) — this task changes GitHub state and the local remote

**Interfaces:**
- Consumes: nothing
- Produces: a resolvable `jagp/cc-gitflow-regulator`; plan 3's release workflow assumes this slug

- [ ] **Step 1: Confirm with the user, then rename** (outward-facing; user pre-approved in design, re-confirm before firing)

Run: `gh repo rename cc-gitflow-regulator -R jagp/claude-gitflow --yes`
Expected: success line with the new URL.

- [ ] **Step 2: Point the local remote at the new slug**

```bash
git remote set-url origin https://github.com/jagp/cc-gitflow-regulator
git remote -v          # verify
git fetch origin       # verify connectivity
```

- [ ] **Step 3: Verify the published references now resolve**

Run: `gh repo view jagp/cc-gitflow-regulator --json name,url`
Expected: `{"name":"cc-gitflow-regulator","url":"https://github.com/jagp/cc-gitflow-regulator"}`.

Note (no action): `extraKnownMarketplaces` in `~/.claude/settings.json` still says `jagp/claude-gitflow`; the GitHub redirect keeps it working. Optional cleanup for the user, not this plan.

No commit — nothing in the tree changed.

---

### Task 4: CI — shellcheck, JSON validation, bats

**Files:**
- Create: `.github/workflows/ci.yml`

**Interfaces:**
- Consumes: `tests/*.bats` from Task 2
- Produces: the workflow plans 2 and 3 extend (plan 3 adds a version-agreement step; its release workflow is separate)

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/ci.yml`:

```yaml
# CI: lint the bash, prove the JSON parses, run the test suite.
# ubuntu-only by design — the scripts target Git Bash everywhere, and
# shellcheck/bats behave identically enough on linux to catch real bugs.
name: ci
on:
  push:
    branches: [main, develop]
  pull_request:

jobs:
  checks:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: shellcheck
        run: shellcheck scripts/*.sh   # preinstalled on ubuntu runners

      - name: validate JSON
        run: |
          # Every tracked .json must parse — node is preinstalled on runners.
          git ls-files '*.json' | while read -r f; do
            node -e "JSON.parse(require('fs').readFileSync('$f','utf8'))" \
              || { echo "invalid JSON: $f"; exit 1; }
          done

      - name: bats
        run: npx bats tests/
```

- [ ] **Step 2: Validate locally what CI will run**

Run: `node -e "JSON.parse(require('fs').readFileSync('.claude-plugin/plugin.json','utf8'))" && npx bats tests/`
Expected: no output from node; `4 tests, 0 failures` from bats. (shellcheck runs in CI if not installed locally.)

- [ ] **Step 3: Commit and confirm the workflow runs**

```bash
git add .github/workflows/ci.yml
git commit -m "ci: shellcheck, JSON validation, bats"
git push -u origin feature/bump-0.3.1
gh run watch --exit-status   # wait for green
```

Expected: the `ci` run completes successfully.

---

## Self-Review Notes

- Spec coverage: shim deletion ✓ (Task 1), idempotent rename ✓ (Task 2, narrowed honestly to the race case — sequential guard pre-exists at `scripts/cc-gitflow-regulator.sh:157`), repo URL fix ✓ (Task 3), shellcheck CI ✓ (Task 4). Version bumps deliberately absent (release cut).
- The race window itself is untestable from outside the process; Task 2 pins all observable behavior and the re-check is 3 lines reviewed by diff. Stated in-plan rather than pretending a test covers it.
