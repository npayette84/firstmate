#!/usr/bin/env bash
# Constraint 4 check: text arriving from the remote review page is DATA.
# A captain submission whose answer values, decision keys and freeform message
# are all shell metacharacter payloads must not be interpreted, must not reach
# the visible receipt, and must not gain any authority.
set -u
ROOT=${FM_REPO_ROOT:?set FM_REPO_ROOT to the firstmate checkout}
ADAPTER="$ROOT/bin/fm-procevent-lavish.sh"; RUNNER="$ROOT/bin/fm-procevent.sh"
E=$(mktemp -d "${TMPDIR:-/tmp}/fm-receipt-untrusted.XXXXXX")
SENTINEL_DIR="$E/sentinels"; mkdir -p "$SENTINEL_DIR"
HOME_DIR="$E/home"; mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
STUB_BIN="$E/bin"; mkdir -p "$STUB_BIN"; QUEUE="$E/queue"; IDX="$E/idx"; CALLS="$E/calls"
REPLIES="$E/replies"; mkdir -p "$REPLIES"; : > "$QUEUE"
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
until_ok() { local i=0; while [ $i -lt 80 ]; do reconcile; if "$@"; then return 0; fi; sleep 0.25; i=$((i+1)); done; return 1; }
captured() { [ -e "$HOME_DIR/state/procevent-inbox/$SID.$1.result" ]; }
calls_at_least() { [ "$(cat "$CALLS" 2>/dev/null || echo 0)" -ge "$1" ]; }

ART="$E/review.html"; printf '<h1>deck</h1>\n' > "$ART"; SID=$(lav source-id "$ART")
tsk add deck-alpha "Alpha call" --kind ship --repo sample --body 'Alpha plan.' >/dev/null
captain hold deck-alpha --reason "alpha choice pending" >/dev/null

# Every remote-controlled field carries a shell payload.
PAY_ANSWER='go$(touch '"$SENTINEL_DIR"'/answer-subst)`touch '"$SENTINEL_DIR"'/answer-backtick`; touch '"$SENTINEL_DIR"'/answer-semicolon'
PAY_KEY='deck-alpha; touch '"$SENTINEL_DIR"'/key-semicolon'
PAY_MSG='hi $(touch '"$SENTINEL_DIR"'/msg-subst) && touch '"$SENTINEL_DIR"'/msg-and'
printf 'Payloads submitted from the review page\n'
printf '  answer value : %s\n' "$PAY_ANSWER"
printf '  decision key : %s\n' "$PAY_KEY"
printf '  free message : %s\n\n' "$PAY_MSG"

row_choice() { printf '  "%s","%s: %s\\n\\nContext data:\\n{\\n  \\"question\\": \\"%s\\", \\"answer\\": \\"%s\\"\\n}",section > form,choice,"%s: %s"\n' "$1" "$4" "$3" "$2" "$3" "$4" "$3"; }
row_msg() { printf '  "","%s","","message","Freeform message"\n' "$1"; }
ROWS="$(row_choice 3 deck-alpha "$PAY_ANSWER" 'Alpha')
$(row_choice 4 "$PAY_KEY" go 'Beta')
$(row_msg "$PAY_MSG")"
{ printf 'session:\n  file: /review.html\n  status: feedback\n'
  printf 'prompts[3]{uid,prompt,selector,tag,text}:\n'; printf '%s\n' "$ROWS"; printf '### \n'; } >> "$QUEUE"
printf 'session:\n  file: /review.html\n  status: ended\n  ended_by: user\n### \n' >> "$QUEUE"

captain bind "$SID" >/dev/null
lav arm "$ART" >/dev/null
until_ok captured 1 || { echo "the payload submission was never captured"; exit 1; }

echo "1. Did anything execute?"
found=$(ls -A "$SENTINEL_DIR" 2>/dev/null | grep -c . || true)
if [ "$found" = 0 ]; then echo "   no sentinel was created - nothing was interpreted as a command"
else echo "   FAIL: shell payload executed ->"; ls -1 "$SENTINEL_DIR" | sed 's/^/     /'; fi

echo
echo "2. What does the captain see on the review page?"
lav applying "$SID" 1 >/dev/null; lav complete "$SID" 1 >/dev/null; pe handled "$SID" 1 >/dev/null
until_ok calls_at_least 2 || { echo "no delivery poll"; exit 1; }
sed 's/^/   /' "$REPLIES"/*.txt; printf '\n'

echo "3. Did any remote byte leak into that visible text?"
text=$(cat "$REPLIES"/*.txt)
leak=0
for probe in 'touch' '$(' '`' 'deck-alpha' "$SENTINEL_DIR" '/' 'hi '; do
  case "$text" in *"$probe"*) printf '   FAIL: visible receipt contains %s\n' "$probe"; leak=1 ;; esac
done
[ "$leak" = 0 ] && echo "   none - counts and UTC timestamps only"

echo
echo "4. Did the payload key gain any authority?"
printf '   deck-alpha state after the submission: %s\n' "$(tsk show deck-alpha --full | awk '/^  state:/ {print $2}')"
printf '   a task named by the payload key -> %s\n' \
  "$(tsk show "$PAY_KEY" --full >/dev/null 2>&1 && echo 'PRESENT (unexpected)' || echo 'never created')"
printf '   saved verdict journaled: closed=%s skipped=%s\n' \
  "$(awk -F '\t' '$1 == "saved" { print $4 }' "$HOME_DIR/state/procevent/$SID.receipts")" \
  "$(awk -F '\t' '$1 == "saved" { print $5 }' "$HOME_DIR/state/procevent/$SID.receipts")"

FM_HOME="$HOME_DIR" "$RUNNER" sweep-home >/dev/null 2>&1 || true
rm -rf "$E"
