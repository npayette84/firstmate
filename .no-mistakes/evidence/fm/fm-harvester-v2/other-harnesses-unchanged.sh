#!/usr/bin/env bash
# Spot-check that the harnesses this change did NOT touch still fall through to
# source=unavailable with null token fields, even with the real Pi log tree in
# reach and a worktree that a real Pi session recorded.
set -eu
WT_REPO=${WT_REPO:?}
S=$(mktemp -d "${TMPDIR:-/tmp}/fm-other-harness.XXXXXX"); trap 'rm -rf "$S"' EXIT
CWD=/Users/npayette/.treehouse/firstmate-e5afef/3/firstmate
stamp() { date -r "$1" +%Y%m%d%H%M.%S 2>/dev/null || date -d "@$1" +%Y%m%d%H%M.%S; }
for h in opencode grok kimi cursor muse pi; do
  mkdir -p "$S/$h/state" "$S/$h/data"
  printf 'worktree=%s\nharness=%s\nmodel=default\neffort=default\nspawn_gen=s1788150000.1.a\n' \
    "$CWD" "$h" > "$S/$h/state/t-$h.meta"
  printf 'working: a\ndone: b\n' > "$S/$h/state/t-$h.status"
  touch -t "$(stamp 1788186000)" "$S/$h/state/t-$h.status" "$S/$h/state/t-$h.meta"
  FM_STATE_OVERRIDE="$S/$h/state" FM_DATA_OVERRIDE="$S/$h/data" \
    FM_USAGE_PI_DIR="$HOME/.pi/agent/sessions" \
    "$WT_REPO/bin/fm-usage-harvest.sh" "t-$h"
  jq -c '{harness,input_tokens,cached_input_tokens,output_tokens,reasoning_tokens,source}' \
    "$S/$h/data/usage-ledger.jsonl"
done
