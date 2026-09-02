#!/usr/bin/env bash
# End-to-end demonstration of the Lavish answer-receipt lifecycle as the captain
# experiences it: the visible text the adapter prints into the review page via
# the published poll's --agent-reply surface, after each real submission round.
# Drives bin/fm-procevent-lavish.sh directly - no stubs of the adapter itself.
set -u
ROOT=${1:?repo root}
DEMO_ROOT=$(mktemp -d "${TMPDIR:-/tmp}/fm-receipt-demo.XXXXXX")
trap 'rm -rf "$DEMO_ROOT"' EXIT
HOME_DIR="$DEMO_ROOT/home"
mkdir -p "$HOME_DIR/data" "$HOME_DIR/state" "$HOME_DIR/config" "$HOME_DIR/projects"
cp "$ROOT/.tasks.toml" "$HOME_DIR/.tasks.toml"
printf '## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"

lav() {
  FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" \
    FM_PROCEVENT_CLAIM_ROOT="$HOME_DIR/procevent-claims" \
    "$ROOT/bin/fm-procevent-lavish.sh" "$@"
}
result() {  # <path> <declared-rows> <rows>
  { printf 'session:\n  file: /review.html\n  status: feedback\n'
    printf 'prompts[%s]{uid,prompt,selector,tag,text}:\n' "$2"
    printf '%s\n' "$3"; } > "$1"
}
choice_row() {  # <uid> <key> <answer> <label>
  printf '  "%s","%s: %s\\n\\nContext data:\\n{\\n  \\"question\\": \\"%s\\", \\"answer\\": \\"%s\\"\\n}",section > form,choice,"%s: %s"\n' \
    "$1" "$4" "$3" "$2" "$3" "$4" "$3"
}
message_row() { printf '  "","%s","","message","Freeform message"\n' "$1"; }
show() { printf '\n----- what the captain sees in the review page -----\n'; lav receipt-text "$SID"; printf '\n'; printf -- '---------------------------------------------------\n'; }

ART="$DEMO_ROOT/design-review.html"
printf '<h1>Design review</h1>\n' > "$ART"
SID=$(lav source-id "$ART")
printf '# Lavish answer-receipt lifecycle - end-to-end captain view\n'
printf 'artifact : %s\nsource   : %s\n' "$ART" "$SID"

printf '\n## Round 1 - the captain answers one question and adds a message\n'
result "$DEMO_ROOT/r1" 2 "$(choice_row 2 ship-now yes 'Ship the receipt lifecycle now?')
$(message_row 'Please also close the follow-up task.')"
printf 'fed 0\nclosed: ship-now\n' > "$DEMO_ROOT/o1"
lav receipt "$SID" 1 "$DEMO_ROOT/r1" "$DEMO_ROOT/o1" >/dev/null
show

printf '\n## The handler starts routing that round, then finishes it\n'
mkdir -p "$HOME_DIR/state/procevent-inbox"
cp "$DEMO_ROOT/r1" "$HOME_DIR/state/procevent-inbox/$SID.1.result"; chmod 0600 "$HOME_DIR/state/procevent-inbox/$SID.1.result"
lav applying "$SID" 1 >/dev/null
show
lav complete "$SID" 1 >/dev/null
show

printf '\n## Round 2 - a comment-only submission (no answers at all)\n'
printf '   Before this change this round displayed no receipt whatsoever.\n'
result "$DEMO_ROOT/r2" 1 "$(message_row 'The footer spacing is still off on mobile.')"
printf 'not-fed\n' > "$DEMO_ROOT/o2"
lav receipt "$SID" 2 "$DEMO_ROOT/r2" "$DEMO_ROOT/o2" >/dev/null
show

printf '\n## Round 3 - the captain resubmits round 1 unchanged; nothing new happened\n'
printf 'fed 0\n' > "$DEMO_ROOT/o3"
lav receipt "$SID" 3 "$DEMO_ROOT/r1" "$DEMO_ROOT/o3" >/dev/null
show

printf '\n## Round 4 - the answer extractor failed; no verified save is claimed\n'
result "$DEMO_ROOT/r4" 1 "$(choice_row 7 hold-release go 'Release the hold?')"
printf 'fed 0\nincomplete\n' > "$DEMO_ROOT/o4"
lav receipt "$SID" 4 "$DEMO_ROOT/r4" "$DEMO_ROOT/o4" >/dev/null
show

printf '\n## Round 5 - two answers, neither of which named a held task (partial save)\n'
result "$DEMO_ROOT/r5p" 2 "$(choice_row 11 pick-a yes 'Pick A?')
$(choice_row 12 pick-b no 'Pick B?')"
printf 'fed 0\nskipped: pick-a names no held task\nskipped: pick-b names no held task\n' > "$DEMO_ROOT/o5p"
lav receipt "$SID" 5 "$DEMO_ROOT/r5p" "$DEMO_ROOT/o5p" >/dev/null
show

printf '\n## Round 6 - a prompt block declaring 3 rows but delivering 1 (truncated in transit)\n'
printf '   A refused parse is no verdict: nothing is journaled, nothing is acknowledged.\n'
result "$DEMO_ROOT/r5" 3 "$(choice_row 9 truncated go 'Truncated')"
lav receipt "$SID" 6 "$DEMO_ROOT/r5" "$DEMO_ROOT/o3" >/dev/null
show

printf '\n## The receipts record itself (durable journal behind every line above)\n'
printf 'mode: %s\n' "$(ls -l "$HOME_DIR/state/procevent/$SID.receipts" | awk '{print $1}')"
awk -F '\t' '{ line=$1; for (i=2; i<=NF; i++) line = line " | " $i; print line }' \
  "$HOME_DIR/state/procevent/$SID.receipts"
