# Plan 3/3: Release Tooling Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Single-source the version from `package.json` into all four locations, gate agreement in CI, and publish to npm on tag push with OIDC provenance.

**Architecture:** `scripts/sync-version.sh` rewrites the other three version refs; npm's `version` lifecycle hook runs it so `npm version X.Y.Z` yields one atomic commit + tag. `release.yml` publishes on `v*` tags via npm trusted publishing (no long-lived token).

**Tech Stack:** bash + node one-liners (no new deps), GitHub Actions, npm trusted publishing (OIDC).

## Global Constraints

- Version locations, exactly four: `package.json`, `.claude-plugin/plugin.json` (`.version`), `.claude-plugin/marketplace.json` (`.plugins[0].version`), `README.md` (the standalone `vX.Y.Z` line under the title)
- `package.json` is the source of truth; nothing else is ever edited by hand
- No version bump lands in this plan — the machinery ships; the 0.3.1 cut runs it afterward, on the user's go
- JSON rewrites preserve the repo's format: 2-space indent, trailing newline
- No long-lived `NPM_TOKEN` secret — OIDC trusted publishing only

---

### Task 1: `sync-version.sh` (bats test first)

**Files:**
- Create: `scripts/sync-version.sh`
- Test: `tests/sync-version.bats`

**Interfaces:**
- Consumes: `package.json` `.version` (reads only)
- Produces: rewrites the other three version locations; `npm version` lifecycle (Task 2) and the release runbook call `bash scripts/sync-version.sh`

- [ ] **Step 1: Write the failing test**

Create `tests/sync-version.bats`:

```bash
#!/usr/bin/env bats
# sync-version rewrites plugin.json, marketplace.json, and README's v-line
# from package.json. Tested against a scratch copy of the real manifests —
# the script cds to its own repo root, so we copy it into a fake repo.

setup() {
  tmp="$BATS_TEST_TMPDIR"
  command -v cygpath >/dev/null && tmp="$(cygpath -m "$tmp")"  # node-safe on Windows
  FAKE="$tmp/fake-repo"
  mkdir -p "$FAKE/scripts" "$FAKE/.claude-plugin"
  cp "$BATS_TEST_DIRNAME/../scripts/sync-version.sh" "$FAKE/scripts/"
  cp "$BATS_TEST_DIRNAME/../.claude-plugin/plugin.json" "$FAKE/.claude-plugin/"
  cp "$BATS_TEST_DIRNAME/../.claude-plugin/marketplace.json" "$FAKE/.claude-plugin/"
  printf '# title\n\nv0.0.0\n\nbody\n' > "$FAKE/README.md"
  printf '{\n  "version": "9.9.9"\n}\n' > "$FAKE/package.json"
}

@test "propagates package.json version into all three targets" {
  run bash "$FAKE/scripts/sync-version.sh"
  [ "$status" -eq 0 ]
  [ "$(node -p "require('$FAKE/.claude-plugin/plugin.json').version")" = "9.9.9" ]
  [ "$(node -p "require('$FAKE/.claude-plugin/marketplace.json').plugins[0].version")" = "9.9.9" ]
  grep -qx 'v9.9.9' "$FAKE/README.md"
  # untouched lines survive
  grep -qx '# title' "$FAKE/README.md"
  grep -qx 'body' "$FAKE/README.md"
}

@test "idempotent: second run changes nothing" {
  bash "$FAKE/scripts/sync-version.sh"
  cp "$FAKE/.claude-plugin/plugin.json" "$BATS_TEST_TMPDIR/one.json"
  bash "$FAKE/scripts/sync-version.sh"
  cmp "$BATS_TEST_TMPDIR/one.json" "$FAKE/.claude-plugin/plugin.json"
}
```

- [ ] **Step 2: Run to verify failure**

Run: `npx bats tests/sync-version.bats`
Expected: FAIL — `scripts/sync-version.sh` does not exist.

- [ ] **Step 3: Implement**

Create `scripts/sync-version.sh`:

```bash
#!/usr/bin/env bash
# sync-version — single-source the version. package.json is the truth;
# this propagates it to plugin.json, marketplace.json, and README's
# standalone vX.Y.Z line. Wired as npm's "version" lifecycle hook so
# `npm version X.Y.Z` bumps all four inside one release commit; also
# runnable standalone: bash scripts/sync-version.sh
set -euo pipefail
cd "$(dirname "$0")/.."
v="$(node -p "require('./package.json').version")"

# JSON edits via node so formatting stays stable (2-space, trailing \n)
node -e '
  const fs = require("fs"), v = process.argv[1];
  for (const f of [".claude-plugin/plugin.json", ".claude-plugin/marketplace.json"]) {
    const j = JSON.parse(fs.readFileSync(f, "utf8"));
    if (j.version) j.version = v;                    // plugin.json top-level
    for (const p of j.plugins || []) p.version = v;  // marketplace entries
    fs.writeFileSync(f, JSON.stringify(j, null, 2) + "\n");
  }
' "$v"

# README: only the standalone version line under the title
sed -i.bak -E "s/^v[0-9]+\.[0-9]+\.[0-9]+$/v$v/" README.md && rm -f README.md.bak

echo "synced $v -> plugin.json, marketplace.json, README.md"
```

- [ ] **Step 4: Run tests**

Run: `npx bats tests/sync-version.bats`
Expected: `2 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add scripts/sync-version.sh tests/sync-version.bats
git commit -m "feat: sync-version propagates package.json version to the other three refs"
```

---

### Task 2: Wire the `npm version` lifecycle + CI agreement gate

**Files:**
- Modify: `package.json` (add `version` lifecycle script)
- Modify: `.github/workflows/ci.yml` (add agreement step)

**Interfaces:**
- Consumes: `scripts/sync-version.sh` (Task 1)
- Produces: `npm version <X.Y.Z>` → one commit + tag covering all four refs; CI fails on drift

- [ ] **Step 1: Add the lifecycle script**

In `package.json` `"scripts"`, alongside `"test"`:

```json
"version": "bash scripts/sync-version.sh && git add .claude-plugin/plugin.json .claude-plugin/marketplace.json README.md"
```

(npm runs `version` after bumping `package.json` but before creating the release commit — staged files ride along in that commit.)

- [ ] **Step 2: Add the CI gate**

In `.github/workflows/ci.yml`, append a step to the `checks` job after `bats`:

```yaml
      - name: version agreement
        run: |
          pkg=$(node -p "require('./package.json').version")
          plg=$(node -p "require('./.claude-plugin/plugin.json').version")
          mkt=$(node -p "require('./.claude-plugin/marketplace.json').plugins[0].version")
          rdm=$(grep -m1 -oE '^v[0-9]+\.[0-9]+\.[0-9]+$' README.md | tr -d v)
          test "$pkg" = "$plg" -a "$pkg" = "$mkt" -a "$pkg" = "$rdm" \
            || { echo "version drift: pkg=$pkg plugin=$plg marketplace=$mkt readme=$rdm"; exit 1; }
```

- [ ] **Step 3: Prove the gate catches drift, then passes**

Run the gate's script body locally (copy-paste it into bash). Current state: all four say 0.3.0 → prints nothing, exit 0. Then `sed -i 's/^v0\.3\.0$/v0.0.1/' README.md`, run again → expect `version drift:` and exit 1. Restore: `git checkout -- README.md`.
Expected: exactly that pass → fail → restore sequence.

- [ ] **Step 4: Dry-run the lifecycle without keeping the bump**

```bash
git switch -c tmp/version-dry-run
npm version 0.9.9        # bumps, syncs, commits, tags v0.9.9
git show --stat HEAD      # expect: package.json(+lock), plugin.json, marketplace.json, README.md
npx bats tests/sync-version.bats
git tag -d v0.9.9
git switch -              # back to the plan branch
git branch -D tmp/version-dry-run
```

Expected: the version commit touches all four refs (+ lockfile); tag and branch deleted afterward; working branch untouched.

- [ ] **Step 5: Commit**

```bash
git add package.json .github/workflows/ci.yml
git commit -m "ci: npm-version lifecycle sync and four-way version agreement gate"
```

---

### Task 3: Release workflow (OIDC trusted publishing)

**Files:**
- Create: `.github/workflows/release.yml`
- Modify: `CLAUDE.md` (releasing runbook)

**Interfaces:**
- Consumes: green `ci.yml`; the `v*` tag `npm version` creates
- Produces: the package on npmjs.com with provenance

- [ ] **Step 1: Write the workflow**

Create `.github/workflows/release.yml`:

```yaml
# release: publish to npm when a v* tag lands. Auth is OIDC trusted
# publishing — configured on npmjs.com, no NPM_TOKEN secret anywhere.
name: release
on:
  push:
    tags: ['v*']

permissions:
  contents: read
  id-token: write   # mint the OIDC token npm exchanges for publish rights

jobs:
  publish:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: actions/setup-node@v4
        with:
          node-version: 22
          registry-url: https://registry.npmjs.org
      - run: npx bats tests/     # never publish untested
      - run: npm publish --provenance --access public
```

- [ ] **Step 2: Configure the trusted publisher on npmjs.com** (manual, browser)

On npmjs.com → package settings (or org settings for a first publish) → Trusted Publishers → GitHub Actions, with: repository `jagp/cc-gitflow-regulator`, workflow `release.yml`, environment blank.

Fallback if npm rejects a never-published package for trusted publishing: one manual bootstrap from a logged-in machine — `npm publish --access public` — then configure the trusted publisher and every later release flows through CI.

- [ ] **Step 3: Add the runbook to CLAUDE.md**

Append:

```markdown
## Releasing

`npm version <X.Y.Z>` — syncs all four version refs into one commit + tag (scripts/sync-version.sh).
`git push --follow-tags` — CI validates, then release.yml publishes to npm with provenance.
```

- [ ] **Step 4: Verify workflow syntax without a publish**

Run: `node -e "console.log('yaml parse is CI-side')" && gh workflow list`
Expected: after push, `gh workflow list` shows `ci` and `release`; `release` has no runs (no tag yet). Full pipeline validation happens at the 0.3.1 cut.

- [ ] **Step 5: Commit**

```bash
git add .github/workflows/release.yml CLAUDE.md
git commit -m "ci: npm release workflow via OIDC trusted publishing; releasing runbook"
```

---

### The 0.3.1 cut (after all three plans merge — user's go, not part of this plan)

```bash
npm version 0.3.1
git push --follow-tags
```

That is the deferred version bump: one command, four refs, one tag, CI publishes.

---

## Self-Review Notes

- Spec coverage: version single-sourcing ✓ (T1/T2), CI agreement ✓ (T2), OIDC publish ✓ (T3), deferred-bump instruction preserved as the final runbook ✓.
- The trusted-publisher first-publish edge (npm may require an existing package) is handled with an explicit documented fallback, not silently assumed away.
- `npm version` dry-run happens on a throwaway branch so no bump ever lands from this plan.
