# npm as a second delivery channel — 0.3.1

Status: approved design, pending implementation plan
Date: 2026-08-12
Branch: `feature/bump-0.3.1` → `release/0.3.1`

## Problem

`cc-gitflow-regulator` ships only through the Claude Code plugin marketplace.
Reaching users outside that channel needs a second delivery path.

Two constraints shape everything below:

1. **`${CLAUDE_PLUGIN_ROOT}` only exists for marketplace installs.** Every hook
   in `hooks/hooks.json` and both invocations in `commands/finish-branch.md`
   (lines 18, 63) reference it. Claude Code resolves it at hook-fire time
   because it *mounts* the plugin. An npm package has no mount point, so the
   npm path must resolve those references itself, at install time.

2. **A second channel is a second way to register the same hooks.** The
   canonical collision: an install at user scope plus a committed
   project-scope install — identical versions, identical source, and every
   hook still fires twice.

Cost of a duplicate registration, per hook:

- `rename` — a second `git branch -m` against an already-renamed branch;
  without idempotence, a misleading "target may already exist" error
- `notify` — fires on every `Stop`, i.e. **every turn**; doubles process spawns
- `end` — two processes racing to detach HEAD on one worktree; a correctness
  hazard, not merely waste

## Decisions

| Decision                | Choice                                             |
| ----------------------- | -------------------------------------------------- |
| Registry                | npm (name `cc-gitflow-regulator`, verified free)    |
| Install mechanism       | Vendor-copy via `npx`                               |
| Scope                   | Prompt at install; `--scope` bypasses               |
| Repo slug               | Rename GitHub repo to `jagp/cc-gitflow-regulator`   |
| Collision handling      | `install` refuses on error; `--force` overrides     |
| Config repair           | Report + remediation only; never auto-edit          |

### Why npm, given the logic is bash

Bash has no canonical package manager. `bpkg` and `basher` are effectively
dormant; Homebrew is Windows-hostile; `curl | bash` is awkward on Windows.
npm wins for one reason: **Claude Code is a Node CLI, so every possible user of
this plugin already has npm** — uniformly on Windows, macOS, and Linux. The
choice is about reach, not idiom. Node is a delivery vehicle and installer;
it never becomes runtime logic.

Consequence: npm cannot express the real dependencies (`git ≥ 2.31`, `bash`).
Those stay runtime checks, which is part of why `doctor` exists.

### Why vendor-copy rather than live paths

`npx` caches to a temp directory that npm garbage-collects. Hooks pointed at
the npx download would work for days, then fail with `No such file or
directory`. Global-install live paths fail differently: `nvm`/`volta`/`fnm`
switches and Windows prefix variation move the path out from under the hooks.

Copying to a stable, version-stamped location makes the npm package disposable
after install — the failure mode disappears rather than being mitigated.

## Architecture

### Package shape

`package.json` at repo root:

- `bin`: `{ "cc-gitflow-regulator": "./bin/cli.js" }`
- **zero runtime dependencies** — Node's built-in JSON handling covers the
  settings merge, so installing needs no `jq` (the scripts' existing
  jq-optional runtime behavior is unchanged)
- `files`: `scripts/`, `commands/`, `hooks/`, `bin/`, `README.md`, `LICENSE`
- excluded: `assets/`, the four root icon PNGs, `.claude-plugin/`

The bash scripts remain the single source of truth for all logic. Both delivery
channels ship the same `scripts/` directory.

### CLI surface

| Command     | Responsibility                                                        |
| ----------- | --------------------------------------------------------------------- |
| `install`   | scan → refuse on collision → prompt scope → copy → rewrite → merge     |
| `uninstall` | remove only the `_managedBy` block; `--scope` picks which one         |
| `doctor`    | report all registrations, versions, scopes; check runtime deps         |
| `--version` | print version; consumed by the CI sync check                           |

### The registration scanner

One scanner, shared by `install` and `doctor`. It answers "how many ways is
this installed, at what versions, in what scopes?" — not "is it installed?".
The second question is the only actionable one; on the machine described above
the first would have answered "yes" and explained nothing.

Seven surfaces:

| # | Surface                                      | Yields                       |
| - | -------------------------------------------- | ---------------------------- |
| 1 | `~/.claude/settings.json`                    | user-scope entries           |
| 2 | `~/.claude/settings.local.json`              | user-local entries           |
| 3 | `<repo>/.claude/settings.json`               | project-scope entries        |
| 4 | `<repo>/.claude/settings.local.json`         | project-local entries        |
| 5 | `enabledPlugins` in settings                 | active marketplace install   |
| 6 | `~/.claude/plugins/cache/*/*/<version>/`     | every plugin version on disk |
| 7 | `~/.claude/cc-gitflow-regulator/<version>/`  | our own vendored installs    |
| 8 | `<root>/commands/finish-branch.md`           | duplicate slash commands     |

Surface 8 exists because slash commands collide the same way hooks do: a
marketplace install already provides `/finish-branch`, so an npm install that
writes `~/.claude/commands/finish-branch.md` produces two definitions of one
command. Same class of bug, different registry.

Each hit is classified on four axes:

- **scope** — user / user-local / project / project-local
- **source** — `managed` (ours) / `marketplace`
- **version**
- **target** — path, and whether that path still exists

**Duplicate detection needs no version information.** It is arithmetic over the
scan: count the entries firing each hook event. Version attribution is a
separate concern, used only for staleness reporting. Keeping them independent
is what keeps the scanner small.

Every registration is version-attributable — marketplace installs through the
cache's versioned directory, npm installs through `_managedBy`.

Severity rules:

| Condition                                      | Severity | Needs version? |
| ---------------------------------------------- | -------- | -------------- |
| >1 registration for the same hook event        | error    | no             |
| registration target file does not exist        | error    | no             |
| vendored dir with no referencing registration  | warning  | no             |
| version below the newest present               | warning  | yes            |

Only the last rule consults versions. The canonical duplicate — a `managed`
user-scope install plus a `managed` project-scope install, both current, both
firing — is caught by the first rule without any version comparison at all.

`doctor` exits non-zero on any error, so it is CI-usable and scriptable.

Sample output — the canonical scope collision, where both installs are ours,
both current, and nothing is stale:

```
$ npx cc-gitflow-regulator doctor

  ✗ DUPLICATE  PostToolUse[EnterWorktree] has 2 registrations
      user     managed  0.3.1  ~/.claude/settings.json
      project  managed  0.3.1  ./.claude/settings.json
  ✗ DUPLICATE  Stop has 2 registrations         → 2 processes per turn
  ✗ DUPLICATE  SessionEnd has 2 registrations   → racing HEAD detach

  3 errors.

  To fix: uninstall one scope —
    npx cc-gitflow-regulator uninstall --scope user
```

This is what a teammate committing `.claude/settings.json` produces for someone
who already installed at user scope. Identical versions, identical source,
still double-firing — which is why duplicate detection is version-independent.

### Install flow

```
npx cc-gitflow-regulator install
  ├─ run scanner across all seven surfaces
  ├─ if any error → print report, REFUSE  (--force overrides)
  ├─ prompt: user scope or project scope?  (--scope skips, for CI)
  ├─ copy scripts/  → <root>/cc-gitflow-regulator/<version>/scripts/
  ├─ copy commands/ → <root>/commands/          (discovery location)
  ├─ rewrite ${CLAUDE_PLUGIN_ROOT} in both to the vendored scripts path
  └─ merge hooks.json's 3 entries into <root>/settings.json as a managed block

where <root> = ~/.claude  (user scope)  |  <repo>/.claude  (project scope)
```

Two destinations, because they are discovered differently. Scripts are
referenced by absolute path from the hook entries, so they can live anywhere
stable — the version-stamped vendor directory. Slash commands are discovered by
*location*: Claude Code scans `<root>/commands/`, so `finish-branch.md` must
land there and cannot be version-stamped. Its two `${CLAUDE_PLUGIN_ROOT}`
references (lines 18, 63) are rewritten to point into the vendored scripts
directory.

`hooks/hooks.json` ships in the tarball but is never registered directly — the
installer reads it as the template for the three entries it merges, keeping one
source of truth for hook definitions across both delivery channels.

Refuse-by-default is deliberate. A warning that can be scrolled past is not a
control; a duplicate installed today fires on every turn until someone notices.

### The managed block

Every entry the installer writes carries a marker:

```json
{
  "type": "command",
  "command": "bash \"/home/you/.claude/cc-gitflow-regulator/0.3.1/scripts/cc-gitflow-regulator.sh\" rename",
  "timeout": 30,
  "statusMessage": "gitflow: renaming worktree branch",
  "_managedBy": "cc-gitflow-regulator@0.3.1"
}
```

Claude Code ignores unknown keys, so the marker is free. It makes `uninstall`
surgical — remove entries matching `_managedBy`, never touch anything else —
and makes reinstall idempotent: strip the managed block, rewrite it.

The copied `finish-branch.md` gets the equivalent marker in its existing YAML
frontmatter:

```yaml
x-managed-by: cc-gitflow-regulator@0.3.1
```

so `uninstall` can tell a file it wrote from one the user placed there by hand,
and deletes only the former. Unknown frontmatter keys are ignored, same as the
JSON case.

Version-stamping the install directory means an upgrade writes `0.3.2/`
alongside `0.3.1/` and then swings the paths over, so a mid-upgrade failure
never leaves a half-written script tree.

### Scope prompt

```
Where should the gitflow guardrails apply?
  1) This machine  — ~/.claude/settings.json (all repos)
  2) This repo     — .claude/settings.json (commit it; whole team gets them)
```

`--scope user|project` bypasses the prompt for non-interactive installs.
Project scope is a genuine fit for this tool: branch conventions are a
team-level concern, and committing `.claude/settings.json` gives the whole team
the guardrails on clone.

### Config repair policy

`doctor` reports and prints remediation. It never edits configuration itself.
Deleting hooks from a user's `settings.json` is a destructive edit, and
CLAUDE.md's "destructive steps gated on user interaction" applies to config as
much as to `git reset`. `uninstall` removes our own managed block and nothing
else; entries the installer did not write are always the user's to remove.

## Behavior change: `rename` becomes idempotent

If the current branch already equals `<prefix><name>`, the rename has already
happened — exit 0 quietly instead of attempting `git branch -m` and reporting
"target may already exist".

Any duplicate registration, from any
source, present or future, degrades to a silent no-op rather than a misleading
error. The current message misattributes cause: it reads as a naming conflict
when the real cause was being invoked twice. When a hook can legitimately run
more than once, "already in the desired state" is a success path.

## Version single-sourcing

0.3.1 takes the version locations from three to four (`plugin.json`,
`marketplace.json`, `README.md:7`, and now `package.json`).

`package.json` becomes the source of truth. An `npm version` lifecycle hook
runs `scripts/sync-version.sh`, which rewrites the other three and `git add`s
them, so `npm version 0.3.1` produces one atomic commit and tag across all
four. CI re-asserts the invariant on every PR.

## Tooling

| Workflow      | Trigger    | Does                                                              |
| ------------- | ---------- | ----------------------------------------------------------------- |
| `ci.yml`      | PR / push  | shellcheck `scripts/*.sh`; validate all JSON; assert 4-way version agreement |
| `release.yml` | tag `v*`   | `npm publish --provenance` via OIDC trusted publishing            |

OIDC trusted publishing avoids storing a long-lived `NPM_TOKEN` in repo secrets.

Deliberately deferred: `release-please`, `changesets`, `shfmt`. Single-package
solo repo; not yet earning their complexity.

## Testing

There are zero tests today, so this is where they start. `bats-core`:

- **unit** — the two risky pure functions: settings-merge and path-rewrite
- **end-to-end** — `install → doctor → uninstall` against a temp `$HOME`,
  asserting `settings.json` is byte-identical before and after
- **collision** — install at user scope, then attempt project scope; assert
  `install` refuses and exits non-zero, and that `--force` proceeds.
- **idempotence** — run `rename` twice, assert the second is a quiet exit 0

## Also in 0.3.1

- Delete `scripts/claude-gitflow-regulator.sh` — byte-identical 185-line copy
  of `cc-gitflow-regulator.sh`, left over from the 0.3.0 rename. Dead weight in
  the npm tarball and a silent divergence risk.
- Fix `homepage` / `repository` / README install command. `gh repo view
  jagp/cc-gitflow-regulator` currently fails to resolve — the repo does not
  exist and there is no rename redirect, so `/plugin marketplace add
  jagp/cc-gitflow-regulator` in README:48 is broken as published. Resolved by
  renaming the GitHub repo, which also aligns repo, plugin, and npm names.
- Bump all four version references to 0.3.1 — deferred to the release cut,
  after all in-scope work lands.

## Out of scope

- Homebrew formula, `curl | bash` installer, Scoop manifest
- Auto-repair of hook entries the installer did not write
- Migrating existing marketplace users to npm — the channels coexist
