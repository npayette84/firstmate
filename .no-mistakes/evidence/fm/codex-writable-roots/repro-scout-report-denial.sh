#!/usr/bin/env bash
# Manual end-to-end reproduction of the defect this change fixes, run against the
# real codex binary: a codex SCOUT in a linked task worktree is asked to deliver
# its report to $FM_HOME/data/<id>/report.md and append its status line.
#
# BEFORE: the launch codex gets without the grant (-s workspace-write alone).
# AFTER:  the same turn with the exact --add-dir roots bin/fm-spawn.sh composes.
#
# The lab lives under the repo worktree, NOT $TMPDIR, because codex's
# workspace-write sandbox always grants /tmp and $TMPDIR: a lab there would make
# the BEFORE half silently pass. The lab is removed by the caller.
set -u

ROOT=${1:?usage: repro-scout-report-denial.sh <fm root> <lab>}
LAB=${2:?usage: repro-scout-report-denial.sh <fm root> <lab>}
mkdir -p "$LAB"
LAB=$(cd "$LAB" && pwd -P)

HOME_DIR="$LAB/fmhome"
PROJECT="$LAB/project"
WT="$LAB/wt"
ID=codex-repro-scout
mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/$ID" "$HOME_DIR/config" "$HOME_DIR/projects"
printf 'Scout the repo and report.\n' > "$HOME_DIR/data/$ID/brief.md"
printf '%s\n' "$$" > "$HOME_DIR/state/.lock"
touch "$HOME_DIR/state/.last-watcher-beat"

git init -q -b main "$PROJECT"
( cd "$PROJECT" && printf 'a\n' > a.txt && git add a.txt \
  && git -c user.email=t@t -c user.name=t commit -qm init ) >/dev/null
git clone --quiet --bare "$PROJECT" "$PROJECT.origin.git"
git -C "$PROJECT" remote add origin "file://$(cd "$PROJECT.origin.git" && pwd)"
git -C "$PROJECT" worktree add -q -b "fm/$ID" "$WT"

FAKEBIN="$LAB/fakebin"
mkdir -p "$FAKEBIN"
cat > "$FAKEBIN/tmux" <<'SH'
#!/usr/bin/env bash
set -u
case "$*" in
  *"#{pane_current_path}"*) printf '%s\n' "${FM_FAKE_PANE_PATH:-}"; exit 0 ;;
esac
case "${1:-}" in
  display-message) printf 'firstmate\n'; exit 0 ;;
  send-keys)
    if [ -n "${FM_FAKE_LAUNCH_LOG:-}" ]; then
      shift
      skip_next=
      for a in "$@"; do
        if [ -n "$skip_next" ]; then skip_next=; continue; fi
        case "$a" in
          -t) skip_next=1; continue ;;
          -l|Enter|C-m) continue ;;
          *) printf '%s\n' "$a" >> "$FM_FAKE_LAUNCH_LOG" ;;
        esac
      done
    fi
    exit 0
    ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/tmux"
printf '#!/bin/sh\nexit 0\n' > "$FAKEBIN/treehouse"
chmod +x "$FAKEBIN/treehouse"

LAUNCH_LOG="$LAB/launch.log"
: > "$LAUNCH_LOG"
env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_PROJECTS_OVERRIDE="$HOME_DIR/projects" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_GATE_REFUSE_BYPASS=1 FM_SPAWN_NO_GUARD=1 FM_FAKE_PANE_PATH="$WT" TMUX="fake,1,0" \
  FM_FAKE_LAUNCH_LOG="$LAUNCH_LOG" PATH="$FAKEBIN:$PATH" \
  "$ROOT/bin/fm-spawn.sh" "$ID" "$PROJECT" codex --scout > "$LAB/spawn.log" 2>&1 \
  || { echo "spawn failed: $(tail -5 "$LAB/spawn.log")"; exit 1; }

ROOTS=$(grep -F -- '--add-dir' "$LAUNCH_LOG" | tail -1 \
  | tr ' ' '\n' | grep -A1 -F -- '--add-dir' | grep -v -F -- '--add-dir' \
  | grep -v '^--$' | sed "s/^'//; s/'\$//")
CLI_FLAGS=()
while IFS= read -r r; do
  [ -n "$r" ] || continue
  CLI_FLAGS+=(--add-dir "$r")
done <<EOF
$ROOTS
EOF

REPORT="$HOME_DIR/data/$ID/report.md"
STATUS="$HOME_DIR/state/$ID.status"
PROMPT="You are a firstmate scout finishing your brief. Run exactly these two shell commands, each separately, then stop: (1) printf 'scout report: the repo builds\n' > $REPORT (2) echo 'done: report delivered' >> $STATUS . Report for each whether it succeeded or was denied. Do nothing else and do not retry a denied command."

echo "== writable roots fm-spawn composed for this scout =="
printf '%s\n' "$ROOTS" | sed "s#$LAB#<lab>#g; s/^/  /"

echo
echo "== BEFORE: codex exec -s workspace-write (no grant) =="
( cd "$WT" && codex exec -s workspace-write --skip-git-repo-check \
    -c 'model_reasoning_effort="low"' "$PROMPT" < /dev/null ) \
  > "$LAB/before.log" 2>&1
sed "s#$LAB#<lab>#g" "$LAB/before.log" | grep -v 'codex_skills_extension'
echo "-- delivered artifacts after BEFORE turn --"
[ -e "$REPORT" ] && echo "  report.md EXISTS" || echo "  report.md ABSENT (scout could not deliver its report)"
[ -s "$STATUS" ] && echo "  status line APPENDED" || echo "  status EMPTY (supervision sees nothing)"

echo
echo "== AFTER: same turn, with the --add-dir roots fm-spawn composed =="
( cd "$WT" && codex exec -s workspace-write "${CLI_FLAGS[@]}" --skip-git-repo-check \
    -c 'model_reasoning_effort="low"' "$PROMPT" < /dev/null ) \
  > "$LAB/after.log" 2>&1
sed "s#$LAB#<lab>#g" "$LAB/after.log" | grep -v 'codex_skills_extension'
echo "-- delivered artifacts after AFTER turn --"
[ -e "$REPORT" ] && echo "  report.md EXISTS: $(cat "$REPORT")" || echo "  report.md ABSENT"
[ -s "$STATUS" ] && echo "  status line: $(cat "$STATUS")" || echo "  status EMPTY"
echo "-- the home itself stays denied --"
[ -e "$HOME_DIR/config/leaked.txt" ] && echo "  config/ WRITABLE (leak)" || echo "  config/ still denied"
