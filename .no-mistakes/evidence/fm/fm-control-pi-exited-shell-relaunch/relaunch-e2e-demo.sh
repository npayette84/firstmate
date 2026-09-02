#!/usr/bin/env bash
# Manual end-to-end evidence: bin/fm-control.sh <task> relaunch over a Herdr
# pane whose Pi worker already exited to a zsh shell, with a stale agent
# registration left behind. Runs entirely inside a private, throwaway Herdr lab
# session (bin/fm-herdr-lab.sh), never the captain's default session.
#
# usage: relaunch-demo.sh <repo-root> <label>
set -u
ROOT=$(cd "$1" && pwd); LABEL=$2
export FM_GATE_REFUSE_BYPASS=1

say() { printf '\n=== %s ===\n' "$*"; }

unset HERDR_ENV HERDR_PANE_ID HERDR_TAB_ID HERDR_WORKSPACE_ID HERDR_SOCKET_PATH HERDR_SESSION
SESSION="fm-lab-relaunch-demo-$LABEL-$$"
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-relaunch-demo.XXXXXX"); SCRATCH=$(cd "$SCRATCH" && pwd)
cleanup() { herdr_safe_stop_and_delete "$SESSION" >/dev/null 2>&1 || true; rm -rf "$SCRATCH"; }
trap cleanup EXIT

# shellcheck source=/dev/null
. "$ROOT/tests/herdr-test-safety.sh"
export HERDR_SESSION="$SESSION"
fm_herdr_lab_prepare "$SESSION" >/dev/null || { echo "could not prepare lab session"; exit 1; }

# --- a task with real work to preserve --------------------------------------
HOME_DIR="$SCRATCH/home"; mkdir -p "$HOME_DIR/state" "$HOME_DIR/data/demo"
printf '# Ship the PR lifecycle follow-through monitor\n' > "$HOME_DIR/data/demo/brief.md"
PROJ="$SCRATCH/proj"; WT="$SCRATCH/wt"; mkdir -p "$PROJ"
git -C "$PROJ" init -q
printf '# proj\n' > "$PROJ/README.md"
git -C "$PROJ" add README.md
git -C "$PROJ" -c user.name='Demo' -c user.email='demo@example.invalid' commit -qm initial
git -C "$PROJ" worktree add --quiet -b task-demo "$WT"
printf 'work the previous worker had not committed\n' > "$WT/scratch.txt"
printf 'committed on the preserved branch\n' > "$WT/landed.txt"
git -C "$WT" add landed.txt
git -C "$WT" -c user.name='Demo' -c user.email='demo@example.invalid' commit -qm 'prior worker commit'
HEAD_BEFORE=$(git -C "$WT" rev-parse HEAD)

# --- a fake pi executable: no tokens, but a REAL foreground process ----------
mkdir -p "$SCRATCH/fakebin"
cat > "$SCRATCH/fakebin/pi" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in --help|--version) echo "fake pi (evidence shim)"; exit 0 ;; esac
exec sleep 900
SH
chmod +x "$SCRATCH/fakebin/pi"
export PATH="$SCRATCH/fakebin:$PATH"

# --- the endpoint: a pane whose worker exited to its shell -------------------
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || { echo "fm_backend_source herdr failed"; exit 1; }
CONTAINER_RAW=$(fm_backend_herdr_container_ensure "$WT") || exit 1
CONTAINER=${CONTAINER_RAW%%$'\t'*}; SEEDED=${CONTAINER_RAW#*$'\t'}
WORKSPACE_ID=${CONTAINER#*:}
IDS=$(fm_backend_herdr_create_task "$CONTAINER" fm-demo "$WT" "$SEEDED") || exit 1
read -r TAB_ID PANE_ID <<EOF
$IDS
EOF
{
  echo "window=$SESSION:$PANE_ID"; echo "endpoint_task_id=demo"; echo "worktree=$WT"
  echo "project=$PROJ"; echo "harness=pi"; echo "kind=ship"; echo "mode=no-mistakes"
  echo "yolo=off"; echo "model=default"; echo "effort=default"; echo "backend=herdr"
  echo "herdr_session=$SESSION"; echo "herdr_workspace_id=$WORKSPACE_ID"
  echo "herdr_tab_id=$TAB_ID"; echo "herdr_pane_id=$PANE_ID"
} > "$HOME_DIR/state/demo.meta"

# The Pi worker exited cleanly; nothing withdrew its registration.
herdr pane report-agent "$PANE_ID" --source fm-pi-ext --agent pi-worker \
  --state idle --session "$SESSION" >/dev/null 2>&1 \
  || { echo "could not leave a stale registration"; exit 1; }

say "the reported disagreement (herdr $(herdr --version 2>/dev/null | head -1))"
echo "\$ herdr agent get $PANE_ID   ->  agent_status: $(herdr agent get "$PANE_ID" --session "$SESSION" 2>/dev/null | jq -r '.result.agent.agent_status // "none"')"
echo "\$ herdr pane process-info    ->  foreground: $(herdr pane process-info --pane "$PANE_ID" --session "$SESSION" 2>/dev/null | jq -c '[.result.process_info.foreground_processes[]? | {name, argv0}]')"
echo "firstmate's own classifier    ->  fm_backend_agent_state herdr = $(fm_backend_agent_state herdr "$SESSION:$PANE_ID")"

say "operator runs the supported control verb"
echo "\$ bin/fm-control.sh demo relaunch --note 'prior Pi worker exited to a shell after the PR went green'"
OUT=$(env FM_HOME="$HOME_DIR" HERDR_SESSION="$SESSION" FM_CONTROL_POLL=0.2 \
  FM_CONTROL_EXIT_WAIT=3 FM_CONTROL_LAUNCH_WAIT=25 \
  "$ROOT/bin/fm-control.sh" demo relaunch \
  --note 'prior Pi worker exited to a shell after the PR went green' 2>&1)
RC=$?
printf '%s\n' "$OUT"
echo "exit status: $RC"

say "what reached the pane"
PANE_TEXT=$(herdr pane read "$PANE_ID" --session "$SESSION" --source recent --lines 200 2>/dev/null)
if printf '%s' "$PANE_TEXT" | grep -q '/quit'; then
  echo "pane received /quit: YES  <- the harness exit command was typed at a zsh prompt"
else
  echo "pane received /quit: no"
fi
echo "pane foreground now: $(herdr pane process-info --pane "$PANE_ID" --session "$SESSION" 2>/dev/null | jq -c '[.result.process_info.foreground_processes[]? | {name, argv0}]')"
echo "endpoint still exists: $(herdr pane get "$PANE_ID" --session "$SESSION" >/dev/null 2>&1 && echo yes || echo NO)"

say "preserved work"
echo "branch:            $(git -C "$WT" rev-parse --abbrev-ref HEAD)"
echo "HEAD unchanged:    $([ "$(git -C "$WT" rev-parse HEAD)" = "$HEAD_BEFORE" ] && echo yes || echo NO)"
echo "uncommitted file:  $(cat "$WT/scratch.txt" 2>/dev/null)"
echo "committed file:    $(cat "$WT/landed.txt" 2>/dev/null)"
echo "task record harness=$(grep '^harness=' "$HOME_DIR/state/demo.meta" | cut -d= -f2)"
echo "journal exit_result: $(grep -h '^exit_result=' "$HOME_DIR/state/demo.control-relaunch" 2>/dev/null | tail -1)"
echo "progress note in the replacement's instructions: $(grep -q 'prior Pi worker exited' "$HOME_DIR/data/demo/brief.md" && echo yes || echo no)"
exit "$RC"
