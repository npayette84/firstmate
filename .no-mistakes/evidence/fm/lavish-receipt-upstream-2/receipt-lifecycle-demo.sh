#!/usr/bin/env bash
# End-to-end demonstration of the Lavish answer-receipt lifecycle at the head
# under test.
#
# It drives the REAL adapter (bin/fm-procevent-lavish.sh), the REAL runner
# (bin/fm-procevent.sh) and the REAL keyed-answer intake (bin/fm-captain-hold.sh)
# against a stand-in lavish-axi that speaks the published poll shape, and prints
# what the captain actually sees in the Lavish conversation at each step, plus
# the exact --agent-reply payload handed to the Lavish session.
#
# No live Lavish server is started; the stand-in is the published poll wire
# shape only. A manual reconcile loop stands in for the watcher cadence, and
# ack_captures() stands in for the wake handler acknowledging each capture.
set -u
ROOT=${1:?usage: receipt-lifecycle-demo.sh <repo-root>}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/receipt-demo.XXXXXX")
HOME_DIR="$TMP/home"
trap 'FM_HOME="$HOME_DIR" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true; rm -rf "$TMP"' EXIT

ADAPTER="$ROOT/bin/fm-procevent-lavish.sh"
RUNNER="$ROOT/bin/fm-procevent.sh"
STUB_BIN="$TMP/stub/bin"; STUB_QUEUE="$TMP/stub/queue"; STUB_IDX="$TMP/stub/idx"; STUB_LOG="$TMP/stub/argv.log"
mkdir -p "$STUB_BIN"; : > "$STUB_QUEUE"

# Stand-in for the published `lavish-axi poll <file> [--agent-reply "..."]`:
# it records exactly what it was handed and returns the next queued response.
cat > "$STUB_BIN/lavish-axi" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$STUB_LOG"
n=\$(cat "$STUB_IDX" 2>/dev/null || echo 0); n=\$((n + 1)); printf '%s\n' "\$n" > "$STUB_IDX"
awk -v want="\$n" '/^### \$/ { seen++; next } seen == want - 1 { print; got = 1 } END { exit got ? 0 : 1 }' "$STUB_QUEUE"
SH
chmod +x "$STUB_BIN/lavish-axi"

mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"

lavish() { PATH="$STUB_BIN:$PATH" FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_PROCEVENT_CLAIM_ROOT="$HOME_DIR/claims" "$ADAPTER" "$@"; }
captain() { ( cd "$HOME_DIR" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  "$ROOT/bin/fm-captain-hold.sh" "$@" ); }
tasks_in() { ( cd "$HOME_DIR" && tasks-axi "$@" ); }
reconcile() { PATH="$STUB_BIN:$PATH" FM_HOME="$HOME_DIR" FM_PROCEVENT_CLAIM_ROOT="$HOME_DIR/claims" "$RUNNER" reconcile >/dev/null 2>&1; }

# The wake handler's job: acknowledge every captured generation. Nothing here
# writes receipt text - the receipt is the runner's and the adapter's own.
ack_captures() {
  local f s
  for f in "$HOME_DIR/state/procevent-inbox/$SID".*.result; do
    [ -e "$f" ] || continue
    s=$(basename "$f"); s=${s#"$SID".}; s=${s%.result}
    # Only a generation whose receipt seam has already had its chance is
    # published, so only such a generation can have reached a handler.
    [ -e "$HOME_DIR/state/procevent-inbox/$SID.$s.receipted" ] || continue
    FM_HOME="$HOME_DIR" "$RUNNER" handled "$SID" "$s" >/dev/null 2>&1 || true
  done
}
drive_until() {  # <condition string>: reconcile + acknowledge until it holds
  local i=0
  while [ "$i" -lt 60 ]; do
    reconcile; ack_captures
    if eval "$*"; then return 0; fi
    sleep 0.25; i=$((i + 1))
  done
  return 1
}
wait_seam() { local i=0; while [ ! -e "$HOME_DIR/state/procevent-inbox/$SID.$1.receipted" ] && [ "$i" -lt 100 ]; do sleep 0.2; i=$((i+1)); done; }
rounds() { local n; n=$(grep -c '^received' "$JOURNAL" 2>/dev/null | head -1); printf '%s' "${n:-0}"; }
last_seq() { awk -F '\t' '$1 == "received" { s = $2 } END { print s }' "$JOURNAL"; }

choice_row() { printf '  "%s","%s: %s\\n\\nContext data:\\n{\\n  \\"question\\": \\"%s\\", \\"answer\\": \\"%s\\"\\n}",section > form,choice,"%s: %s"\n' "$1" "$4" "$3" "$2" "$3" "$4" "$3"; }
message_row() { printf '  "","%s","","message","Freeform message"\n' "$1"; }
q_feedback() { { printf 'session:\n  file: /review.html\n  status: feedback\n'
  printf 'prompts[%s]{uid,prompt,selector,tag,text}:\n' "$(printf '%s\n' "$1" | grep -c .)"; printf '%s\n' "$1"; printf '### \n'; } >> "$STUB_QUEUE"; }
q_truncated() { { printf 'session:\n  file: /review.html\n  status: feedback\n'
  printf 'prompts[%s]{uid,prompt,selector,tag,text}:\n' "$1"; printf '%s\n' "$2"; printf '### \n'; } >> "$STUB_QUEUE"; }
q_ended() { printf 'session:\n  file: /review.html\n  status: ended\n  ended_by: user\n### \n' >> "$STUB_QUEUE"; }

show() { printf '\n  +-- what the captain sees in the Lavish conversation --------------------\n'
  lavish receipt-text "$SID" | sed 's/^/  | /'
  printf '\n  +-----------------------------------------------------------------------\n'; }

ART="$TMP/review.html"; printf '<h1>deck</h1>\n' > "$ART"
SID=$(lavish source-id "$ART")
JOURNAL="$HOME_DIR/state/procevent/$SID.receipts"
tasks_in add deck-alpha "Alpha call" --kind ship --repo sample --body 'Alpha plan.' >/dev/null
captain hold deck-alpha --reason "alpha choice pending" >/dev/null

ROUND_A_ROWS="$(choice_row 3 deck-alpha go 'Alpha')
$(choice_row 4 deck-beta hold 'Beta')
$(message_row 'please also look at the footer')"

q_feedback "$ROUND_A_ROWS"                                        # 1: two answers + a message
q_truncated 3 "$(message_row 'partial wire read')"                # 2: a response truncated in transit
q_feedback "$(message_row 'the header spacing looks off to me')"  # 3: a written comment, no answers
q_feedback "$ROUND_A_ROWS"                                        # 4: the identical submission again
q_ended                                                           # 5: the captain closes the review

captain bind "$SID" >/dev/null
lavish arm "$ART" >/dev/null

printf '=========================================================================\n'
printf ' 1. The captain answers two cards and adds a written message\n'
printf '=========================================================================\n'
drive_until '[ "$(rounds)" -ge 1 ]' || { echo "FAILED: no receipt journaled"; exit 1; }
wait_seam 1
show
printf '\n  durable facts behind that text (state/procevent/<source>.receipts):\n'
sed 's/^/    /' "$JOURNAL"

printf '\n=========================================================================\n'
printf ' 2. Firstmate starts routing the answers, then finishes\n'
printf '=========================================================================\n'
lavish applying "$SID" 1 >/dev/null; show
lavish complete "$SID" 1 >/dev/null; show
printf '\n  what the accepted answer actually did:\n'
tasks_in show deck-alpha --full | sed -n '1,8p' | sed 's/^/    /'

printf '\n=========================================================================\n'
printf ' 3. A poll response truncated in transit is refused, never acknowledged\n'
printf '=========================================================================\n'
before=$(rounds)
drive_until '[ -e "$HOME_DIR/state/procevent-inbox/$SID.2.receipted" ]' || true
after=$(rounds)
printf '  received rounds before this response: %s / after: %s\n' "$before" "$after"
if [ -e "$HOME_DIR/state/procevent/$SID.source" ]; then
  printf '  review still armed: yes - a refused parse never ends the review\n'
else
  printf '  review still armed: NO\n'; fi
show

printf '\n=========================================================================\n'
printf ' 4. The captain submits a written comment only, with no answers\n'
printf '=========================================================================\n'
drive_until '[ "$(rounds)" -ge 2 ]' || { echo "FAILED: comment-only round never received"; exit 1; }
wait_seam "$(last_seq)"
show

printf '\n=========================================================================\n'
printf ' 5. The captain re-sends the identical earlier submission\n'
printf '=========================================================================\n'
drive_until '[ "$(rounds)" -ge 3 ]' || { echo "FAILED: replay never received"; exit 1; }
wait_seam "$(last_seq)"
show

printf '\n=========================================================================\n'
printf ' 6. The captain ends the review; it retires after its receipt is shown\n'
printf '=========================================================================\n'
drive_until '[ ! -e "$HOME_DIR/state/procevent/$SID.source" ]' \
  && printf '  the ended review retired, and its receipts record outlives it:\n' \
  || printf '  the ended review is still registered:\n'
sed 's/^/    /' "$JOURNAL"

printf '\n=========================================================================\n'
printf ' 7. Exactly what was delivered to the Lavish session, per poll\n'
printf '=========================================================================\n'
awk '/^poll \// { n++; sub(/^poll [^ ]+ ?/, ""); if ($0 == "") $0 = "(armed with no receipt to present yet)"; printf "\n  poll %d handed to the Lavish session:\n    %s\n", n, $0; next } { printf "    %s\n", $0 }' "$STUB_LOG"

printf '\n=========================================================================\n'
printf ' 8. Answers took effect exactly once\n'
printf '=========================================================================\n'
printf '  times the accepted answer was recorded on deck-alpha: %s\n' "$(tasks_in show deck-alpha --full | grep -c 'Answer: go')"
printf '  the unknown key deck-beta closed a task: %s\n' "$(tasks_in show deck-beta --full 2>/dev/null | grep -c 'state: done' | head -1)"
