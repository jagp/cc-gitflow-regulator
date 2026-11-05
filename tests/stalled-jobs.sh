#!/usr/bin/env bash
# Stalled background job tests for scripts/finish-feature.sh (Windows only:
# they need a real folder lock). Skips with exit 0 where powershell.exe is
# missing. Run: bash tests/stalled-jobs.sh
#
# A "session" here is a hidden PowerShell parked inside the worktree, which
# holds the folder the way a real session's shells do. Its command line
# carries a fake session id, and a matching job record goes in the test jobs
# folder. The id is built at runtime so no test shell's own command line
# contains it (finish would otherwise match the shell running it).
source "$(dirname "$0")/lib.sh"
command -v powershell.exe >/dev/null 2>&1 || { echo "SKIP  stalled-job tests need powershell.exe (Windows)"; exit 0; }
W=.claude/worktrees
gone() { ! git show-ref -q --verify "refs/heads/$1"; }

# hold <worktree> <id>: park a hidden process inside the folder, then wait
# (up to 15s) until Windows lists it, rather than guessing a fixed delay
hold() {
  SESSION="$2" FOLDER="$(cd "$1" && pwd -W)" powershell.exe -NoProfile -Command '
    Start-Process powershell -WindowStyle Hidden -WorkingDirectory $env:FOLDER -ArgumentList "-NoProfile","-Command","Start-Sleep 120 # $env:SESSION"
    $deadline = (Get-Date).AddSeconds(15)
    while ((Get-Date) -lt $deadline -and -not (Get-CimInstance Win32_Process |
           Where-Object { $_.Name -eq "powershell.exe" -and $_.CommandLine -match "Start-Sleep 120 # $env:SESSION" })) {
      Start-Sleep -Milliseconds 200
    }'
}
# job <id> <worktree> <session-id> <state>: write a job record for it
job() {
  mkdir -p "$SCRATCH/jobs/$1"
  local folder; folder="$(cd "$2" && pwd -W | sed 's|/|\\\\\\\\|g')"
  printf '{"state": "%s", "sessionId": "%s", "worktreePath": "%s"}\n' "$4" "$3" "$folder" > "$SCRATCH/jobs/$1/state.json"
}
# release <id>: stop anything left holding a folder after a case
release() {
  SESSION="$1" powershell.exe -NoProfile -Command \
    'Get-CimInstance Win32_Process | Where-Object { $_.CommandLine -match $env:SESSION } | ForEach-Object { Stop-Process -Id $_.ProcessId -Force }' >/dev/null 2>&1
  sleep 1
}

run_id="t$(date +%s)"

fresh; wt a 2>/dev/null; job j1 $W/a "$run_id-done" done; hold $W/a "$run_id-done"
out="$(fin finish feature/a 2>&1)"
check "done job: stopped, worktree and branch removed" \
  'echo "$out" | grep -q "stopped background job" && [ ! -e $W/a ] && gone feature/a && [ ! -e "$SCRATCH/jobs/j1" ]'
release "$run_id-done"

fresh; wt b 2>/dev/null; job j1 $W/b "$run_id-blocked" blocked; hold $W/b "$run_id-blocked"
out="$(fin finish feature/b 2>&1)"
check "blocked job: asks, keeps branch for the re-run" \
  'echo "$out" | grep -q "^ask: kill-stalled j1" && ! gone feature/b && echo "$out" | grep -q exit=4'
fin finish feature/b --kill-stalled-session >/dev/null 2>&1
check "blocked job: re-run with the flag finds the orphan folder and cleans up" '[ ! -e $W/b ] && gone feature/b'
release "$run_id-blocked"

fresh; wt c 2>/dev/null; job j1 $W/c "$run_id-running" running; hold $W/c "$run_id-running"
out="$(fin finish feature/c 2>&1)"
check "running job: never stopped" 'echo "$out" | grep -q "not stopped" && [ -e "$SCRATCH/jobs/j1" ] && ! gone feature/c'
release "$run_id-running"

# finish runs under a parent shell whose command line carries the id (like a
# session resumed from the job); the parent must survive, the holder must not.
fresh; wt d 2>/dev/null; job j1 $W/d "$run_id-self" done; hold $W/d "$run_id-self"
out="$(bash -c "bash '$REPO/scripts/finish-feature.sh' finish feature/d; echo PARENT-SURVIVED # $run_id-self" 2>&1)"
check "never stops the session running finish" 'echo "$out" | grep -q PARENT-SURVIVED && [ ! -e $W/d ]'
release "$run_id-self"

echo "$failures failure(s)"
[ "$failures" = 0 ]
