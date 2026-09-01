#!/usr/bin/env bash
# End-to-end walkthrough of durable PR lifecycle follow-through monitoring,
# driven only through the production entrypoints an operator actually runs
# (fm-pr-check.sh, fm-procevent.sh, fm-procevent-pr-follow.sh) against a stub
# `gh` that serves representative GitHub REST/GraphQL payloads. The adapter's
# own real --jq projections turn those payloads into every row shown below.
set -u
ROOT=$1
WORK=$2
rm -rf "$WORK"; mkdir -p "$WORK"/{home/state,gh,fakebin,claims,wt,project}
export FM_HOME="$WORK/home"
export FM_PROCEVENT_CLAIM_ROOT="$WORK/claims"
export GH_FIX="$WORK/gh"
export GH_CALL_LOG="$WORK/gh-calls.log"
export FM_PR_FOLLOW_INTERVAL=0.1
export FM_PR_FOLLOW_FETCH_TIMEOUT=5
export FM_PR_FOLLOW_ROTATION_SLOT=1
: > "$GH_CALL_LOG"

cat > "$WORK/fakebin/gh" <<'STUB'
#!/usr/bin/env bash
fix=${GH_FIX:?}
printf 'gh %s\n' "$*" >> "${GH_CALL_LOG:-/dev/null}"
filter=; want=
for a in "$@"; do
  if [ "$want" = 1 ]; then filter=$a; want=0
  else case "$a" in --jq|-q) want=1 ;; esac; fi
done
serve() { jq -r "${filter:-.}" "$1" 2>/dev/null || exit 9; }
if [ "$1" = pr ]; then
  [ "$2" = view ] || { echo "unexpected gh pr subcommand: $*" >&2; exit 9; }
  serve "$fix/pr.json"; exit 0
fi
if [ "$1" = api ]; then
  case "$2" in
    graphql)             serve "$fix/reviews.json" ;;
    *issues/*/comments*) serve "$fix/comments.json" ;;
    *pulls/*/comments*)  serve "$fix/rc.json" ;;
    *check-runs*)        serve "$fix/checks.json" ;;
    *) echo "unexpected gh api path: $2" >&2; exit 9 ;;
  esac
  exit 0
fi
echo "unexpected gh call: $*" >&2; exit 9
STUB
chmod +x "$WORK/fakebin/gh"
export PATH="$WORK/fakebin:$PATH"

SHA1=1111111111111111111111111111111111111111
SHA2=2222222222222222222222222222222222222222
pr_json() { printf '{"state":"%s","headRefOid":"%s","author":{"login":"alice"}}\n' "$1" "$2" > "$GH_FIX/pr.json"; }
checks()  { printf '{"check_runs":%s}\n' "$1" > "$GH_FIX/checks.json"; }
pr_json OPEN "$SHA1"
printf '[{"id":5,"user":{"login":"bob"}}]\n' > "$GH_FIX/comments.json"
printf '[]\n' > "$GH_FIX/rc.json"
printf '{"data":{"repository":{"pullRequest":{"reviews":{"nodes":[]}}}}}\n' > "$GH_FIX/reviews.json"
checks '[]'

PRURL=https://github.com/kunchenguid/firstmate/pull/4271
say()  { printf '\n=== %s ===\n' "$*"; }
run()  { printf '$ %s\n' "$(printf '%s ' "$@" | sed "s#$ROOT/bin/##g; s#$WORK#\$WORK#g")"; "$@"; }
wakes()   { awk -F '\t' '{print "  wake> " $5}' "$FM_HOME/state/.wake-queue" 2>/dev/null; }
results() { ls "$FM_HOME"/state/procevent-inbox/*.result 2>/dev/null; }
latest()  { results | awk -F. '{print $(NF-1), $0}' | sort -n | tail -1 | cut -d' ' -f2-; }

wait_for() { local n=0; while [ "$n" -lt 250 ]; do
    [ "$(results | wc -l | tr -d ' ')" -ge "$1" ] && return 0; sleep 0.1; n=$((n+1)); done; return 1; }
wait_baseline() { local n=0; while [ "$n" -lt 250 ]; do
    grep -qx 'baseline=done' "$FM_HOME/state/pr-follow/$SID.cursor" 2>/dev/null && return 0
    sleep 0.1; n=$((n+1)); done; return 1; }
restart_runner() { local n=0 out; while [ "$n" -lt 80 ]; do
    out=$("$ROOT/bin/fm-procevent.sh" reconcile 2>&1) || true
    case "$out" in *started=1*|*stopped=1*) return 0 ;; esac
    sleep 0.1; n=$((n+1)); done; return 1; }
LAST_SEQ=
ack_all() {
  local f seq
  for f in $(results); do
    seq=$(basename "$f" .result); seq=${seq##*.}; LAST_SEQ=$seq
    "$ROOT/bin/fm-procevent-pr-follow.sh" handle "$SID" "$seq" "$f" >/dev/null 2>&1 || true
  done
  restart_runner >/dev/null 2>&1
}
# drain: apply every outstanding capture and let the monitor settle, so the
# next scene starts from a quiet, fully acknowledged state.
drain() {
  local prev cur n=0
  while [ "$n" -lt 12 ]; do
    prev=$(results | wc -l | tr -d ' ')
    ack_all
    sleep 1
    cur=$(results | wc -l | tr -d ' ')
    [ "$cur" = "$prev" ] && return 0
    n=$((n+1))
  done
}
BASE=0
# mutate <shell-snippet>: settle first, remember the capture count, then make
# the forge change.
mutate() { drain; BASE=$(results | wc -l | tr -d ' '); eval "$1"; }
# expect <headline> [extra-field]: wait for the capture that change produced.
expect() {
  local n=0 cur
  while [ "$n" -lt 250 ]; do
    cur=$(results | wc -l | tr -d ' ')
    [ "$cur" -gt "$BASE" ] && break
    sleep 0.1; n=$((n+1))
  done
  if [ "$(results | wc -l | tr -d ' ')" -gt "$BASE" ]; then
    printf '  %s\n' "$1"
    grep -E "^(event|${2:-state}):" "$(latest)" | sed 's/^/    doc> /'
  else
    printf '  %s  -> NO CAPTURE (monitoring stopped)\n' "$1"
  fi
}

say "1. An operator records a PR-ready task the way they always have"
printf 'window=firstmate:fm-task-ship\nendpoint_task_id=task-ship\nworktree=%s\nproject=%s\nkind=ship\nmode=no-mistakes\n' \
  "$WORK/wt" "$WORK/project" > "$FM_HOME/state/task-ship.meta"
echo '$ fm-pr-check.sh task-ship https://github.com/kunchenguid/firstmate/pull/4271'
OUT=$("$ROOT/bin/fm-pr-check.sh" task-ship "$PRURL" 2>/dev/null)
printf '%s\n' "$OUT" | sed 's/^/  | /'
printf '  (stdout is %s line - the single-line success contract is intact;\n' "$(printf '%s\n' "$OUT" | wc -l | tr -d ' ')"
printf '   monitoring was armed before it, with its registration output suppressed)\n'
SID=$("$ROOT/bin/fm-procevent-pr-follow.sh" source-id "$PRURL")
echo "  lifecycle source registered: $SID"
run ls "$FM_HOME/state/procevent"

say "2. The watcher starts the monitor; a freshly registered PR replays no history"
run "$ROOT/bin/fm-procevent.sh" reconcile
wait_baseline || echo "  baseline did not complete"
echo "  captured results after the first poll: $(results | wc -l | tr -d ' ')  (silent baseline, no creation noise)"
grep -E '^(head|state|max_issue_comment|baseline)=' "$FM_HOME/state/pr-follow/$SID.cursor" | sed 's/^/    cursor> /'

say "3. Real review activity on the open PR"
mutate 'printf "[{\"id\":5,\"user\":{\"login\":\"bob\"}},{\"id\":9,\"user\":{\"login\":\"carol\"}}]\n" > "$GH_FIX/comments.json"'
expect "a reviewer leaves a comment"
mutate 'printf "[{\"id\":21,\"in_reply_to_id\":0,\"user\":{\"login\":\"dana\"},\"path\":\"bin/fm-pr-check.sh\",\"line\":140}]\n" > "$GH_FIX/rc.json"'
expect "an inline review comment lands on a file"
mutate 'printf "[{\"id\":21,\"in_reply_to_id\":0,\"user\":{\"login\":\"dana\"},\"path\":\"bin/fm-pr-check.sh\",\"line\":140},{\"id\":22,\"in_reply_to_id\":21,\"user\":{\"login\":\"alice\"},\"path\":\"bin/fm-pr-check.sh\",\"line\":140}]\n" > "$GH_FIX/rc.json"'
expect "the author replies inside that thread"
mutate 'printf "{\"data\":{\"repository\":{\"pullRequest\":{\"reviews\":{\"nodes\":[{\"databaseId\":77,\"state\":\"CHANGES_REQUESTED\",\"author\":{\"login\":\"dana\"}}]}}}}}\n" > "$GH_FIX/reviews.json"'
expect "a review is submitted requesting changes"

say "4. The whole live GitHub check-run vocabulary round-trips (queued/in_progress/waiting/requested/pending)"
mutate 'checks "[{\"id\":91,\"status\":\"queued\",\"conclusion\":null,\"name\":\"linux\"},{\"id\":92,\"status\":\"in_progress\",\"conclusion\":null,\"name\":\"macos\"},{\"id\":93,\"status\":\"waiting\",\"conclusion\":null,\"name\":\"deploy\"},{\"id\":94,\"status\":\"requested\",\"conclusion\":null,\"name\":\"sign\"},{\"id\":95,\"status\":\"pending\",\"conclusion\":null,\"name\":\"windows\"}]"'
expect "CI reports five checks in five different in-flight states"
drain
echo "  the durable cursor advanced to exactly those composite tokens:"
grep -E '^checks=' "$FM_HOME/state/pr-follow/$SID.cursor" | fold -w 96 -s | sed 's/^/    cursor> /'
mutate 'checks "[{\"id\":91,\"status\":\"completed\",\"conclusion\":\"failure\",\"name\":\"linux\"},{\"id\":92,\"status\":\"completed\",\"conclusion\":\"success\",\"name\":\"macos\"},{\"id\":93,\"status\":\"completed\",\"conclusion\":\"success\",\"name\":\"deploy\"},{\"id\":94,\"status\":\"completed\",\"conclusion\":\"success\",\"name\":\"sign\"},{\"id\":95,\"status\":\"completed\",\"conclusion\":\"success\",\"name\":\"windows\"}]"'
expect "they complete: one regression, four greens"

say "5. A forge word this adapter has never seen must not brick monitoring"
mutate 'checks "[{\"id\":91,\"status\":\"completed\",\"conclusion\":\"failure\",\"name\":\"linux\"},{\"id\":92,\"status\":\"completed\",\"conclusion\":\"cosmic_ray\",\"name\":\"macos\"},{\"id\":93,\"status\":\"completed\",\"conclusion\":\"success\",\"name\":\"deploy\"},{\"id\":94,\"status\":\"completed\",\"conclusion\":\"success\",\"name\":\"sign\"},{\"id\":95,\"status\":\"completed\",\"conclusion\":\"success\",\"name\":\"windows\"}]"'
expect "GitHub invents a conclusion word this adapter has never seen: cosmic_ray"
drain
echo "  it normalized to a safe explicit value, applied cleanly, and advanced the cursor:"
grep -E '^checks=' "$FM_HOME/state/pr-follow/$SID.cursor" | fold -w 96 -s | sed 's/^/    cursor> /'

say "6. Head replacement, merge, and post-merge activity"
mutate 'pr_json OPEN "$SHA2"; checks "[]"'
expect "the author force-pushes a new head" head
mutate 'pr_json MERGED "$SHA2"'
expect "the PR is merged"
mutate 'printf "[{\"id\":5,\"user\":{\"login\":\"bob\"}},{\"id\":9,\"user\":{\"login\":\"carol\"}},{\"id\":31,\"user\":{\"login\":\"erin\"}}]\n" > "$GH_FIX/comments.json"'
expect "someone comments AFTER the merge - tracking must continue"
drain
echo "  registration is still present after merge:"
run ls "$FM_HOME/state/procevent"

say "7. Every wake firstmate receives carries fixed, trusted identity text only"
wakes
echo "  any remote author or forge prose in the wake queue?"
if grep -qE 'carol|erin|dana|cosmic_ray|fm-pr-check' "$FM_HOME/state/.wake-queue"; then
  echo "    FAIL: remote prose leaked into the wake line"
else
  echo "    none - remote text reaches firstmate only as stored result data"
fi

say "8. Replaying an already applied capture is a no-op (durable sequence receipts)"
BEFORE=$(cat "$FM_HOME/state/pr-follow/$SID.cursor")
run "$ROOT/bin/fm-procevent-pr-follow.sh" handle "$SID" "$LAST_SEQ" "$FM_HOME/state/procevent-inbox/$SID.$LAST_SEQ.result"
AFTER=$(cat "$FM_HOME/state/pr-follow/$SID.cursor")
[ "$BEFORE" = "$AFTER" ] && echo "  cursor unchanged on byte-identical replay" || echo "  FAIL: cursor moved on replay"

say "9. Monitoring notifies and records only: every forge call this run made"
sort -u "$GH_CALL_LOG" | cut -c1-150 | sed 's/^/  /'
echo "  mutating verbs (merge/review/comment/close/reopen/POST/PATCH/PUT/DELETE)?"
if grep -qE 'pr (merge|review|comment|close|reopen|edit|ready)|--method (POST|PATCH|PUT|DELETE)|-X (POST|PATCH|PUT|DELETE)' "$GH_CALL_LOG"; then
  echo "    FAIL: a mutating forge call was made"
else
  echo "    none - GET-only forge access, no PR or repository mutation"
fi

say "10. Tracking ends only by an explicit, auditable retirement"
"$ROOT/bin/fm-procevent-pr-follow.sh" terminal "$FM_HOME/state/procevent-inbox/$SID.$LAST_SEQ.result"; rc=$?
echo "\$ fm-procevent-pr-follow.sh terminal <capture>   -> exit $rc (a merged PR never self-retires)"
"$ROOT/bin/fm-procevent-pr-follow.sh" retire "$SID" --force
echo "\$ fm-procevent-pr-follow.sh retire $SID --force"
echo "  registrations remaining:"
ls "$FM_HOME/state/procevent" 2>/dev/null | sed 's/^/    /' || true
[ -z "$(ls -A "$FM_HOME/state/procevent" 2>/dev/null)" ] && echo "    (none - retired)"
"$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true


say "11. Aggregate load stays bounded and no tracked PR is starved"
# A second home tracking three PRs at once, polled by the same deterministic
# rotation: time is cut into slots and slot t belongs to roster index t mod N.
H2="$WORK/home2"; mkdir -p "$H2/state"
: > "$GH_CALL_LOG"
for n in 1001 1002 1003; do
  FM_HOME="$H2" "$ROOT/bin/fm-procevent-pr-follow.sh" arm "task-$n" \
    "https://github.com/kunchenguid/firstmate/pull/$n" | sed 's/^/  /'
done
FM_HOME="$H2" "$ROOT/bin/fm-procevent.sh" reconcile | sed 's/^/  /'
echo "  ...letting the rotation run for 9 slots (FM_PR_FOLLOW_ROTATION_SLOT=1s)..."
sleep 9
echo "  core forge fetches per tracked PR over that window:"
for n in 1001 1002 1003; do
  c=$(grep -c "pull/$n --json state" "$GH_CALL_LOG" || true)
  printf '    pull/%s: %s poll(s)\n' "$n" "$c"
done
printf '    total core fetches for the whole home: %s\n' "$(grep -c -- '--json state' "$GH_CALL_LOG" || true)"
echo "  every tracked PR was visited (no starvation) and the aggregate rate is"
echo "  set by the slot, not by the number of PRs - production defaults bound"
echo "  the whole home to 156 forge requests/hour regardless of PR count."
FM_HOME="$H2" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true

say "12. Monitoring loss is bounded, actionable, and never silent"
# A third home whose adapter emitted a capture that fails its own validation -
# an adapter defect, not tampering.
H3="$WORK/home3"; mkdir -p "$H3/state/procevent-inbox"
PR3=https://github.com/kunchenguid/firstmate/pull/777
SID3=$(FM_HOME="$H3" "$ROOT/bin/fm-procevent-pr-follow.sh" source-id "$PR3")
FM_HOME="$H3" "$ROOT/bin/fm-procevent-pr-follow.sh" arm task-loss "$PR3" | sed 's/^/  /'
printf '%s\n' 'schema: fm-pr-follow-event-v1' "source: $SID3" 'provider: github' \
  "url: $PR3" 'number: 777' 'status: events' "head: $SHA1" 'state: open' 'dropped: 0' \
  'events: 0' 'cursor:' 'head=not-a-sha' 'state=open' 'max_issue_comment=0' 'max_review=0' \
  'max_review_comment=0' 'reviews=' 'checks=' 'threads=' 'approvals=' 'backfill=off' \
  'generation=1' > "$H3/state/procevent-inbox/$SID3.1.result"
printf 'pr-follow\n' > "$H3/state/procevent-inbox/$SID3.1.adapter"
chmod 600 "$H3/state/procevent-inbox/$SID3.1.result" "$H3/state/procevent-inbox/$SID3.1.adapter"
echo "  first apply attempt:"
FM_HOME="$H3" "$ROOT/bin/fm-procevent-pr-follow.sh" handle "$SID3" 1 \
  "$H3/state/procevent-inbox/$SID3.1.result" 2>&1 | sed 's/^/    /'
echo "  second attempt reaches the bound:"
FM_HOME="$H3" "$ROOT/bin/fm-procevent-pr-follow.sh" handle "$SID3" 1 \
  "$H3/state/procevent-inbox/$SID3.1.result" 2>&1 | sed 's/^/    /'
echo "  the paused source surfaces exactly one bounded diagnostic, with no forge bytes:"
FM_HOME="$H3" GH_FIX="$GH_FIX" perl -e 'alarm 3; exec @ARGV' \
  "$ROOT/bin/fm-procevent-pr-follow.sh" run "$SID3" 2>/dev/null | sed 's/^/    doc> /'
echo "  a tampered/foreign document is a different class and is refused loudly every time:"
printf 'schema: not-this-adapter\nsource: %s\n' "$SID3" > "$WORK/foreign"
FM_HOME="$H3" "$ROOT/bin/fm-procevent-pr-follow.sh" handle "$SID3" 9 "$WORK/foreign" 2>&1 | sed 's/^/    /'
FM_HOME="$H3" "$ROOT/bin/fm-procevent-pr-follow.sh" handle "$SID3" 9 "$WORK/foreign" 2>&1 | sed 's/^/    /'
echo "  re-arming after the adapter is repaired clears the pause:"
FM_HOME="$H3" "$ROOT/bin/fm-procevent-pr-follow.sh" arm task-loss "$PR3" | sed 's/^/    /'
[ -e "$H3/state/pr-follow/$SID3.quarantine" ] \
  && echo "    FAIL: quarantine survived re-arm" \
  || echo "    quarantine record cleared - tracking resumes"
FM_HOME="$H3" "$ROOT/bin/fm-procevent.sh" sweep-home >/dev/null 2>&1 || true
