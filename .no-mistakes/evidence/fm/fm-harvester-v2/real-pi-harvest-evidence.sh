#!/usr/bin/env bash
# End-to-end evidence for the two harvester defects, run against the REAL,
# unmodified ~/.pi/agent/sessions tree on this machine. Nothing under ~/.pi is
# written; it is only read.
set -eu
WT_REPO=${WT_REPO:?set WT_REPO to the worktree checkout}
NEW_BIN="$WT_REPO/bin"
PI_DIR="$HOME/.pi/agent/sessions"
TASK_CWD=/Users/npayette/.treehouse/firstmate-e5afef/3/firstmate
START=1788150000        # task spawn epoch, as recorded in meta spawn_gen
END=1788186000          # last status append

SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-usage-evidence.XXXXXX")
trap 'rm -rf "$SCRATCH"' EXIT

# The pre-fix harvester, taken verbatim from the commit before this change.
OLD_BIN="$SCRATCH/oldbin"
mkdir -p "$OLD_BIN"
cp "$NEW_BIN"/*.sh "$OLD_BIN"/
git -C "$WT_REPO" show 12f6613:bin/fm-usage-harvest.sh > "$OLD_BIN/fm-usage-harvest.sh"
chmod +x "$OLD_BIN/fm-usage-harvest.sh"

stamp() { date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$1" +%Y%m%d%H%M.%S; }

# make_home <id> <keep-status> : a firstmate home holding one finished pi task
# whose worktree is a real Pi session cwd. The meta's mtime is pushed to the
# END of the task, exactly as a late PR registration write does.
make_home() {
  local id=$1
  local keep_status=$2
  local home="$SCRATCH/home-$id"
  mkdir -p "$home/state" "$home/data"
  cat > "$home/state/$id.meta" <<META
window=firstmate:fm-$id
endpoint_task_id=$id
worktree=$TASK_CWD
harness=pi
kind=ship
mode=no-mistakes
model=zai/glm-4.6
effort=default
spawn_gen=s$START.41234.a1b2c3
META
  printf 'working: started\nworking: halfway\nworking: wrapping up\ndone: finished\n' \
    > "$home/state/$id.status"
  touch -t "$(stamp "$END")" "$home/state/$id.status"
  [ "$keep_status" = keep ] || rm -f "$home/state/$id.status"
  # The late metadata write (PR registration) lands at the end of the task.
  touch -t "$(stamp "$END")" "$home/state/$id.meta"
  printf '%s' "$home"
}

run_harvest() {  # <bin> <home> <id>
  FM_STATE_OVERRIDE="$2/state" FM_DATA_OVERRIDE="$2/data" \
  FM_USAGE_PI_DIR="$PI_DIR" \
    "$1/fm-usage-harvest.sh" "$3" || echo "(harvest exited $?)"
  cat "$2/data/usage-ledger.jsonl" 2>/dev/null || echo "(no ledger row)"
}

echo "=================================================================="
echo " Fixture: one finished harness=pi task"
echo "   worktree      : $TASK_CWD"
echo "   spawn_gen     : s$START.41234.a1b2c3   ($(date -r $START -u +%FT%TZ))"
echo "   last status   : $END                   ($(date -r $END -u +%FT%TZ))"
echo "   true wall     : $((END - START))s over 3 'working:' turns"
echo "   Pi log tree   : $PI_DIR   (real, unmodified, read-only)"
echo "   meta mtime was rewritten to the END of the task (PR registration)"
echo "=================================================================="
echo
echo "### BEFORE (harvester at 12f6613, teardown had already removed the status log)"
run_harvest "$OLD_BIN" "$(make_home before-a nostatus)" before-a
echo
echo "### BEFORE (harvester at 12f6613, status log kept)"
run_harvest "$OLD_BIN" "$(make_home before-b keep)" before-b
echo
echo "### AFTER (this change, status log kept - the teardown order it now runs in)"
run_harvest "$NEW_BIN" "$(make_home after-a keep)" after-a
echo
echo "### AFTER (this change, status log removed - wall + tokens still survive on spawn_gen)"
run_harvest "$NEW_BIN" "$(make_home after-b nostatus)" after-b
echo
echo "=================================================================="
echo " Independent recomputation, straight jq over the same real Pi logs"
echo " in [$START,$END] whose session record's cwd is the task worktree"
echo "=================================================================="
for f in $(find "$PI_DIR" -type f -name '*.jsonl'); do
  m=$(stat -f %m "$f" 2>/dev/null || stat -c %Y "$f")
  [ "$m" -ge "$START" ] && [ "$m" -le "$END" ] || continue
  jq -rs --arg wt "$TASK_CWD" '
    if (map(select(.type=="session"))|.[0].cwd) == $wt then
      [.[] | select(.type=="message" and .message.role=="assistant" and .message.usage != null)]
      | "\($wt)\tinput=\(map(.message.usage.input//0)|add) cached=\(map((.message.usage.cacheRead//0)+(.message.usage.cacheWrite//0))|add) output=\(map(.message.usage.output//0)|add) reasoning=\(map(.message.usage.reasoning//0)|add) records=\(length)"
    else empty end' "$f"
done

echo
echo "=================================================================="
echo " Arithmetic check: harvested row == sum of the independent jq rows"
echo "=================================================================="
python3 - "$SCRATCH/home-after-a/data/usage-ledger.jsonl" <<'PYCHK'
import json, sys
row = json.loads(open(sys.argv[1]).read().strip())
expect = {"input_tokens": 677858 + 86709, "cached_input_tokens": 11216256 + 499200,
          "output_tokens": 85861 + 23602, "reasoning_tokens": 59337 + 12400}
for k, v in expect.items():
    print(f"{k:22} harvested={row[k]:>10}  independent={v:>10}  {'MATCH' if row[k]==v else 'MISMATCH'}")
PYCHK

echo
echo "=================================================================="
echo " End-user surface: bin/fm-usage-report.sh over the harvested ledger"
echo "=================================================================="
FM_DATA_OVERRIDE="$SCRATCH/home-after-a/data" "$NEW_BIN/fm-usage-report.sh"
