#!/usr/bin/env bash
# Live Muse-on-Herdr evidence: launch a REAL Muse Code on --provider echo in an
# isolated Herdr lab (no credential, no model), then read its real composer
# through the shared classifier at BOTH revisions and steer it once.
#
# This is the Muse leg of tests/fm-herdr-submit-confirm-live-e2e.test.sh minus
# the credentialed Claude leg: the same lab helper, the same launch shape, the
# same readiness gate, the same adapter entry point.
#
# Usage: muse-on-herdr-live-evidence.sh <fixed-root> <base-root> <outdir>
set -u
ROOT=$1
BASE_ROOT=$2
OUT=$3
mkdir -p "$OUT"

LAB="$ROOT/bin/fm-herdr-lab.sh"
ORIGINAL_PATH=$PATH
SESSION=$("$LAB" name muse-live-ev)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-muse-live-ev.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

cleanup() {
  local rc=$?
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$LAB" teardown "$SESSION" >>"$OUT/teardown.log" 2>&1 || rc=1
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

shell_quote() { printf "'"; printf '%s' "$1" | sed "s/'/'\\\\''/g"; printf "'"; }

cat > "$FAKEBIN/herdr" <<EOF
#!/usr/bin/env bash
set -u
args=("\$@")
n=\${#args[@]}
if [ "\$n" -ge 2 ] && [ "\${args[\$((n-2))]}" = --session ]; then
  [ "\${args[\$((n-1))]}" = "$SESSION" ] || { echo "wrapper refused foreign session" >&2; exit 97; }
  args=("\${args[@]:0:\$((n-2))}")
else
  echo "wrapper requires trailing --session $SESSION" >&2
  exit 98
fi
exec env PATH="$ORIGINAL_PATH" "$LAB" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB" provision "$SESSION" || { echo "could not provision the isolated Herdr lab"; exit 1; }
export PATH="$FAKEBIN:$ORIGINAL_PATH"
lab() { env PATH="$ORIGINAL_PATH" "$LAB" run "$SESSION" "$@"; }

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

MUSE_BIN=$(PATH="$ORIGINAL_PATH" command -v muse)
MUSE_CONFIG_HOME="$TMP_ROOT/muse-config"
MUSE_DATA_HOME="$TMP_ROOT/muse-data"
MUSE_WORKSPACE="$TMP_ROOT/muse-workspace"
mkdir -p "$MUSE_CONFIG_HOME" "$MUSE_DATA_HOME" "$MUSE_WORKSPACE"
git -C "$MUSE_WORKSPACE" init -q

WS_JSON=$(lab workspace create --cwd "$MUSE_WORKSPACE" --label fm-muse-live-ev --no-focus)
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id')
TARGET="$SESSION:$PANE"
HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1 || printf 'herdr-unknown')

MUSE_LAUNCH=$(printf 'env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS XDG_CONFIG_HOME=%s XDG_DATA_HOME=%s MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on %s --provider echo --yolo' \
  "$(shell_quote "$MUSE_CONFIG_HOME")" "$(shell_quote "$MUSE_DATA_HOME")" "$(shell_quote "$MUSE_BIN")")
lab pane run "$PANE" "$MUSE_LAUNCH" >/dev/null

# Readiness gate, same shape as the live guard: a live muse-bin-<version> argv
# identity in the pane, and the shared classifier reading its composer.
MUSE_VERSION=version-unknown
i=0
while [ "$i" -lt 90 ]; do
  proc_json=$(lab pane process-info --pane "$PANE" 2>/dev/null || true)
  exec_name=$(printf '%s' "$proc_json" | jq -r '
    [.result.process_info.foreground_processes[]?
     | ((.argv? // []) | if type == "array" then (.[0]? // empty) else empty end),
       (.argv0? // empty)]
    | map(select(type == "string" and . != ""))
    | map(split("/") | last)
    | map(select(test("^muse-bin-.+$")))
    | first // empty' 2>/dev/null || true)
  if [ -n "$exec_name" ]; then
    MUSE_VERSION=${exec_name#muse-bin-}
    state=$(fm_backend_herdr_composer_state "$TARGET")
    [ "$state" = empty ] && break
  fi
  i=$((i + 1))
  sleep 1
done

NATIVE_RAW=$(fm_backend_herdr_agent_status_raw "$SESSION" "$PANE")

# The real idle pane, exactly as herdr renders it.
lab pane read "$PANE" --source recent --lines 200 > "$OUT/muse-idle-pane.txt" 2>/dev/null || true
lab pane read "$PANE" --source recent --lines 200 --format ansi > "$OUT/muse-idle-pane.ansi" 2>/dev/null || true

# The same LIVE pane, read through the shared classifier at both revisions.
verdict_base=$(
  PATH="$FAKEBIN:$ORIGINAL_PATH" bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_composer_state "$2"' _ "$BASE_ROOT" "$TARGET"
)
verdict_fixed=$(
  PATH="$FAKEBIN:$ORIGINAL_PATH" bash -c '. "$1/bin/backends/herdr.sh"; fm_backend_herdr_composer_state "$2"' _ "$ROOT" "$TARGET"
)

# One real steer through the adapter boundary fm-send.sh calls.
TOKEN="FMMUSEEV$$_$RANDOM"
submit_verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "Reply with exactly $TOKEN and nothing else." 3 0.4 0.4)

sleep 2
lab pane read "$PANE" --source recent --lines 200 > "$OUT/muse-after-steer-pane.txt" 2>/dev/null || true
occurrences=$(grep -F -c "$TOKEN" "$OUT/muse-after-steer-pane.txt" || true)

{
  printf 'Live Muse-on-Herdr evidence (isolated lab session %s)\n' "$SESSION"
  printf '  herdr:                 %s\n' "$HERDR_VER"
  printf '  muse:                  muse-bin-%s (--provider echo --yolo, isolated XDG lab)\n' "$MUSE_VERSION"
  printf '  native agent_status:   %s\n' "${NATIVE_RAW:-<none>}"
  printf '\n'
  printf '  shared classifier on the SAME live idle Muse composer:\n'
  printf '    base  %s -> %s\n' "3eb5b63 (before the repair)" "$verdict_base"
  printf '    fixed %s -> %s\n' "5110b99 (this branch)" "$verdict_fixed"
  printf '\n'
  printf '  fm_backend_herdr_send_text_submit (the boundary fm-send.sh calls) on a real steer: %s\n' "$submit_verdict"
  printf '  token rendered in the captured pane window: %s occurrence(s)\n' "$occurrences"
} > "$OUT/summary.txt"

cat "$OUT/summary.txt"
