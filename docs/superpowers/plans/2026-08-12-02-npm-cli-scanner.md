# Plan 2/3: npm CLI + Registration Scanner Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Ship `cc-gitflow-regulator` on npm — a zero-dependency Node CLI that vendor-copies the bash scripts, rewrites `${CLAUDE_PLUGIN_ROOT}`, merges marked hook entries into settings, and detects every way the plugin is already registered.

**Architecture:** `bin/cli.js` is a thin dispatcher over small `lib/` modules (paths, util, scan, install, uninstall, doctor). All logic stays in the existing bash scripts; Node only vendors files and edits JSON. `CLAUDE_CONFIG_DIR` (Claude Code's own `~/.claude` override) is the hermetic test seam. Tests are bats-driven e2e through the real CLI.

**Tech Stack:** Node ≥18 (built-ins only: fs, path, os, readline, child_process), bats-core (devDependency), npm.

## Global Constraints

- **Zero runtime dependencies** — Node built-ins only; `devDependencies` may hold bats
- Bash scripts stay the single source of truth; `hooks/hooks.json` is the single hook template for both channels
- Managed markers, exact strings: hooks `"_managedBy": "cc-gitflow-regulator@<version>"`; command frontmatter `x-managed-by: cc-gitflow-regulator@<version>`
- Paths embedded in hook commands use forward slashes (`posix()`) — bash double-quotes treat backslashes as escapes on Windows
- Duplicate detection never consults versions; versions feed only staleness warnings
- `install` refuses when any registration exists outside the target scope's managed block; `--force` overrides
- `doctor` never edits config; exits non-zero on any error
- No version bumps — `package.json` is born at the current 0.3.0 and moves only at the release cut
- Tests are authoritative on CI (ubuntu); local Windows runs use the `cygpath -m` shim shown in the test files

---

### Task 1: Package manifest + CLI skeleton

**Files:**
- Create: `package.json`
- Create: `bin/cli.js` (skeleton — Task 4 replaces it wholesale)
- Test: `tests/cli.bats` (started here, grown in Tasks 4–5)

**Interfaces:**
- Consumes: nothing
- Produces: `require('../package.json').version` (every lib module reads this); `node bin/cli.js --version` → version string on stdout, exit 0; unknown command → usage on stdout, exit 2

- [ ] **Step 1: Write the failing test**

Create `tests/cli.bats`:

```bash
#!/usr/bin/env bats
# End-to-end tests through the real CLI under a hermetic CLAUDE_CONFIG_DIR.
# Windows note: every path handed to node — argv, env, and paths embedded
# inside node -e script strings (which MSYS path conversion never sees) —
# goes through cygpath -m first, yielding C:/mixed/form that node and bash
# both accept. On linux/CI cygpath is absent and plain paths already work.

CLI="$BATS_TEST_DIRNAME/../bin/cli.js"
LIB="$BATS_TEST_DIRNAME/../lib"
PKG="$BATS_TEST_DIRNAME/../package.json"

setup() {
  if command -v cygpath >/dev/null; then
    CLI="$(cygpath -m "$CLI")"; LIB="$(cygpath -m "$LIB")"; PKG="$(cygpath -m "$PKG")"
  fi
  tmp="$BATS_TEST_TMPDIR"
  command -v cygpath >/dev/null && tmp="$(cygpath -m "$tmp")"
  export CLAUDE_CONFIG_DIR="$tmp/claude"
  mkdir -p "$CLAUDE_CONFIG_DIR"
  REPO="$tmp/repo"
  git init -q -b main "$REPO"
}

@test "--version prints the package version" {
  run node "$CLI" --version
  [ "$status" -eq 0 ]
  [ "$output" = "$(node -p "require('$PKG').version")" ]
}

@test "no command prints usage" {
  run node "$CLI"
  [ "$status" -eq 0 ]
  [[ "$output" == usage:* ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `npx bats tests/cli.bats`
Expected: FAIL — `bin/cli.js` does not exist.

- [ ] **Step 3: Write package.json and the skeleton**

Create `package.json` (version matches the current manifests — the release cut moves it):

```json
{
  "name": "cc-gitflow-regulator",
  "version": "0.3.0",
  "description": "Gitflow guardrails for Claude Code worktrees — rename to feature/*, fork from develop, completion alerts, local-first delivery.",
  "bin": { "cc-gitflow-regulator": "bin/cli.js" },
  "files": ["bin/", "lib/", "scripts/", "commands/", "hooks/"],
  "scripts": { "test": "bats tests/" },
  "engines": { "node": ">=18" },
  "license": "MIT",
  "author": "Jared Parmenter <jared.parmenter@gmail.com>",
  "homepage": "https://github.com/jagp/cc-gitflow-regulator",
  "repository": { "type": "git", "url": "git+https://github.com/jagp/cc-gitflow-regulator.git" },
  "keywords": ["git", "gitflow", "worktree", "claude-code", "hooks"],
  "devDependencies": { "bats": "^1.11.0" }
}
```

Create `bin/cli.js`:

```js
#!/usr/bin/env node
// cc-gitflow-regulator CLI — skeleton: usage + --version.
// install/uninstall/doctor land alongside their lib/ modules (Tasks 2-5).
const VERSION = require('../package.json').version;
const cmd = process.argv[2];
if (cmd === '--version' || cmd === '-v') { console.log(VERSION); process.exit(0); }
console.log('usage: cc-gitflow-regulator <install|uninstall|doctor|--version> [--scope user|project] [--force]');
process.exit(cmd ? 2 : 0);
```

- [ ] **Step 4: Run tests + pack sanity**

Run: `npm install && npx bats tests/cli.bats && npm pack --dry-run`
Expected: `2 tests, 0 failures`; pack lists `bin/`, `lib/` (once it exists), `scripts/*.sh`, `commands/finish-branch.md`, `hooks/hooks.json`, `README.md`, `LICENSE`, `package.json` — and none of `assets/`, `*.png`, `.claude-plugin/`, `tests/`, `docs/`.

- [ ] **Step 5: Commit** (`node_modules/` and `*.tgz` must not be committed — add `.gitignore` entries if the repo lacks them)

```bash
printf 'node_modules/\n*.tgz\n' >> .gitignore
git add package.json package-lock.json bin/cli.js tests/cli.bats .gitignore
git commit -m "feat: npm package manifest and CLI skeleton"
```

---

### Task 2: `lib/paths.js` + `lib/util.js`

**Files:**
- Create: `lib/paths.js`
- Create: `lib/util.js`
- Test: `tests/lib.bats`

**Interfaces:**
- Consumes: `CLAUDE_CONFIG_DIR` env var (optional)
- Produces (exact signatures later tasks call):
  - `paths.claudeDir(scope, repoRoot)` → string; `'user'` honors `CLAUDE_CONFIG_DIR`, `'project'` → `<repoRoot>/.claude`
  - `paths.settingsPath(scope, repoRoot)`, `paths.localSettingsPath(scope, repoRoot)`, `paths.vendorRoot(scope, repoRoot)`, `paths.commandsDir(scope, repoRoot)` → strings
  - `paths.posix(p)` → forward-slash form of `p`
  - `util.readJson(file)` → object | null (never throws); `util.writeJson(file, obj)` → 2-space indent + trailing newline, mkdir -p; `util.cmpVersion(a, b)` → -1|0|1

- [ ] **Step 1: Write the failing test**

Create `tests/lib.bats`:

```bash
#!/usr/bin/env bats
# Unit checks for the two pure modules, driven through node -e.
# LIB is embedded in -e strings, which MSYS never converts — cygpath it.

LIB="$BATS_TEST_DIRNAME/../lib"

setup() {
  command -v cygpath >/dev/null && LIB="$(cygpath -m "$LIB")"
}

@test "cmpVersion orders numerically, not lexically" {
  run node -e "
    const {cmpVersion} = require('$LIB/util.js');
    const assert = require('assert');
    assert.equal(cmpVersion('0.3.0','0.10.0'), -1);  // lexical would say 1
    assert.equal(cmpVersion('1.0.0','0.9.9'), 1);
    assert.equal(cmpVersion('0.3.1','0.3.1'), 0);
    console.log('ok');
  "
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "posix flips backslashes; claudeDir honors CLAUDE_CONFIG_DIR" {
  run env CLAUDE_CONFIG_DIR=/tmp/seam node -e "
    const p = require('$LIB/paths.js');
    const assert = require('assert');
    assert.equal(p.posix('C:\\\\a\\\\b'), 'C:/a/b');
    assert.equal(p.claudeDir('user'), '/tmp/seam');
    assert.ok(p.settingsPath('project','/r').replace(/\\\\/g,'/').endsWith('/r/.claude/settings.json'));
    console.log('ok');
  "
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}

@test "readJson swallows garbage; writeJson round-trips with stable format" {
  run node -e "
    const {readJson, writeJson} = require('$LIB/util.js');
    const assert = require('assert'), fs = require('fs');
    const f = process.env.BATS_TEST_TMPDIR + '/x/y.json';
    assert.equal(readJson('/nope'), null);
    writeJson(f, {a: 1});
    assert.equal(fs.readFileSync(f, 'utf8'), '{\n  \"a\": 1\n}\n');
    console.log('ok');
  "
  [ "$status" -eq 0 ]
  [ "$output" = "ok" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `npx bats tests/lib.bats`
Expected: FAIL — `lib/` does not exist.

- [ ] **Step 3: Implement**

Create `lib/paths.js`:

```js
// Path map for both delivery scopes. CLAUDE_CONFIG_DIR mirrors Claude
// Code's own override for ~/.claude — and doubles as the hermetic test
// seam, so tests never touch the real machine.
const os = require('os');
const path = require('path');

// bash double-quotes treat backslashes as escapes, so every path embedded
// in a hook command line goes through posix() first.
const posix = (p) => p.replace(/\\/g, '/');

function claudeDir(scope, repoRoot) {
  if (scope === 'project') return path.join(repoRoot, '.claude');
  return process.env.CLAUDE_CONFIG_DIR || path.join(os.homedir(), '.claude');
}

module.exports = {
  posix,
  claudeDir,
  settingsPath: (scope, repoRoot) => path.join(claudeDir(scope, repoRoot), 'settings.json'),
  localSettingsPath: (scope, repoRoot) => path.join(claudeDir(scope, repoRoot), 'settings.local.json'),
  vendorRoot: (scope, repoRoot) => path.join(claudeDir(scope, repoRoot), 'cc-gitflow-regulator'),
  commandsDir: (scope, repoRoot) => path.join(claudeDir(scope, repoRoot), 'commands'),
};
```

Create `lib/util.js`:

```js
// Tiny shared helpers — no dependencies, ever (node is the delivery
// vehicle here, never the runtime).
const fs = require('fs');
const path = require('path');

function readJson(file) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch { return null; }
}

function writeJson(file, obj) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, JSON.stringify(obj, null, 2) + '\n');
}

// numeric semver compare (x.y.z only): -1 | 0 | 1
function cmpVersion(a, b) {
  const pa = String(a).split('.').map(Number), pb = String(b).split('.').map(Number);
  for (let i = 0; i < 3; i++) {
    if ((pa[i] || 0) < (pb[i] || 0)) return -1;
    if ((pa[i] || 0) > (pb[i] || 0)) return 1;
  }
  return 0;
}

module.exports = { readJson, writeJson, cmpVersion };
```

- [ ] **Step 4: Run tests**

Run: `npx bats tests/lib.bats`
Expected: `3 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add lib/paths.js lib/util.js tests/lib.bats
git commit -m "feat: paths and util modules for the npm installer"
```

---

### Task 3: `lib/scan.js` — the eight-surface registration scanner

**Files:**
- Create: `lib/scan.js`
- Test: `tests/scan.bats`

**Interfaces:**
- Consumes: `paths.*`, `util.readJson`, `util.cmpVersion` (Task 2 signatures)
- Produces: `scan({ repoRoot, ourVersion })` → `{ registrations, problems }`
  - registration: `{ event, scope, source: 'managed'|'marketplace'|'manual', version: string|null, target, targetExists: bool|null, file }`
  - problem: `{ severity: 'error'|'warning', code: 'DUPLICATE'|'BROKEN'|'STALE'|'ORPHAN', msg, hits: registration[] }`
  - `EVENTS` export: `['PostToolUse', 'Stop', 'SessionEnd']`
  - Note: `'manual'` labels an entry running our scripts without a marker (a user hand-copy) — counted for duplicates like everything else; display-only distinction

- [ ] **Step 1: Write the failing test**

Create `tests/scan.bats`:

```bash
#!/usr/bin/env bats
# Scanner tests: build settings/cache fixtures, assert counts and problems.

LIB="$BATS_TEST_DIRNAME/../lib"

setup() {
  command -v cygpath >/dev/null && LIB="$(cygpath -m "$LIB")"
  tmp="$BATS_TEST_TMPDIR"
  command -v cygpath >/dev/null && tmp="$(cygpath -m "$tmp")"
  export CLAUDE_CONFIG_DIR="$tmp/claude"
  mkdir -p "$CLAUDE_CONFIG_DIR"
}

# helper: run scan, print "<#regs> <#errors> <#warnings> <codes,>"
run_scan() {
  node -e "
    const {scan} = require('$LIB/scan.js');
    const r = scan({repoRoot: process.argv[1] || null, ourVersion: '0.3.0'});
    const e = r.problems.filter(p => p.severity==='error').length;
    const w = r.problems.filter(p => p.severity==='warning').length;
    console.log(r.registrations.length, e, w, r.problems.map(p=>p.code).sort().join(','));
  " "$1"
}

write_managed_settings() {  # $1 = settings.json path, $2 = version tag
  node -e "
    const {writeJson} = require('$LIB/util.js');
    const entry = (sub) => ({type:'command',
      command: 'bash \"' + process.env.CLAUDE_CONFIG_DIR + '/cc-gitflow-regulator/$2/scripts/cc-gitflow-regulator.sh\" ' + sub,
      _managedBy: 'cc-gitflow-regulator@$2'});
    writeJson(process.argv[1], {hooks:{
      PostToolUse:[{matcher:'EnterWorktree',hooks:[entry('rename')]}],
      Stop:[{hooks:[entry('notify')]}],
      SessionEnd:[{hooks:[entry('end')]}]}});
  " "$1"
}

@test "empty machine scans clean" {
  run run_scan ""
  [ "$output" = "0 0 0 " ]
}

@test "single managed install: 3 registrations, targets missing flagged BROKEN" {
  write_managed_settings "$CLAUDE_CONFIG_DIR/settings.json" "0.3.0"
  run run_scan ""
  # 3 regs; vendored scripts were never copied so each target is BROKEN
  [[ "$output" == "3 3 0 BROKEN,BROKEN,BROKEN" ]]
}

@test "user + project scope: DUPLICATE per event, no version consulted" {
  write_managed_settings "$CLAUDE_CONFIG_DIR/settings.json" "0.3.0"
  REPO="$tmp/repo"; mkdir -p "$REPO/.claude"
  write_managed_settings "$REPO/.claude/settings.json" "0.3.0"
  # create the vendored scripts so BROKEN stays out of the picture
  for base in "$CLAUDE_CONFIG_DIR" "$REPO/.claude"; do
    mkdir -p "$base/cc-gitflow-regulator/0.3.0/scripts"
    touch "$base/cc-gitflow-regulator/0.3.0/scripts/cc-gitflow-regulator.sh"
  done
  run run_scan "$REPO"
  [ "$output" = "6 3 0 DUPLICATE,DUPLICATE,DUPLICATE" ]
}

@test "enabled marketplace plugin registers all three events; stale version warns" {
  # fake the marketplace: enabledPlugins + a versioned cache dir with .in_use
  node -e "
    const {writeJson} = require('$LIB/util.js');
    writeJson(process.env.CLAUDE_CONFIG_DIR + '/settings.json',
      {enabledPlugins: {'cc-gitflow-regulator@cc-gitflow-regulator': true}});
  "
  mkdir -p "$CLAUDE_CONFIG_DIR/plugins/cache/cc-gitflow-regulator/cc-gitflow-regulator/0.1.0"
  touch "$CLAUDE_CONFIG_DIR/plugins/cache/cc-gitflow-regulator/cc-gitflow-regulator/0.1.0/.in_use"
  run run_scan ""
  # 3 regs (one per event), no duplicates, one deduped STALE warning
  [ "$output" = "3 0 1 STALE" ]
}

@test "orphaned vendor dir warns" {
  mkdir -p "$CLAUDE_CONFIG_DIR/cc-gitflow-regulator/0.2.0/scripts"
  run run_scan ""
  [ "$output" = "0 0 1 ORPHAN" ]
}

@test "duplicate /finish-branch definitions warn (surface 8)" {
  mkdir -p "$CLAUDE_CONFIG_DIR/commands"
  echo x > "$CLAUDE_CONFIG_DIR/commands/finish-branch.md"
  REPO2="$tmp/repo2"; mkdir -p "$REPO2/.claude/commands"
  echo x > "$REPO2/.claude/commands/finish-branch.md"
  run run_scan "$REPO2"
  [ "$output" = "0 0 1 CMD_DUP" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `npx bats tests/scan.bats`
Expected: FAIL — `lib/scan.js` does not exist.

- [ ] **Step 3: Implement**

Create `lib/scan.js`:

```js
// The registration scanner — answers "how many ways is this installed,
// at what versions, in what scopes?" across the spec's eight surfaces:
//   1-4  user/user-local/project/project-local settings files
//   5    enabledPlugins (marketplace install active?)
//   6    plugins/cache/*/*/<version>/ (which plugin versions exist)
//   7    <root>/cc-gitflow-regulator/<version>/ (our vendored trees)
//   8    <root>/commands/finish-branch.md (duplicate slash commands)
// Duplicate detection is arithmetic over the scan (count per hook event)
// and never consults versions; versions feed only the STALE warning.
const fs = require('fs');
const path = require('path');
const { readJson, cmpVersion } = require('./util');
const paths = require('./paths');

const EVENTS = ['PostToolUse', 'Stop', 'SessionEnd'];
// an entry is ours when its command runs one of our scripts (old plugin
// script name included so pre-rename marketplace caches still match)
const OURS = /cc-gitflow-regulator\.sh|claude-gitflow\.sh/;

const list = (dir) => { try { return fs.readdirSync(dir); } catch { return []; } };

// surfaces 1-4: hook entries inside one settings file
function scanSettingsFile(file, scope) {
  const hooks = (readJson(file) || {}).hooks || {};
  const found = [];
  for (const event of EVENTS) {
    for (const block of hooks[event] || []) {
      for (const h of block.hooks || []) {
        if (!OURS.test(h.command || '')) continue;
        const quoted = /"([^"]+\.sh)"/.exec(h.command || '');   // abs script path
        const target = quoted ? quoted[1] : '';
        found.push({
          event, scope,
          source: h._managedBy ? 'managed' : 'manual',
          version: h._managedBy ? h._managedBy.split('@')[1] : null,
          target,
          targetExists: target ? fs.existsSync(target) : null,
          file,
        });
      }
    }
  }
  return found;
}

// surfaces 5+6: an enabled marketplace plugin registers every event via
// its own hooks.json; its version comes from the cache dir (.in_use
// marks the active copy, else newest present)
function scanMarketplace(userDir) {
  const settings = readJson(path.join(userDir, 'settings.json')) || {};
  const enabled = Object.entries(settings.enabledPlugins || {})
    .some(([key, on]) => on && /cc-gitflow-regulator|claude-gitflow/.test(key));
  if (!enabled) return [];
  const cache = path.join(userDir, 'plugins', 'cache');
  const seen = [];
  for (const marketplace of list(cache)) {
    for (const plugin of list(path.join(cache, marketplace))) {
      if (!/cc-gitflow-regulator|claude-gitflow/.test(plugin)) continue;
      for (const v of list(path.join(cache, marketplace, plugin))) {
        if (!/^\d+\.\d+\.\d+$/.test(v)) continue;
        seen.push({ v, inUse: fs.existsSync(path.join(cache, marketplace, plugin, v, '.in_use')) });
      }
    }
  }
  seen.sort((a, b) => cmpVersion(a.v, b.v));
  const active = seen.find(s => s.inUse) || seen[seen.length - 1];
  return EVENTS.map((event) => ({
    event, scope: 'user', source: 'marketplace',
    version: active ? active.v : null,
    target: 'plugin cache', targetExists: true, file: 'enabledPlugins',
  }));
}

function scan({ repoRoot, ourVersion }) {
  const userDir = paths.claudeDir('user');
  const registrations = [
    ...scanSettingsFile(paths.settingsPath('user'), 'user'),
    ...scanSettingsFile(paths.localSettingsPath('user'), 'user-local'),
    ...(repoRoot ? scanSettingsFile(paths.settingsPath('project', repoRoot), 'project') : []),
    ...(repoRoot ? scanSettingsFile(paths.localSettingsPath('project', repoRoot), 'project-local') : []),
    ...scanMarketplace(userDir),
  ];

  const problems = [];
  // rule 1 (error): >1 registration per event — pure counting
  for (const event of EVENTS) {
    const hits = registrations.filter(r => r.event === event);
    if (hits.length > 1) problems.push({
      severity: 'error', code: 'DUPLICATE', hits,
      msg: `${event} has ${hits.length} registrations`,
    });
  }
  // rule 2 (error): registration points at a file that is gone
  for (const r of registrations) {
    if (r.targetExists === false) problems.push({
      severity: 'error', code: 'BROKEN', hits: [r],
      msg: `target missing: ${r.target}`,
    });
  }
  // rule 3 (warning): vendored tree nothing references
  for (const scope of ['user', 'project']) {
    if (scope === 'project' && !repoRoot) continue;
    const root = paths.vendorRoot(scope, repoRoot);
    for (const v of list(root)) {
      const referenced = registrations.some(r =>
        r.source === 'managed' && paths.posix(r.target).includes(`cc-gitflow-regulator/${v}/`));
      if (!referenced) problems.push({
        severity: 'warning', code: 'ORPHAN', hits: [],
        msg: `unreferenced vendor dir: ${paths.posix(path.join(root, v))}`,
      });
    }
  }
  // rule 4 (warning, the only version-aware rule): older than us
  const staleSeen = new Set();
  for (const r of registrations) {
    const key = `${r.source}@${r.version}`;
    if (!r.version || !ourVersion || staleSeen.has(key)) continue;
    if (cmpVersion(r.version, ourVersion) < 0) {
      staleSeen.add(key);
      problems.push({
        severity: 'warning', code: 'STALE', hits: [r],
        msg: `${r.source} install is ${r.version}, latest is ${ourVersion}`,
      });
    }
  }
  // surface 8 (warning): >1 definition of the /finish-branch command —
  // command files at each scope, plus the marketplace plugin's own copy
  const cmdDefs = [];
  for (const scope of ['user', 'project']) {
    if (scope === 'project' && !repoRoot) continue;
    const f = path.join(paths.commandsDir(scope, repoRoot), 'finish-branch.md');
    if (fs.existsSync(f)) cmdDefs.push(`${scope}: ${paths.posix(f)}`);
  }
  if (registrations.some((r) => r.source === 'marketplace')) cmdDefs.push('marketplace plugin');
  if (cmdDefs.length > 1) problems.push({
    severity: 'warning', code: 'CMD_DUP', hits: [],
    msg: `/finish-branch defined ${cmdDefs.length}x: ${cmdDefs.join(', ')}`,
  });
  return { registrations, problems };
}

module.exports = { scan, EVENTS };
```

- [ ] **Step 4: Run tests**

Run: `npx bats tests/scan.bats tests/lib.bats`
Expected: `9 tests, 0 failures`.

- [ ] **Step 5: Commit**

```bash
git add lib/scan.js tests/scan.bats
git commit -m "feat: eight-surface registration scanner (duplicates are version-blind)"
```

---

### Task 4: `install` + `uninstall` + full CLI dispatcher

**Files:**
- Create: `lib/install.js`
- Create: `lib/uninstall.js`
- Modify: `bin/cli.js` (replace the Task-1 skeleton wholesale)
- Test: `tests/cli.bats` (append)

**Interfaces:**
- Consumes: `scan()` (Task 3), `paths.*`/`util.*` (Task 2), `hooks/hooks.json` template, `commands/finish-branch.md`
- Produces:
  - `install.resolveScope(flags)` → Promise<'user'|'project'> (prompts unless `flags.scope`)
  - `install.install(scope, repoRoot)` → `{ vendored, file }`
  - `install.stripManaged(settings)` → settings (managed entries removed, emptied containers pruned) — uninstall reuses this
  - `uninstall.uninstall(scope, repoRoot)` → `{ file }`
  - CLI exit codes: refusal = 1, bad flags = 2, success = 0

- [ ] **Step 1: Append the failing e2e tests to `tests/cli.bats`**

```bash
# ---- install / uninstall / collision ----------------------------------

count_managed() {  # entries carrying our marker in $1 settings file
  node -e "
    const s = require('$LIB/util.js').readJson(process.argv[1]) || {};
    let n = 0;
    for (const ev of Object.values(s.hooks || {}))
      for (const b of ev) for (const h of b.hooks || []) if (h._managedBy) n++;
    console.log(n);
  " "$1"
}

@test "install --scope user: vendors, rewrites, marks, merges" {
  run node "$CLI" install --scope user
  [ "$status" -eq 0 ]
  [ "$(count_managed "$CLAUDE_CONFIG_DIR/settings.json")" = "3" ]
  # vendored script exists at the path the hook command references
  v="$(node -p "require('$PKG').version")"
  [ -f "$CLAUDE_CONFIG_DIR/cc-gitflow-regulator/$v/scripts/cc-gitflow-regulator.sh" ]
  # command file landed in discovery location, marked, fully rewritten
  grep -q "x-managed-by: cc-gitflow-regulator@$v" "$CLAUDE_CONFIG_DIR/commands/finish-branch.md"
  ! grep -q 'CLAUDE_PLUGIN_ROOT' "$CLAUDE_CONFIG_DIR/commands/finish-branch.md"
  ! grep -q 'CLAUDE_PLUGIN_ROOT' "$CLAUDE_CONFIG_DIR/settings.json"
}

@test "reinstall is idempotent: still exactly 3 managed entries" {
  node "$CLI" install --scope user
  node "$CLI" install --scope user
  [ "$(count_managed "$CLAUDE_CONFIG_DIR/settings.json")" = "3" ]
}

@test "install/uninstall round-trip leaves settings byte-identical" {
  # seed a settings file with unrelated content, in writeJson's format
  node -e "
    require('$LIB/util.js').writeJson(process.argv[1],
      {model: 'opus', hooks: {PreToolUse: [{matcher: 'Bash',
        hooks: [{type: 'command', command: 'echo hi'}]}]}});
  " "$CLAUDE_CONFIG_DIR/settings.json"
  cp "$CLAUDE_CONFIG_DIR/settings.json" "$BATS_TEST_TMPDIR/before.json"
  node "$CLI" install --scope user
  node "$CLI" uninstall --scope user
  cmp "$BATS_TEST_TMPDIR/before.json" "$CLAUDE_CONFIG_DIR/settings.json"
  [ ! -e "$CLAUDE_CONFIG_DIR/commands/finish-branch.md" ]
  [ ! -e "$CLAUDE_CONFIG_DIR/cc-gitflow-regulator" ]
}

@test "cross-scope install refuses; --force overrides" {
  node "$CLI" install --scope user
  cd "$REPO"
  run node "$CLI" install --scope project
  [ "$status" -eq 1 ]
  [[ "$output" == *refused* ]]
  run node "$CLI" install --scope project --force
  [ "$status" -eq 0 ]
  [ "$(count_managed "$REPO/.claude/settings.json")" = "3" ]
}

@test "install refuses when the marketplace plugin is enabled" {
  node -e "
    require('$LIB/util.js').writeJson(
      process.env.CLAUDE_CONFIG_DIR + '/settings.json',
      {enabledPlugins: {'cc-gitflow-regulator@cc-gitflow-regulator': true}});
  "
  run node "$CLI" install --scope user
  [ "$status" -eq 1 ]
  [[ "$output" == *refused* ]]
}

@test "uninstall never deletes a hand-written command file" {
  mkdir -p "$CLAUDE_CONFIG_DIR/commands"
  echo "my own notes" > "$CLAUDE_CONFIG_DIR/commands/finish-branch.md"
  node "$CLI" uninstall --scope user
  [ -f "$CLAUDE_CONFIG_DIR/commands/finish-branch.md" ]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `npx bats tests/cli.bats`
Expected: the two Task-1 tests PASS; every new test FAILS (`install` prints usage, exit 2).

- [ ] **Step 3: Implement**

Create `lib/install.js`:

```js
// install: resolve scope (flag or prompt) -> vendor-copy the scripts ->
// copy+mark the slash command -> merge marked hook entries into settings.
// Reinstall is idempotent: the managed block is stripped and rewritten.
// The refusal gate lives in bin/cli.js so uninstall can reuse the pieces.
const fs = require('fs');
const path = require('path');
const readline = require('readline');
const { readJson, writeJson } = require('./util');
const paths = require('./paths');

const PKG_ROOT = path.join(__dirname, '..');
const VERSION = require('../package.json').version;
const MARK = `cc-gitflow-regulator@${VERSION}`;

async function resolveScope(flags) {
  if (flags.scope) return flags.scope;
  const rl = readline.createInterface({ input: process.stdin, output: process.stdout });
  const answer = await new Promise((res) => rl.question(
    'Where should the gitflow guardrails apply?\n' +
    '  1) This machine  — ~/.claude/settings.json (all repos)\n' +
    '  2) This repo     — .claude/settings.json (commit it; whole team gets them)\n' +
    'Choice [1/2]: ', res));
  rl.close();
  return answer.trim() === '2' ? 'project' : 'user';
}

// remove every entry we ever wrote; prune containers emptied by that
function stripManaged(settings) {
  const hooks = settings.hooks || {};
  for (const event of Object.keys(hooks)) {
    hooks[event] = (hooks[event] || []).map((block) => ({
      ...block,
      hooks: (block.hooks || []).filter((h) => !h._managedBy),
    })).filter((block) => block.hooks.length);
    if (!hooks[event].length) delete hooks[event];
  }
  if (!Object.keys(hooks).length) delete settings.hooks;
  return settings;
}

function install(scope, repoRoot) {
  const vendored = path.join(paths.vendorRoot(scope, repoRoot), VERSION);
  const scriptsAbs = paths.posix(path.join(vendored, 'scripts'));

  // 1. vendor the scripts — the npm package is disposable after this copy
  fs.cpSync(path.join(PKG_ROOT, 'scripts'), path.join(vendored, 'scripts'), { recursive: true });

  // 2. slash command -> its discovery location, PLUGIN_ROOT rewritten to
  //    the vendored path, ownership marked in frontmatter
  const cmdSrc = fs.readFileSync(path.join(PKG_ROOT, 'commands', 'finish-branch.md'), 'utf8');
  const marked = cmdSrc
    .replace(/\$\{CLAUDE_PLUGIN_ROOT\}\/scripts/g, scriptsAbs)
    .replace(/^---\r?\n/, `---\nx-managed-by: ${MARK}\n`);
  fs.mkdirSync(paths.commandsDir(scope, repoRoot), { recursive: true });
  fs.writeFileSync(path.join(paths.commandsDir(scope, repoRoot), 'finish-branch.md'), marked);

  // 3. hooks.json is the single template for both channels: rewrite each
  //    command, stamp _managedBy, merge into the scope's settings file
  const template = readJson(path.join(PKG_ROOT, 'hooks', 'hooks.json')).hooks;
  const file = paths.settingsPath(scope, repoRoot);
  const settings = stripManaged(readJson(file) || {});
  settings.hooks = settings.hooks || {};
  for (const [event, blocks] of Object.entries(template)) {
    settings.hooks[event] = settings.hooks[event] || [];
    for (const block of blocks) {
      settings.hooks[event].push({
        ...block,
        hooks: block.hooks.map((h) => ({
          ...h,
          command: h.command.replace('${CLAUDE_PLUGIN_ROOT}/scripts', scriptsAbs),
          _managedBy: MARK,
        })),
      });
    }
  }
  writeJson(file, settings);
  return { vendored, file };
}

module.exports = { install, resolveScope, stripManaged };
```

Create `lib/uninstall.js`:

```js
// uninstall: strip our managed hook entries at the chosen scope, delete
// the command file only if we wrote it (x-managed-by), remove the vendor
// tree. Anything the installer did not write is never touched.
const fs = require('fs');
const path = require('path');
const { readJson, writeJson } = require('./util');
const paths = require('./paths');
const { stripManaged } = require('./install');

function uninstall(scope, repoRoot) {
  const file = paths.settingsPath(scope, repoRoot);
  const settings = readJson(file);
  if (settings) writeJson(file, stripManaged(settings));

  const cmd = path.join(paths.commandsDir(scope, repoRoot), 'finish-branch.md');
  let text = '';
  try { text = fs.readFileSync(cmd, 'utf8'); } catch { /* absent is fine */ }
  if (/^x-managed-by: cc-gitflow-regulator@/m.test(text)) fs.rmSync(cmd);

  fs.rmSync(paths.vendorRoot(scope, repoRoot), { recursive: true, force: true });
  return { file };
}

module.exports = { uninstall };
```

Replace `bin/cli.js` wholesale:

```js
#!/usr/bin/env node
// cc-gitflow-regulator CLI — the npm delivery channel. All gitflow logic
// stays in the vendored bash scripts; this CLI only vendors files and
// edits JSON. Exit codes: 0 ok, 1 refusal/problem, 2 bad invocation.
const { execFileSync } = require('child_process');
const VERSION = require('../package.json').version;

function repoRoot() {
  try {
    return execFileSync('git', ['rev-parse', '--show-toplevel'],
      { stdio: ['ignore', 'pipe', 'ignore'] }).toString().trim();
  } catch { return null; }
}

function parseFlags(argv) {
  const flags = { force: false, scope: null };
  for (let i = 0; i < argv.length; i++) {
    if (argv[i] === '--force') flags.force = true;
    else if (argv[i] === '--scope') flags.scope = argv[++i];
    else { console.error(`unknown flag: ${argv[i]}`); process.exit(2); }
  }
  if (flags.scope && !['user', 'project'].includes(flags.scope)) {
    console.error('--scope must be user|project'); process.exit(2);
  }
  return flags;
}

(async () => {
  const [cmd, ...rest] = process.argv.slice(2);
  if (cmd === '--version' || cmd === '-v') { console.log(VERSION); return; }
  const flags = parseFlags(rest);
  const root = repoRoot();

  if (cmd === 'doctor') {
    const { doctor } = require('../lib/doctor');
    process.exit(doctor({ repoRoot: root, ourVersion: VERSION }));
  }

  if (cmd === 'install') {
    const { install, resolveScope } = require('../lib/install');
    const scope = await resolveScope(flags);
    if (scope === 'project' && !root) {
      console.error('not inside a git repository; --scope project needs one');
      process.exit(1);
    }
    // refusal gate: anything registered outside this scope's own managed
    // block would double-fire the hooks after install
    const { scan } = require('../lib/scan');
    const { registrations } = scan({ repoRoot: root, ourVersion: VERSION });
    const conflicting = registrations.filter(
      (r) => !(r.source === 'managed' && r.scope === scope));
    if (conflicting.length && !flags.force) {
      console.log('install refused — these existing registrations would double-fire:');
      for (const r of conflicting) {
        console.log(`  ${r.scope.padEnd(8)} ${r.source.padEnd(12)} ${(r.version || '-').padEnd(7)} ${r.file}`);
      }
      console.log('run `npx cc-gitflow-regulator doctor` for details, or pass --force to override.');
      process.exit(1);
    }
    const r = install(scope, root);
    console.log(`  ✓ vendored scripts → ${r.vendored}`);
    console.log(`  ✓ merged 3 hooks   → ${r.file}`);
    console.log('  run `npx cc-gitflow-regulator doctor` to verify.');
    return;
  }

  if (cmd === 'uninstall') {
    const { uninstall } = require('../lib/uninstall');
    const r = uninstall(flags.scope || 'user', root);
    console.log(`  ✓ removed managed entries from ${r.file}`);
    return;
  }

  console.log('usage: cc-gitflow-regulator <install|uninstall|doctor|--version> [--scope user|project] [--force]');
  process.exit(cmd ? 2 : 0);
})();
```

- [ ] **Step 4: Run the suite** (doctor test still absent — Task 5)

Run: `npx bats tests/cli.bats tests/lib.bats tests/scan.bats`
Expected: all tests pass — `install`/`uninstall`/collision green; `2 + 6` cli tests, 3 lib, 6 scan.

- [ ] **Step 5: Commit**

```bash
git add lib/install.js lib/uninstall.js bin/cli.js tests/cli.bats
git commit -m "feat: install/uninstall with vendor-copy, managed markers, cross-scope refusal"
```

---

### Task 5: `doctor`

**Files:**
- Create: `lib/doctor.js`
- Test: `tests/cli.bats` (append)

**Interfaces:**
- Consumes: `scan()` (Task 3)
- Produces: `doctor({ repoRoot, ourVersion })` → exit code int (0 clean/warnings, 1 any error or missing runtime dep); report on stdout

- [ ] **Step 1: Append the failing tests to `tests/cli.bats`**

```bash
# ---- doctor -----------------------------------------------------------

@test "doctor: clean machine exits 0" {
  run node "$CLI" doctor
  [ "$status" -eq 0 ]
  [[ "$output" == *"no problems"* ]]
}

@test "doctor: forced double-scope install exits 1 with DUPLICATE lines" {
  node "$CLI" install --scope user
  cd "$REPO"
  node "$CLI" install --scope project --force
  run node "$CLI" doctor
  [ "$status" -eq 1 ]
  [[ "$output" == *DUPLICATE* ]]
  [[ "$output" == *"3 error(s)"* ]]
}
```

- [ ] **Step 2: Run to verify failure**

Run: `npx bats tests/cli.bats`
Expected: the two doctor tests FAIL (`Cannot find module '../lib/doctor'`); everything else passes.

- [ ] **Step 3: Implement**

Create `lib/doctor.js`:

```js
// doctor: render the scan and check runtime deps. Reports and prints
// remediation — never edits configuration (destructive fixes are the
// user's call). Exit 1 on any error so CI can gate on it.
const { execFileSync } = require('child_process');
const { scan } = require('./scan');

function checkDeps() {
  const deps = [];
  try {
    const m = /(\d+)\.(\d+)/.exec(execFileSync('git', ['--version']).toString());
    const ok = !!m && (+m[1] > 2 || (+m[1] === 2 && +m[2] >= 31));
    deps.push({ ok, msg: `git >= 2.31 (found ${m ? m[0] : 'none'})` });
  } catch { deps.push({ ok: false, msg: 'git not found' }); }
  try {
    execFileSync('bash', ['--version'], { stdio: 'ignore' });
    deps.push({ ok: true, msg: 'bash present' });
  } catch { deps.push({ ok: false, msg: 'bash not found' }); }
  return deps;
}

function doctor({ repoRoot, ourVersion }) {
  const { registrations, problems } = scan({ repoRoot, ourVersion });
  for (const p of problems) {
    console.log(`  ${p.severity === 'error' ? '✗' : '⚠'} ${p.code.padEnd(9)} ${p.msg}`);
    for (const h of p.hits) {
      console.log(`      ${h.scope.padEnd(8)} ${h.source.padEnd(12)} ${(h.version || '-').padEnd(7)} ${h.file}`);
    }
  }
  const deps = checkDeps();
  for (const d of deps) console.log(`  ${d.ok ? '✓' : '✗'} ${d.msg}`);
  if (!problems.length) console.log(`  ✓ ${registrations.length} registration(s), no problems`);

  const errors = problems.filter((p) => p.severity === 'error').length;
  const warnings = problems.length - errors;
  console.log(`\n  ${errors} error(s), ${warnings} warning(s).`);
  if (errors) console.log('  fix: keep exactly one registration per event — `uninstall --scope <s>` removes ours; `/plugin uninstall` removes the marketplace copy.');
  return errors || deps.some((d) => !d.ok) ? 1 : 0;
}

module.exports = { doctor };
```

- [ ] **Step 4: Run the full suite**

Run: `npx bats tests/`
Expected: all tests pass, 0 failures (cli 10, lib 3, scan 6, rename 4).

- [ ] **Step 5: Commit**

```bash
git add lib/doctor.js tests/cli.bats
git commit -m "feat: doctor — report registrations, duplicates, staleness, runtime deps"
```

---

### Task 6: Documentation

**Files:**
- Modify: `README.md` (Installation section)
- Modify: `CLAUDE.md` (Layout section)

**Interfaces:**
- Consumes: the CLI surface as shipped in Tasks 1–5
- Produces: user-facing install docs for both channels

- [ ] **Step 1: Extend README's Installation section**

Replace the current Installation section body (the single fenced block) with:

```markdown
Two channels, same plugin — pick one. Installing both double-fires every
hook; the npm installer refuses if it detects the other.

### Claude Code marketplace

```install
/plugin marketplace add jagp/cc-gitflow-regulator
/plugin install cc-gitflow-regulator@cc-gitflow-regulator
```

### npm

```bash
npx cc-gitflow-regulator install     # prompts: this machine, or this repo
npx cc-gitflow-regulator doctor      # verify — flags duplicates and stale installs
npx cc-gitflow-regulator uninstall   # removes exactly what install wrote
```

`install` copies the scripts to a stable versioned directory under
`.claude/`, wires the hooks with absolute paths, and marks everything it
writes — so `uninstall` is surgical and never touches config you authored.
```

- [ ] **Step 2: Extend CLAUDE.md Layout**

Add to the Layout list:

```markdown
- `bin/cli.js` + `lib/` — npm channel: vendor-copy installer, 8-surface registration scanner, doctor
- `tests/*.bats` — bats suite; run `npx bats tests/`
```

- [ ] **Step 3: Verify docs claims against reality**

Run: `npx bats tests/ && node bin/cli.js --version`
Expected: suite green; version prints — the commands the README promises all exist.

- [ ] **Step 4: Commit**

```bash
git add README.md CLAUDE.md
git commit -m "docs: two-channel installation, npm CLI reference"
```

---

## Self-Review Notes

- Spec coverage: package shape ✓ (T1), CLI surface ✓ (T1/T4/T5), scanner w/ 8 surfaces ✓ (T3 — surface 8 is checked via the command-file collision handled in install/uninstall marking), install flow ✓ (T4), managed block ✓ (T4), scope prompt ✓ (T4), config-repair policy ✓ (doctor never edits, T5), tests incl. byte-identical round-trip and cross-scope collision ✓ (T4).
- Deviation from spec, deliberate: source label `'manual'` for an unmarked entry running our scripts (spec lists only managed/marketplace). It is display-only; duplicates count it regardless.
- Type consistency: `install(scope, repoRoot)` — the refusal gate lives in `bin/cli.js`, not `lib/install.js`, so `resolveScope` runs first and the gate can exclude the target scope's own managed block.
