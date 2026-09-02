#!/usr/bin/env bash
# Demonstrates the headline lifecycle fix: the keyed-answer intake no longer
# runs under the per-source lock, so a hung answer backlog cannot wedge the
# source's own reconcile and retirement. A fixture adapter blocks forever inside
# `answers`; while it is blocked, `retire` and `reconcile` must still complete.
set -u
ROOT=${1:?repo root}
D=$(mktemp -d "${TMPDIR:-/tmp}/fm-unlocked-intake.XXXXXX")
export FM_PROCEVENT_CLAIM_ROOT="$D/claims"
trap 'rm -rf "$D"' EXIT
HOME_DIR="$D/home"; mkdir -p "$HOME_DIR/state"
mkdir -p "$D/adapter-root/bin"
cat > "$D/adapter-root/bin/fm-procevent-slowfeed.sh" <<'SH'
#!/usr/bin/env bash
case "${1-}" in
  answers) while [ ! -e "$FM_HOME/state/feed-go" ]; do sleep 0.05; done ;;
  *) exit 2 ;;
esac
SH
chmod +x "$D/adapter-root/bin/fm-procevent-slowfeed.sh"
cat > "$D/blocker.sh" <<'SH'
#!/usr/bin/env bash
trigger=$1; shift
while [ ! -e "$trigger" ]; do sleep 0.05; done
printf '%s\n' "$@"
SH
chmod +x "$D/blocker.sh"

pe() { FM_ROOT_OVERRIDE="$D/adapter-root" FM_PROCEVENT_UNDER_TEST="$ROOT/bin/fm-procevent.sh" \
       FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" "$@"; }


# Portable bounded run: exit 124 when the command outlives the deadline.
bounded() {  # <seconds> <command...>
  local limit=$1; shift
  "$@" >/dev/null 2>&1 &
  local pid=$! i=0
  while kill -0 "$pid" 2>/dev/null; do
    [ "$i" -ge $((limit * 10)) ] && { kill -KILL "$pid" 2>/dev/null; wait "$pid" 2>/dev/null; return 124; }
    sleep 0.1; i=$((i + 1))
  done
  wait "$pid"
}
run_pe() { FM_ROOT_OVERRIDE="$D/adapter-root" FM_PROCEVENT_UNDER_TEST="$ROOT/bin/fm-procevent.sh" \
           FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" "$@"; }

pe register slowfeed feed-src -- "$D/blocker.sh" "$D/trigger" "feed payload" >/dev/null
FM_HOME="$HOME_DIR" "$ROOT/bin/fm-captain-hold.sh" bind feed-src >/dev/null
printf 'registered source feed-src with an adapter whose keyed-answer intake blocks forever\n\n'

pe start feed-src >/dev/null 2>&1 &
runner=$!
for _ in $(seq 1 100); do [ -e "$FM_PROCEVENT_CLAIM_ROOT/feed-src.claim" ] && break; sleep 0.1; done
token=$(sed -n '3p' "$FM_PROCEVENT_CLAIM_ROOT/feed-src.claim")
: > "$D/trigger"
GEN="$HOME_DIR/state/procevent/.feed-src.$token.rcpt.output.gen"
for _ in $(seq 1 200); do [ -e "$GEN" ] && break; sleep 0.1; done
[ -e "$GEN" ] || { echo "FAIL: the runner never reached the intake"; exit 1; }
printf 'the runner is now blocked INSIDE the keyed-answer intake (generation note staged):\n  %s\n\n' "${GEN#"$HOME_DIR"/}"

printf 'while it is blocked there, ask the runner to reconcile the same source:\n'
t0=$(date +%s)
bounded 30 run_pe reconcile
rc=$?; t1=$(date +%s)
printf '  reconcile exit=%s after %ss  %s\n\n' "$rc" "$((t1 - t0))" \
  "$([ "$rc" = 124 ] && echo '<- WEDGED by the intake' || echo '<- not wedged by the intake')"

printf 'and retire the same source while the intake is still blocked:\n'
t0=$(date +%s)
bounded 60 run_pe retire feed-src
rc=$?; t1=$(date +%s)
printf '  retire    exit=%s after %ss  %s\n\n' "$rc" "$((t1 - t0))" \
  "$([ "$rc" = 124 ] && echo '<- WEDGED by the intake' || echo '<- not wedged by the intake')"

[ -e "$FM_PROCEVENT_CLAIM_ROOT/feed-src.claim" ] \
  && printf 'claim after retire : still present (unexpected)\n' \
  || printf 'claim after retire : reaped\n'
printf 'staged verdict     : %s\n' \
  "$([ -e "${GEN%.gen}" ] && echo 'preserved - its receipt seam is still owed' || echo 'gone')"
printf 'generation note    : %s\n' \
  "$([ -e "$GEN" ] && echo 'preserved - recovery still needs it' || echo 'gone')"
: > "$HOME_DIR/state/feed-go"
wait "$runner" 2>/dev/null || true
