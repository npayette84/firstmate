#!/usr/bin/env bash
# End-to-end walkthrough of the Lavish answer-receipt lifecycle at the branch head.
#
# Drives the REAL adapter (bin/fm-procevent-lavish.sh), the REAL runner
# (bin/fm-procevent.sh) and the REAL keyed-answer intake against a stand-in for
# the published lavish-axi poll shape, and prints exactly what the captain sees:
# the acknowledgement text Firstmate presents back onto the review page.
#
# Usage: FM_REPO_ROOT=/path/to/firstmate bash receipt-lifecycle-e2e.sh
set -u
ROOT=${FM_REPO_ROOT:?set FM_REPO_ROOT to the firstmate checkout}
ADAPTER="$ROOT/bin/fm-procevent-lavish.sh"
RUNNER="$ROOT/bin/fm-procevent.sh"

E=$(mktemp -d "${TMPDIR:-/tmp}/fm-receipt-demo.XXXXXX")
HOME_DIR="$E/home"; mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
STUB_BIN="$E/bin"; mkdir -p "$STUB_BIN"
QUEUE="$E/queue"; IDX="$E/idx"; CALLS="$E/calls"; REPLIES="$E/replies"
mkdir -p "$REPLIES"; : > "$QUEUE"

# Stand-in for the published `lavish-axi poll` shape. It records each call and,
# whole and unmangled, whatever text arrives on --agent-reply: that text is what
# the captain reads in the review page's conversation panel.
cat > "$STUB_BIN/lavish-axi" <<SH
#!/usr/bin/env bash
c=\$(cat "$CALLS" 2>/dev/null || echo 0); c=\$((c + 1)); printf '%s\n' "\$c" > "$CALLS"
if [ "\${3-}" = "--agent-reply" ]; then printf '%s' "\${4-}" > "$REPLIES/\$(printf '%03d' "\$c").txt"; fi
n=\$(cat "$IDX" 2>/dev/null || echo 0); n=\$((n + 1)); printf '%s\n' "\$n" > "$IDX"
awk -v want="\$n" '/^### \$/ { seen++; next } seen == want - 1 { print; got = 1 } END { exit got ? 0 : 1 }' "$QUEUE"
SH
chmod +x "$STUB_BIN/lavish-axi"

lav() { FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$HOME_DIR/state" \
  FM_DATA_OVERRIDE="$HOME_DIR/data" FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
  FM_PROCEVENT_CLAIM_ROOT="$HOME_DIR/claims" "$ADAPTER" "$@"; }
pe() { FM_HOME="$HOME_DIR" FM_PROCEVENT_CLAIM_ROOT="$HOME_DIR/claims" "$RUNNER" "$@"; }
captain() { ( cd "$HOME_DIR" && FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
  FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
  FM_CONFIG_OVERRIDE="$HOME_DIR/config" "$ROOT/bin/fm-captain-hold.sh" "$@" ); }
tsk() { ( cd "$HOME_DIR" && tasks-axi "$@" ); }
reconcile() { PATH="$STUB_BIN:$PATH" pe reconcile >/dev/null 2>&1; }
calls() { cat "$CALLS" 2>/dev/null || echo 0; }
presentations() { ls "$REPLIES" 2>/dev/null | grep -c . || true; }
calls_at_least() { [ "$(calls)" -ge "$1" ]; }
captured() { [ -e "$HOME_DIR/state/procevent-inbox/$SID.$1.result" ]; }
source_retired() { [ ! -e "$HOME_DIR/state/procevent/$SID.source" ]; }
until_ok() { local i=0; while [ $i -lt 80 ]; do reconcile; if "$@"; then return 0; fi; sleep 0.25; i=$((i+1)); done; return 1; }

choice() { printf '  "%s","%s: %s\\n\\nContext data:\\n{\\n  \\"question\\": \\"%s\\", \\"answer\\": \\"%s\\"\\n}",section > form,choice,"%s: %s"\n' "$1" "$4" "$3" "$2" "$3" "$4" "$3"; }
msg() { printf '  "","%s","","message","Freeform message"\n' "$1"; }
feedback() { { printf 'session:\n  file: /review.html\n  status: feedback\n'
  [ "$1" = true ] && printf '  session_ended: true\n  ended_by: user\n'
  printf 'prompts[%s]{uid,prompt,selector,tag,text}:\n' "$(printf '%s\n' "$2" | grep -c .)"
  printf '%s\n' "$2"; printf '### \n'; } >> "$QUEUE"; }
ended_empty() { printf 'session:\n  file: /review.html\n  status: ended\n  ended_by: user\n### \n' >> "$QUEUE"; }

banner() { printf '\n================================================================\n%s\n================================================================\n' "$1"; }
SEEN=0
page_shows() {  # print every acknowledgement presented since the last checkpoint
  local f n=0 total; total=$(presentations)
  if [ "$total" -le "$SEEN" ]; then printf '(no new acknowledgement was presented)\n'; return 0; fi
  for f in "$REPLIES"/*.txt; do
    n=$((n + 1)); [ "$n" -gt "$SEEN" ] || continue
    printf 'CAPTAIN SEES ON THE REVIEW PAGE (acknowledgement #%s, poll %s):\n\n' \
      "$n" "$(basename "$f" .txt | sed 's/^0*//')"
    sed 's/^/    /' "$f"; printf '\n'
  done
  SEEN=$total
}

ART="$E/review.html"; printf '<h1>Captain review deck</h1>\n' > "$ART"
SID=$(lav source-id "$ART")

banner "Setup: two captain calls are on hold, waiting for an answer"
tsk add deck-alpha "Alpha call" --kind ship --repo sample --body 'Alpha plan.' >/dev/null
captain hold deck-alpha --reason "alpha choice pending" >/dev/null
tsk add deck-gamma "Gamma call" --kind ship --repo sample --body 'Gamma plan.' >/dev/null
captain hold deck-gamma --reason "gamma choice pending" >/dev/null
printf 'source id: %s\n\n' "$SID"
tsk show deck-alpha --full | sed -n '1,5p'

R1="$(choice 3 deck-alpha go 'Alpha')
$(choice 4 deck-beta hold 'Beta')
$(choice 5 deck-gamma resume 'Gamma')
$(msg 'please also look at the footer')"
feedback false "$R1"        # round 1: three answers (one naming no task) + a message
feedback false "$R1"        # round 2: byte-identical replay of the same submission
feedback true "$(choice 9 deck-alpha ship 'Alpha')"  # round 3: Send & End
ended_empty                 # the post-end poll that carries the final receipt

captain bind "$SID" >/dev/null
lav arm "$ART" >/dev/null

banner "Round 1: the captain submits three answers and a message"
until_ok captured 1 || { echo "round 1 was never captured"; exit 1; }
printf 'Receipt state right after capture (fm-procevent-lavish.sh receipt-text):\n\n'
lav receipt-text "$SID" | sed 's/^/    /'
printf '\n-> Received and Saved exist because the capture and the keyed-answer intake\n'
printf '   already ran. Applying and Complete are absent: the handler has not started.\n'

banner "The handler starts work, then finishes it"
lav applying "$SID" 1
lav applying "$SID" 1   # a duplicate call is idempotent
printf '\nReceipt state while the handler is working:\n\n'
lav receipt-text "$SID" | sed 's/^/    /'
printf '\n'
lav complete "$SID" 1
printf '\n\nReceipt state after the handler finished:\n\n'
lav receipt-text "$SID" | sed 's/^/    /'
printf '\n'
pe handled "$SID" 1 >/dev/null

banner "The next poll carries that acknowledgement back onto the review page"
until_ok calls_at_least 2 || { echo "no second poll"; exit 1; }
page_shows

banner "The captain submits the byte-identical thing again (a replay)"
until_ok captured 2 || { echo "the replay was never captured"; exit 1; }
pe handled "$SID" 2 >/dev/null 2>&1 || true
until_ok calls_at_least 3 || { echo "no third poll"; exit 1; }
page_shows
printf 'Times the answer was actually applied to deck-alpha (must be 1): %s\n' \
  "$(tsk show deck-alpha --full | grep -c 'Answer: go')"

banner "Send & End: the final submission still gets its receipt on the ended page"
until_ok captured 3 || { echo "the final round was never captured"; exit 1; }
pe handled "$SID" 3 >/dev/null 2>&1 || true
until_ok calls_at_least 4 || { echo "no post-end poll"; exit 1; }
page_shows

banner "The source retires only after that final receipt was delivered"
if until_ok source_retired; then
  printf 'source registration: RETIRED (state/procevent/%s.source is gone)\n' "$SID"
else
  printf 'source registration: STILL ARMED\n'
fi
printf 'delivery journaled for round(s): %s\n' \
  "$(awk -F '\t' '$1 == "delivered" { printf "%s ", $3 }' "$HOME_DIR/state/procevent/$SID.receipts")"
printf 'polls issued: %s; acknowledgements presented: %s\n' "$(calls)" "$(presentations)"

banner "Final durable outcome of the captain's answers"
tsk show deck-alpha --full | sed -n '1,8p'
printf '\ndeck-gamma (answered with a card-declared release):\n'
tsk show deck-gamma --full | grep -i '^  held' | sed 's/^/  /'
printf '\ndeck-beta (a decision key naming no task) -> %s\n' \
  "$(tsk show deck-beta --full >/dev/null 2>&1 && echo 'PRESENT (unexpected)' || echo 'never created, correctly reported as not saved')"

banner "Every acknowledgement presented during this session, in order"
for f in "$REPLIES"/*.txt; do
  printf -- '--- poll %s ---\n' "$(basename "$f" .txt | sed 's/^0*//')"
  sed 's/^/    /' "$f"; printf '\n'
done

FM_HOME="$HOME_DIR" "$RUNNER" sweep-home >/dev/null 2>&1 || true
rm -rf "$E"
