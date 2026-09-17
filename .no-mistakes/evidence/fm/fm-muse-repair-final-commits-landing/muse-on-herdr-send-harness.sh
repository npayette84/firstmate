#!/usr/bin/env bash
# End-user reproduction of the Muse-on-Herdr send false negative, driven
# through the REAL bin/fm-send.sh CLI against a stateful fake `herdr` that
# renders Muse Code 1.3.0's composer exactly as a live pane does:
#
#   ── Voice input (⌥ + v to start) ─────────…─────
#   ❯ <typed text, cleared once Muse accepts Enter>
#   ───────────────────────────────────────────────
#     echo · /tmp/muse-workspace · YOLO
#
# The fake pane is honest about delivery: `pane send-text` types the steer into
# the composer, `pane send-keys enter` submits it (the composer clears and the
# footer keeps rendering), and `agent get` reports the `idle` native status
# herdr 0.9.0 reports for a Muse pane. Nothing about the pane changes between
# the two runs below - only which revision of bin/fm-composer-lib.sh is on the
# classifier boundary.
#
# With SWALLOW=1 the fake Muse pane keeps the typed text in its composer after
# Enter (a swallowed submit), which is the duplicate-send hazard the loud
# refusal exists for: the repair must still refuse that pane.
#
# Usage: muse-on-herdr-send-harness.sh <repo-root> <label> <outdir> [swallow]
set -u
ROOT=$1
LABEL=$2
OUT=$3
SWALLOW=${4:-0}
mkdir -p "$OUT"
WORK="$OUT/work"
rm -rf "$WORK"
mkdir -p "$WORK/fakebin" "$WORK/home/state"

cat > "$WORK/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
# Stateful fake herdr pane running Muse Code 1.3.0.
set -u
STATE_DIR="${FAKE_HERDR_STATE:?}"
LOG="${FAKE_HERDR_LOG:?}"
mkdir -p "$STATE_DIR"
printf '%s\n' "herdr $*" >> "$LOG"

composed=$(cat "$STATE_DIR/composer" 2>/dev/null || printf '')

render() {  # renders the pane as herdr would, with the composer holding $composed
  printf '  Muse Code 1.3.0\r\n'
  printf '\r\n'
  printf '\xe2\x94\x80\xe2\x94\x80 Voice input (\xe2\x8c\xa5 + v to start) \xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\r\n'
  printf '\033[38;2;90;160;255m\xe2\x9d\xaf\033[0m %s\r\n' "$composed"
  printf '\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\xe2\x94\x80\r\n'
  printf '  echo \xc2\xb7 /tmp/muse-workspace \xc2\xb7 YOLO\r\n'
}

case "${1:-} ${2:-}" in
  "status --json")
    printf '{"client":{"version":"0.9.0","protocol":18},"server":{"running":true}}\n' ;;
  "pane get")
    printf '{"result":{"pane":{"pane_id":"%s","foreground_cwd":"/tmp/muse-workspace"}}}\n' "${3:-}" ;;
  "agent get")
    # herdr 0.9.0 registers the Muse pane's agent and reports it idle across a
    # landed steer (measured 2026-09-17).
    printf '{"result":{"agent":{"agent":"muse","agent_status":"idle"}}}\n' ;;
  "pane send-text")
    printf '%s' "${4:-}" > "$STATE_DIR/composer" ;;
  "pane send-keys")
    if [ "${4:-}" = enter ]; then
      if [ "${FAKE_MUSE_SWALLOWS_ENTER:-0}" = 1 ]; then
        # Enter was swallowed: the composer still holds the whole steer.
        :
      else
        # Muse accepts the message: the composer clears and the turn starts.
        printf '' > "$STATE_DIR/composer"
      fi
      printf '%s\n' "${4:-}" >> "$STATE_DIR/submitted"
    fi ;;
  "pane read")
    render ;;
  "terminal title")
    printf '{"result":{"reason":"no_foreground_client"}}\n' ;;
esac
exit 0
SH
chmod +x "$WORK/fakebin/herdr"

cat > "$WORK/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$WORK/fakebin/sleep"

# The steer target: a real Muse crewmate pane on the herdr backend.
cat > "$WORK/home/state/muse-lane.meta" <<META
window=default:w1:p2
backend=herdr
herdr_session=default
herdr_pane_id=w1:p2
harness=muse
kind=ship
META

export FAKE_HERDR_STATE="$WORK/herdr-state"
export FAKE_HERDR_LOG="$WORK/herdr-calls.log"
: > "$FAKE_HERDR_LOG"
mkdir -p "$FAKE_HERDR_STATE"

set +e
PATH="$WORK/fakebin:$PATH" FM_HOME="$WORK/home" FM_ROOT_OVERRIDE="$WORK/home" \
  FM_GATE_REFUSE_BYPASS=1 FM_SEND_SETTLE=0 FAKE_MUSE_SWALLOWS_ENTER="$SWALLOW" \
  "$ROOT/bin/fm-send.sh" default:w1:p2 'reply with the token FM-MUSE-9c1f' \
  >"$OUT/$LABEL.stdout" 2>"$OUT/$LABEL.stderr"
rc=$?
set -e

enters=$(grep -c 'pane send-keys w1:p2 enter' "$FAKE_HERDR_LOG" || true)
typed=$(grep -c 'pane send-text w1:p2' "$FAKE_HERDR_LOG" || true)
cp "$FAKE_HERDR_LOG" "$OUT/$LABEL.herdr-calls.log"

{
  printf '$ fm-send.sh default:w1:p2 "reply with the token FM-MUSE-9c1f"   # %s\n' "$LABEL"
  sed 's/^/  /' "$OUT/$LABEL.stderr"
  sed 's/^/  /' "$OUT/$LABEL.stdout"
  printf '  exit status: %s\n' "$rc"
  printf '  herdr calls: pane send-text x%s, pane send-keys enter x%s\n' "$typed" "$enters"
  printf '  pane composer after the send: %s\n' \
    "$( [ -s "$FAKE_HERDR_STATE/composer" ] && printf 'still holds "%s"' "$(cat "$FAKE_HERDR_STATE/composer")" || printf 'cleared (Muse accepted the message)' )"
} > "$OUT/$LABEL.transcript.txt"

cat "$OUT/$LABEL.transcript.txt"
exit 0
