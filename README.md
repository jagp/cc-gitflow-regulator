<p align="center">
  <img src="assets/logo.png" width="240" alt="A brass regulator valve wrapped in a sunburst, sitting at the junction where a dotted side branch rejoins the straight main line of a git pipe-tree carrying water drops">
</p>

# cc-gitflow-regulator

v1.0.0

Gitflow guardrails for Claude Code — every worktree flows back through the regulator.

Claude Code isolates background and parallel work in git worktrees on internal
`worktree-*` branches. Those branches don't follow gitflow naming, stay checked
out inside the worktree (so Sourcetree/GitKraken/git can't check them out —
`fatal: '<branch>' is already used by worktree at ...`), and nothing tells you
when the work is done. This plugin fixes all three:



- **Gitflow naming** — the moment a worktree is created, its branch is renamed
  to `feature/<name>`.
- **Fork from develop** — fresh worktrees are re-pointed to your gitflow base
  branch (`develop` by default), never whatever you happened to have checked out.
- **Completion alerts** — when new committed work exists, you get a desktop
  notification (Windows toast / macOS Notification Center / Linux
  `notify-send`).
- **Local delivery** — at session end the worktree's HEAD is detached, which
  releases the `feature/*` branch so your git client can check it out or merge
  it immediately. The hooks never push anything; only the commands you run
  talk to origin, as described below.
- **Start command** — `/start-feature <name>` performs the Sourcetree-style
  "Start Feature": fast-forward develop from origin, branch `feature/<name>`
  off it, and run the project's test suite as a baseline before you change
  anything. Bootstraps `develop` from main/master if the repo doesn't have one
  yet (with your go-ahead).
- **Finish command** — `/finish-feature` performs the Sourcetree-style
  "Finish Feature" for you: `--no-ff` merge into the branch's base (PR route
  on conflicts), push the base to origin, remove the worktree and delete the
  local branch, then ask before deleting the branch on origin.
- **Release and hotfix commands** — `/start-release` / `/finish-release` and
  `/start-hotfix` / `/finish-hotfix` cut and land releases: version suggested
  from your commits, manifests bumped, changelog drafted and dated, `--no-ff`
  merges into `main` and back, a tag, and (after you agree) the tag pushed
  and a GitHub Release page created. See [Releases and hotfixes](#releases-and-hotfixes).

## Requirements

- git ≥ 2.31
- bash (on Windows: Git Bash, which ships with Git for Windows)
- `jq` optional (a sed fallback is built in)
- a recent Claude Code — the rename hook matches the `EnterWorktree` tool and
  the notify hook uses `async` Stop hooks. Older versions degrade gracefully:
  no rename, and alerts run synchronously.

## Installation

```install
/plugin marketplace add jagp/interface-layer
/plugin install cc-gitflow-regulator@interface-layer
```

## How it works

| Hook   | Event                            | What it does                                                                                                                                                                                                                |
| ------ | -------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| rename | `PostToolUse` on `EnterWorktree` | Renames `worktree-<name>` → `feature/<name>`. If the branch is _fresh_ (a single `branch: Created from ...` reflog entry), hard-resets it onto the base branch first. Worktrees that already carry commits are never reset. |
| notify | `Stop` (async)                   | If the worktree is clean and HEAD moved since the last alert, sends the desktop notification. Deduped by commit SHA — one alert per batch of new work, not per turn.                                        |
| end    | `SessionEnd`                     | Sends any pending alert, then detaches the worktree HEAD (releases the branch) so it is free in your main checkout.                                                                                                         |

Everything is scoped to directories under `.claude/worktrees/` — the hooks
never touch your own branches or checkouts. The script always exits 0; a
guardrail must never break a session.

## Configuration

All optional, via environment variables (e.g. the `"env"` block in
`~/.claude/settings.json`):

| Variable                        | Default                   | Purpose                                                                                                                                          |
| ------------------------------- | ------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------ |
| `CC_GITFLOW_REGULATOR_PREFIX`         | `feature/`                | Branch prefix for renamed worktree branches                                                                                                      |
| `CC_GITFLOW_REGULATOR_BASE`           | auto                      | Base branch to fork from. Auto-detect order: `git config gitflow.branch.develop` (git-flow's own per-repo setting; a repo without `develop` can name `main`), `develop`, `dev`, `origin/develop`, `origin/dev`. If none exist, worktrees keep their default base. |
| `CC_GITFLOW_REGULATOR_FEATURE_MERGE`  | `push`                    | How `/finish-feature` lands a feature on its base: `push` merges here and pushes the base, `local` merges here and pushes nothing, `pr` pushes the branch and opens a GitHub PR instead. |
| `CC_GITFLOW_REGULATOR_RELEASE_MERGE`  | `pr`                      | How `/finish-release` and `/finish-hotfix` land on `main`: same three values. The highest-stakes merge, so it waits for a PR by default. |
| `CC_GITFLOW_REGULATOR_BACK_MERGE`     | `push`                    | How a finished release or hotfix is merged back into `develop` (or the open `release/*`): same three values; its PR goes from `main`. |
| `CC_GITFLOW_REGULATOR_CHANGELOG`      | on                        | Release commands draft, require and date a `CHANGELOG.md` entry. `0` turns that off; release notes then come from the commit list.            |
| `CC_GITFLOW_REGULATOR_GH_RELEASE`     | on                        | Publishing a release also creates its GitHub Release page with `gh`. `0` turns that off.                                                        |

## Starting a branch: `/start-feature`

```
/start-feature <feature name> [--create-base] [--skip-tests]
```

`/new-feature` is an alias.

All git logic lives in `scripts/start-feature.sh` (`plan` is read-only, `start`
acts). In order, it:

1. Slugs the name into `feature/<name>`. The slug rules are the same as
   `/feature-dirty`.
2. Refuses if the branch already exists, locally or on origin.
3. Refuses if tracked files have uncommitted changes. Use `/feature-dirty`
   to carry dirty work onto a new branch instead.
4. Resolves the base branch: `CC_GITFLOW_REGULATOR_BASE`, else
   `develop`/`dev`. A base that exists only on origin is checked out locally.
   If there is no base at all, `--create-base` creates `develop` from
   main/master.
5. Fetches origin and fast-forwards the base only if it is strictly behind.
   A base that is ahead or has diverged is reported and never forced.
6. Creates the branch from the base, switches the current checkout to it,
   and records the base in git config (`gitflow.branch.<branch>.base`, the
   key git-flow uses) so `/finish-feature` merges back into it.
7. Detects the test suite and runs it once as a baseline, so failures that
   were already there aren't mistaken for new ones. Detected runners:
   package.json `test` script (npm/pnpm/yarn/bun), pytest, cargo, go,
   `make test`, and bats.

Nothing is pushed.

## Reviewing and merging Claude's work

When you get the alert, the `feature/<name>` branch is (or will be at session
end) checked out nowhere — open your git client, review it, and merge it into
`develop` like any other feature branch. Delete it after merging as usual.

Or let the plugin do it:

## Finishing a branch: `/finish-feature`

```
/finish-feature [branch] [--keep-branch] [--stash-changes|--discard-changes] [--kill-stalled-session]
```

`/finish-branch` is an alias.

Mimics Sourcetree's Gitflow **Finish Feature** button, deterministically
(all logic lives in `scripts/finish-feature.sh`; the command is a thin
wrapper). It first shows you a read-only *plan* (branch, base, holding
worktree, background job, remote-branch state, whether the merge will be
clean, and what cleanup will do), then:

1. **Checks for leftovers** — if the branch's worktree has uncommitted or
   untracked files (anything in `.claude/` is ignored), it stops *before*
   merging and lists them. Claude asks what they are: commit them to the
   branch and re-run, carry them forward with `--stash-changes` (the stash
   survives the worktree; continue with `/start-feature <name>` then
   `git stash apply <sha>`), or throw them away with `--discard-changes`.
2. **Releases the lock** — unlocks and detaches the `.claude/worktrees/*`
   worktree holding the branch (worktrees you created yourself are never
   touched). Worktrees already on a detached HEAD, the normal state after a
   session ends, are found by their managed-worktree name.
3. **Merges** the branch with `--no-ff` into its base: the one
   `/start-feature` recorded, else `CC_GITFLOW_REGULATOR_BASE`, else
   `develop`/`dev`.
4. **Pushes the base to origin** (plain push, never forced). With no origin
   it says so; `CC_GITFLOW_REGULATOR_FEATURE_MERGE=local` keeps the merge
   local. With it set to `pr`, steps 3 and 4 are replaced by a PR: finish
   pushes the branch, opens a PR into the base and stops, leaving the
   worktree alone; after you merge the PR (with a merge commit), running
   `/finish-feature <branch>` again only cleans up.
   A rejected push is reported and the run ends incomplete.
5. **On conflict**, nothing is merged or pushed to the base. Instead it pushes
   the feature branch and opens a PR into the base. Once the PR is merged,
   run `/finish-feature <branch>` again: it sees the branch is already in the
   base and does the remaining cleanup.
6. **Cleans up** — removes the worktree and deletes the local branch, unless
   `--keep-branch`. The branch is deleted only once a long-lived branch
   (`develop`, `dev`, `main`, `master`, or `CC_GITFLOW_REGULATOR_BASE`) holds
   its work; a feature merged into a `release/*` or `hotfix/*` base is kept
   until that base lands, then a re-run deletes it. If the worktree can't be
   removed, the branch is kept too, so a re-run can find it.
7. **Asks about origin** — after `git fetch --prune`, if the local branch was
   deleted and `origin/<branch>` holds nothing beyond it, Claude asks whether
   to delete it on origin too. On yes, it is deleted only if origin still
   points at the commit that was checked (`--force-with-lease`), so a push
   someone made in the meantime is never lost. A branch with someone else's
   commits on it is left alone.

**When a background session holds the worktree.** On Windows a folder can't
be deleted while any process is running inside it. If removal fails and a
Claude background job's record matches the worktree, finish looks at the
job's state: a `done` or `failed` job is stopped (with its child processes)
and removal is retried; a `blocked` job may be waiting on you, so Claude asks
first and re-runs with `--kill-stalled-session` on yes; a job in any other
state is never stopped. Ordinary terminal sessions have no job record, so
finish names the problem and leaves closing them to you.

A branch that exists only on origin (a background session pushed it without
ever creating a local branch) is adopted local-first: finish creates the
local branch from `origin/<branch>` before merging.

**What reaches origin, exactly:** the base branch after a clean merge (unless
switched off), the feature branch on a conflict (for its PR), and a delete of
`origin/<branch>` only after you say yes. Never a force push.

Guardrails: it refuses to run if your main checkout has uncommitted tracked
changes or a merge in progress, or if the branch is held by a worktree the
plugin doesn't manage. It never stops the session it is running in, or any
job when several match the worktree, and it refuses to remove a detached
worktree whose HEAD holds commits not yet in the base or the branch.

## Releases and hotfixes

`/start-release` (alias `/new-release`) and `/finish-release` cut and land a
release; `/start-hotfix` (alias `/new-hotfix`) and `/finish-hotfix` do the
same for an urgent fix to what is already released. Same rules as the
feature commands: a read-only plan first, nothing pushed without saying so,
and the tag pushed only after you agree.

**Starting.** `/start-release` without a version suggests one from the
[Conventional Commits](https://www.conventionalcommits.org/) since the last
`vX.Y.Z` tag, and lists the commits behind it:

| Commits since the last release | From 1.0 on | Below 1.0 |
| ------------------------------ | ----------- | --------- |
| a breaking change (`feat!:`, or a `BREAKING CHANGE:` footer) | major | minor |
| a `feat:`                       | minor       | minor     |
| only `fix:`, `docs:`, ...       | patch       | patch     |

It never suggests 1.0.0: leaving 0.x is your call, made by naming the version
(`/start-release 1.0.0`). It refuses while another release is open or the tag
exists. Then it creates `release/<version>` from `develop`, bumps the version
in whichever of `.claude-plugin/plugin.json`, `.claude-plugin/marketplace.json`
and `package.json` exist, drafts a `CHANGELOG.md` entry from the commits for you to
edit, commits that, and runs the tests as a baseline. A hotfix branches from
`main` instead, always takes the next patch, and may start while a release
is open.

**Finishing.** `/finish-release` refuses on uncommitted changes, failing
tests, a missing changelog entry, or a manifest at another version. It warns
(without blocking) about files still naming the previous version, changed
files no test change mentions, and commits that are on `main` but not
`develop`. Then it dates the entry and lands the release on `main`: by
default through a PR (see Merge modes below), or with a local `--no-ff`
merge. After that it tags `v<version>`, merges the tag back into `develop`,
pushes, deletes the release branch, and cleans up feature branches that
were waiting for it. A hotfix is merged back into an open release branch if there is one,
so the release can't ship without the fix.

A conflict stops the run and changes nothing half-way. Resolve it (for a
conflict with `main`, the command offers to merge `main` into the release
branch so you can resolve it there) and run the command again; every step
that already happened is skipped.

**Merge modes.** Each of the merges a release makes has its own setting,
taking `pr`, `push` or `local` (see the table above). By default the merge
into `main` goes through a PR and the merge back into `develop` is done here
and pushed. A `pr` stage pushes, opens the PR (or finds the open one) and
stops; merge the PR **with a merge commit**, then run the command again. It
fetches the merge and carries on: tag, merge back, push, clean up. A squash
or rebase merge copies the commits instead of merging them, so git can't
see the branch landed; finish refuses that case rather than tagging a guess.
A `pr` stage without `gh` (installed and logged in) or an origin remote
refuses instead of falling back to a local merge.

**Publishing.** The command then asks before pushing the tag. On yes it
pushes it, creates the GitHub Release page with the changelog entry as notes
(`gh` needed; without it you get the exact command to run), and prints the
commands to undo the release. If the repo has a `RELEASING.md` with a
`## Notify` list, those places are printed with an announcement to paste.
Nothing is sent anywhere.

Per-repo switches (git config) mirror the variables above:
`gitflow.release.changelog false`, `gitflow.release.githubRelease false`,
`gitflow.feature.merge`, `gitflow.release.merge`,
`gitflow.release.backMerge` (each `pr`, `push` or `local`).

**Tests.** The commands find a project's tests on their own: `npm`/`pnpm`/
`yarn`/`bun` `test` scripts, pytest, `cargo test`, `go test`, a Makefile
`test` target, `*.bats` files, and plain `*.sh` suites in `tests/` or
`test/` (helpers other suites `source` are skipped). For anything else, set
`git config gitflow.testCommand "<command>"`. With no tests found, the
commands warn and carry on.

## Tests

```
bash scripts/run-tests.sh     # all of them
bash tests/hooks.sh
bash tests/common.sh
bash tests/start-feature.sh
bash tests/finish-feature.sh
bash tests/start-release.sh
bash tests/finish-release.sh
bash tests/stalled-jobs.sh    # Windows only; skips elsewhere
```

Each builds a throwaway origin and clone in a temp folder, prints one
PASS/FAIL line per case, and exits 1 if any case fails.

## License

MIT — see [LICENSE](LICENSE).
