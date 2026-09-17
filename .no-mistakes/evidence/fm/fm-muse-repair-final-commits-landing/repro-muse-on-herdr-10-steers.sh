#!/usr/bin/env bash
# Independent test-phase reproduction of the Muse-on-Herdr send false negative.
#
# Launches a REAL Muse Code under a REAL herdr in an isolated lab session
# (bin/fm-herdr-lab.sh), then drives ten consecutive real steers through
# fm_backend_herdr_send_text_submit. For each steer it records:
#   - the verdict fm-send would report (empty == delivery confirmed/landed)
#   - whether Muse actually received the message (echo provider repeats the
#     unique token, so the token appears twice on the pane)
#
# It also classifies the pane's OWN captured idle bytes through both the
# branch-tip composer library and the base-commit one, which is the
# before/after proof for the regression.
set -u

ROOT=${ROOT:?ROOT must point at the worktree}
BASE_LIB=${BASE_LIB:?BASE_LIB must point at the base-commit fm-composer-lib.sh}
STEERS=${STEERS:-10}
LAB_HELPER="$ROOT/bin/fm-herdr-lab.sh"

fail() { printf 'FATAL: %s\n' "$1" >&2; exit 1; }

ORIGINAL_PATH=$PATH
SESSION=$("$LAB_HELPER" name muse-steer10)
TMP_ROOT=$(mktemp -d "$(cd "${TMPDIR:-/tmp}" && pwd -P)/fm-muse-steer10.XXXXXX")
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$FAKEBIN"

cleanup() {
  local rc=$?
  trap - EXIT
  PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$SESSION" >/dev/null 2>&1 || rc=1
  rm -rf "$TMP_ROOT"
  exit "$rc"
}
trap cleanup EXIT

# Same session-pinning wrapper the live guard installs: every herdr call this
# script (or the adapter it sources) makes is forced onto the lab session.
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
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "\${args[@]}"
EOF
chmod +x "$FAKEBIN/herdr"

"$LAB_HELPER" provision "$SESSION" >/dev/null || fail "could not provision the isolated Herdr lab"
export PATH="$FAKEBIN:$ORIGINAL_PATH"
unset HERDR_PANE HERDR_PANE_ID 2>/dev/null || true

# shellcheck source=/dev/null
. "$ROOT/bin/backends/herdr.sh"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$SESSION" "$@"; }

HERDR_VER=$(PATH="$ORIGINAL_PATH" herdr --version 2>/dev/null | head -1)
MUSE_BIN=$(PATH="$ORIGINAL_PATH" command -v muse) || fail "muse is not installed"

MUSE_CONFIG_HOME="$TMP_ROOT/muse-config"
MUSE_DATA_HOME="$TMP_ROOT/muse-data"
MUSE_WORKSPACE="$TMP_ROOT/muse-workspace"
mkdir -p "$MUSE_CONFIG_HOME" "$MUSE_DATA_HOME" "$MUSE_WORKSPACE"
git -C "$MUSE_WORKSPACE" init -q

WS_JSON=$(lab workspace create --cwd "$MUSE_WORKSPACE" --label fm-muse-steer10 --no-focus) \
  || fail "could not create the isolated workspace"
PANE=$(printf '%s' "$WS_JSON" | jq -er '.result.root_pane.pane_id') \
  || fail "workspace create did not return a pane id"
TARGET="$SESSION:$PANE"

LAUNCH="env -u CURSOR_AGENT -u CURSOR_INVOKED_AS -u GEMINI_CLI env -u CLAUDECODE -u PI_CODING_AGENT -u GROK_AGENT -u FM_PI_HARNESS XDG_CONFIG_HOME='$MUSE_CONFIG_HOME' XDG_DATA_HOME='$MUSE_DATA_HOME' MUSE_EXPERIMENTAL_FOREIGN_PERSONAL_CONTEXT_KILL=on '$MUSE_BIN' --provider echo --yolo"
lab pane run "$PANE" "$LAUNCH" >/dev/null || fail "could not launch Muse in the lab pane"

# Readiness: the pane must be running the exec'd muse-bin-<version> and the
# shared classifier must read its composer as empty.
exec_name=; state=unread; ready=0
for _ in $(seq 1 90); do
  proc=$(lab pane process-info --pane "$PANE" 2>/dev/null || true)
  exec_name=$(printf '%s' "$proc" | jq -r '
    [.result.process_info.foreground_processes[]?
     | ((.argv? // []) | if type == "array" then (.[0]? // empty) else empty end),
       (.argv0? // empty)]
    | map(select(type == "string" and . != ""))
    | map(split("/") | last)
    | map(select(test("^muse-bin-.+$")))
    | first // empty' 2>/dev/null || true)
  if [ -n "$exec_name" ]; then
    state=$(fm_backend_herdr_composer_state "$TARGET")
    [ "$state" = empty ] && { ready=1; break; }
  fi
  sleep 1
done

RAW=$(fm_backend_herdr_agent_status_raw "$SESSION" "$PANE")

# Capture the idle pane's own bytes exactly the way the adapter captures them
# (fm_backend_herdr_capture_ansi), so both libraries below are judged on the
# same bytes fm_backend_herdr_composer_state actually fed the classifier.
IDLE_ANSI="$TMP_ROOT/idle.ansi"
fm_backend_herdr_capture_ansi "$TARGET" "${FM_COMPOSER_CAPTURE_LINES:-200}" > "$IDLE_ANSI" 2>/dev/null || true
cp "$IDLE_ANSI" "${EVIDENCE_ANSI:-$TMP_ROOT/unused.ansi}" 2>/dev/null || true

# Same capability descriptor and lazy-identity handshake
# fm_backend_herdr_composer_state performs, so the only variable between the
# two runs below is which fm-composer-lib.sh owns the verdict.
classify_with() {  # <lib path> <ansi file> <identity>
  env PATH="$ORIGINAL_PATH" bash -c '
    set -u
    . "$1"
    screen=$(cat "$2")
    caps=$(printf "styled=1\ncursor=0\nidentity=1\nrows=%s" "${FM_COMPOSER_CAPTURE_LINES:-200}")
    v=$(fm_composer_classify_screen "$caps" "$screen")
    if [ "$v" = need-identity ]; then
      v=$(fm_composer_classify_screen "$caps" "$screen" "" "$3")
      [ "$v" != need-identity ] || v=unknown
    fi
    printf "%s" "$v"
  ' _ "$1" "$2" "$3" 2>/dev/null || printf 'classify-error'
}

printf 'harness under test\n'
printf '  herdr:                  %s\n' "$HERDR_VER"
printf '  muse pane exec identity: %s\n' "${exec_name:-none}"
printf '  herdr native agent status for the Muse pane: %s\n' "${RAW:-<none>}"
printf '  shared classifier composer state (branch tip): %s\n' "$state"
printf '  readiness reached: %s\n' "$ready"
printf '\n'

[ "$ready" = 1 ] || fail "Muse never reached a ready state (exec '${exec_name:-none}', composer '$state')"

IDENT0=$(fm_backend_herdr_agent_identity_raw "$SESSION" "$PANE" 2>/dev/null || true)
[ -n "$IDENT0" ] || IDENT0=probe-absent
printf 'the idle Muse composer, classified from the pane bytes the adapter reads\n'
printf '  native identity handed to the classifier: %s\n' "$(printf '%s' "$IDENT0" | tr '\t' '/')"
printf '  base commit fa93097 fm-composer-lib.sh -> %s   (BEFORE: the false negative)\n' "$(classify_with "$BASE_LIB" "$IDLE_ANSI" "$IDENT0")"
printf '  branch tip  98bc92c fm-composer-lib.sh -> %s     (AFTER: the repair)\n' "$(classify_with "$ROOT/bin/fm-composer-lib.sh" "$IDLE_ANSI" "$IDENT0")"
printf '\n'

confirmed=0; landed=0; false_neg=0; base_unknown=0
printf 'ten consecutive real steers through fm_backend_herdr_send_text_submit\n'
printf '  (base verdict = the same post-steer pane bytes replayed through the base-commit library)\n'
for n in $(seq 1 "$STEERS"); do
  TOKEN="FMTESTSTEER$$_${n}_$RANDOM"
  verdict=$(fm_backend_herdr_send_text_submit "$TARGET" "Reply with exactly $TOKEN and nothing else." 3 0.4 0.4) \
    || verdict=send-error
  [ "$verdict" = empty ] && confirmed=$((confirmed + 1))
  echoed=no
  for _ in $(seq 1 60); do
    screen=$(lab pane read "$PANE" --source recent --lines 400 2>/dev/null || true)
    occ=$(printf '%s\n' "$screen" | grep -F -c "$TOKEN" || true)
    if [ "$occ" -ge 2 ]; then echoed=yes; break; fi
    sleep 1
  done
  [ "$echoed" = yes ] && landed=$((landed + 1))
  if [ "$echoed" = yes ] && [ "$verdict" != empty ]; then
    false_neg=$((false_neg + 1))
  fi
  # Let the pane settle back to an idle composer, then replay the very bytes
  # this steer left on screen through the base-commit library.
  for _ in $(seq 1 30); do
    [ "$(fm_backend_herdr_composer_state "$TARGET")" = empty ] && break
    sleep 1
  done
  post="$TMP_ROOT/post-$n.ansi"
  fm_backend_herdr_capture_ansi "$TARGET" "${FM_COMPOSER_CAPTURE_LINES:-200}" > "$post" 2>/dev/null || true
  ident=$(fm_backend_herdr_agent_identity_raw "$SESSION" "$PANE" 2>/dev/null || true)
  [ -n "$ident" ] || ident=probe-absent
  base_verdict=$(classify_with "$BASE_LIB" "$post" "$ident")
  [ "$base_verdict" = empty ] || base_unknown=$((base_unknown + 1))
  printf '  steer %2d: fm-send verdict=%-8s muse echoed the token back=%-4s base-commit verdict on the same bytes=%s\n' \
    "$n" "$verdict" "$echoed" "$base_verdict"
done

printf '\n  verdict=empty (delivery confirmed): %d/%d\n' "$confirmed" "$STEERS"
printf '  message actually landed in Muse:    %d/%d\n' "$landed" "$STEERS"
printf '  FALSE NEGATIVES on this branch (landed but unconfirmed): %d/%d\n' "$false_neg" "$STEERS"
printf '  the same panes under the base commit would have been unconfirmed: %d/%d\n' "$base_unknown" "$STEERS"

printf '\n----- Muse pane as the operator sees it after the last steer -----\n'
fm_backend_herdr_capture "$TARGET" 40 2>/dev/null | sed -e 's/[[:space:]]*$//' -e '/^$/d'
printf -- '----- end -----\n'

[ "$false_neg" -eq 0 ] && [ "$confirmed" -eq "$STEERS" ] && [ "$landed" -eq "$STEERS" ]
