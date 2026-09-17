#!/usr/bin/env bash
# End-to-end demonstration of the adversarial-review gate on a Firstmate-raised
# PR, driven through the real bin/ scripts against a simulated forge.
#
# The simulated forge is a directory: gh-axi writes each `pr comment` body into
# forge/comments/<pr-number>/ and each `pr edit --body-file` into
# forge/body-<pr-number>.md, so the files this script leaves behind under forge/
# are exactly the markdown a human would read in the pull request.
#
# Usage: e2e-adversarial-review-gate.sh <output-dir>
set -eu

OUT=${1:?output dir}
FM_SRC=${FM_SRC:?path to the firstmate worktree}
rm -rf "$OUT/run"
HOME_DIR="$OUT/run/home"
FORGE="$OUT/run/forge"
FAKEBIN="$OUT/run/fakebin"
STATE="$HOME_DIR/state"
mkdir -p "$STATE" "$HOME_DIR/data" "$HOME_DIR/config" "$FORGE/comments" "$FAKEBIN"
PR_URL=https://github.com/example/repo/pull/9
ID=task-ui1
PR_URL2=https://github.com/example/repo/pull/10
ID2=task-fix2
WATCH=when-adversarial-review-pr

say() { printf '\n=== %s\n' "$*"; }
run() { printf '$ %s\n' "$*"; "$@"; }

# --- the lane worktree: a real repo with a real UI-facing change -------------
WT="$OUT/run/wt"
mkdir -p "$WT"
git -C "$WT" init -q
git -C "$WT" config user.name fmtest
git -C "$WT" config user.email fmtest@example.invalid
printf 'export const Button = () => null\n' > "$WT/button.tsx"
git -C "$WT" add -A
git -C "$WT" commit -q -m 'seed the app'
BASE=$(git -C "$WT" rev-parse HEAD)
printf 'export const Banner = ({ text }) => <div class="banner">{text}</div>\n' \
  > "$WT/banner.tsx"
printf '{"lock": 1}\n' > "$WT/package-lock.json"
git -C "$WT" add -A
git -C "$WT" commit -q -m 'add the launch banner'
HEAD_SHA=$(git -C "$WT" rev-parse HEAD)

# --- the simulated forge ----------------------------------------------------
printf '%s\n' "$HEAD_SHA" > "$FORGE/head"
printf '%s\n' "$BASE" > "$FORGE/base"
printf 'Add the launch banner\n' > "$FORGE/title"
printf 'Adds a dismissible launch banner to the marketing shell.\n' > "$FORGE/body-orig"
cat > "$FORGE/view.json" <<JSON
{"state":"OPEN","isDraft":false,"mergeable":"MERGEABLE","mergeStateStatus":"CLEAN","headRefOid":"$HEAD_SHA","baseRefName":"main","statusCheckRollup":[{"__typename":"CheckRun","name":"ci","status":"COMPLETED","conclusion":"SUCCESS"}]}
JSON
printf '%s\n' 'state=MERGED' 'merged=true' 'queued=false' 'base=main' > "$FORGE/outcome"
: > "$FORGE/rules"

cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FORGE/gh.log"
case "${1:-} ${2:-}" in
  "pr view")
    case " $* " in
      *statusCheckRollup*) cat "$FM_FORGE/view.json"; exit 0 ;;
      *headRefOid*) cat "$FM_FORGE/head"; exit 0 ;;
      *baseRefOid*) cat "$FM_FORGE/base"; exit 0 ;;
      *--json\ title*) cat "$FM_FORGE/title"; exit 0 ;;
      *--json\ body*)
        if [ -f "$FM_FORGE/body-$3.md" ]; then cat "$FM_FORGE/body-$3.md"; else cat "$FM_FORGE/body-orig"; fi
        exit 0 ;;
    esac
    exit 1 ;;
  "pr merge") printf 'merged:\n  number: %s\n  status: ok\n' "${3:-}"; exit 0 ;;
  "api graphql") cat "$FM_FORGE/outcome"; exit 0 ;;
  api\ *) cat "$FM_FORGE/rules"; exit 0 ;;
esac
exit 0
SH

# gh-axi is the mutation half: it persists what would be posted into the PR.
cat > "$FAKEBIN/gh-axi" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FORGE/gh-axi.log"
verb="${1:-} ${2:-}"
body=
prev=
for a in "$@"; do
  [ "$prev" = --body-file ] && body=$a
  prev=$a
done
case "$verb" in
  "pr comment")
    mkdir -p "$FM_FORGE/comments/$3"
    n=$(( $(ls "$FM_FORGE/comments/$3" | wc -l) + 1 ))
    cp "$body" "$FM_FORGE/comments/$3/$(printf '%02d' "$n").md"
    ;;
  "pr edit") cp "$body" "$FM_FORGE/body-$3.md" ;;
  "pr view") printf 'pull_request:\n  number: %s\n  state: merged\n' "${3:-}" ;;
esac
exit 0
SH
chmod +x "$FAKEBIN/gh" "$FAKEBIN/gh-axi"

# --- the lane's task state, as bin/fm-spawn.sh writes it --------------------
cp "$FM_SRC/.tasks.toml" "$HOME_DIR/.tasks.toml" 2>/dev/null || true
printf '%s\n' '## In flight' '' '## Queued' '' '## Done' > "$HOME_DIR/data/backlog.md"
{
  printf 'window=fm-%s\n' "$ID"
  printf 'worktree=%s\n' "$WT"
  printf 'project=%s\n' "$WT"
  printf 'kind=ship\n'
  printf 'mode=no-mistakes\n'
  printf 'harness=claude\n'
  printf 'model=default\n'
} > "$STATE/$ID.meta"

adv() {
  FM_STATE_OVERRIDE="$STATE" FM_HOME="$HOME_DIR" FM_FORGE="$FORGE" \
  FM_PROCEVENT_CLAIM_ROOT="$HOME_DIR/claims" \
  PATH="$FAKEBIN:$PATH" "$FM_SRC/bin/fm-adversarial-review.sh" "$@"
}
merge() {
  FM_ROOT_OVERRIDE="$FM_SRC" FM_HOME="$HOME_DIR" FM_STATE_OVERRIDE="$STATE" \
  FM_FORGE="$FORGE" HOME="$OUT/run/user-home" \
  FM_TEST_GH_AXI_LOG="$FORGE/gh-axi.log" FM_TEST_GH_LOG="$FORGE/gh.log" \
  PATH="$FAKEBIN:$PATH" "$FM_SRC/bin/fm-pr-merge.sh" "$@"
}

lens_report() {  # <file> <verdict> <findings-block>
  { printf 'verdict: %s\nboundary_class: merge\nfindings:\n' "$2"
    printf '%s' "$3"
    printf 'blind_spots: none seen\n'; } > "$1"
}

say "STEP 1  the lane opens its PR: a PR-open status line appears"
printf 'working: building the banner\n' > "$STATE/$ID.status"
printf 'done: PR %s\n' "$PR_URL" >> "$STATE/$ID.status"
run adv condition && echo "-> condition TRUE: this PR still owes an adversarial-review loop"

say "STEP 2  the PR-open watch bin/fm-bootstrap.sh and bin/fm-pr-check.sh arm"
# This is exactly the call those two entrypoints make; nothing here is a
# test-only shortcut around it.
run adv ensure-watch --interval 0.1 --stable 1
echo "-> watch registered: $(ls "$STATE/procevent/$WATCH.source" >/dev/null 2>&1 && echo yes || echo no)"
procevent() {
  PATH="$FAKEBIN:$PATH" FM_HOME="$HOME_DIR" FM_FORGE="$FORGE" \
    FM_PROCEVENT_CLAIM_ROOT="$HOME_DIR/claims" \
    "$FM_SRC/bin/fm-procevent.sh" "$@"
}
: > "$OUT/run/seen-outcomes"
await_fire() {
  local r= f
  for _ in $(seq 1 300); do
    for f in "$HOME_DIR"/state/procevent-inbox/$WATCH.*.result; do
      [ -e "$f" ] || continue
      grep -qxF "$f" "$OUT/run/seen-outcomes" && continue
      r=$f; break
    done
    [ -n "$r" ] && break
    sleep 0.1
  done
  [ -n "$r" ] || { echo "the watch never produced a new outcome"; exit 1; }
  printf '%s\n' "$r" >> "$OUT/run/seen-outcomes"
  echo "--- watch outcome ---"
  cat "$r"
}
procevent reconcile >/dev/null
await_fire

say "STEP 2b  the watch fires once, so ensure-watch re-arms it for the NEXT PR"
for _ in $(seq 1 100); do [ -e "$STATE/procevent/$WATCH.source" ] || break; sleep 0.1; done
echo "-> registration after the fire: $([ -e "$STATE/procevent/$WATCH.source" ] && echo present || echo 'dropped by the runner')"
{
  printf 'window=fm-%s\n' "$ID2"; printf 'worktree=%s\n' "$WT"
  printf 'kind=ship\n'; printf 'harness=claude\n'; printf 'model=default\n'
} > "$STATE/$ID2.meta"
run adv ensure-watch --interval 0.1 --stable 1
echo "-> registration after ensure-watch: $([ -e "$STATE/procevent/$WATCH.source" ] && echo present || echo missing)"
procevent reconcile >/dev/null
printf 'done: PR %s\n' "$PR_URL2" > "$STATE/$ID2.status"
await_fire
echo "-> second PR staged its own round 1: $([ -f "$STATE/$ID2.adversarial-review/round-1/diff.patch" ] && echo yes || echo no)"
procevent retire "$WATCH" >/dev/null 2>&1 || true
procevent sweep-home >/dev/null 2>&1 || true

say "STEP 3  what the automatic dispatch staged for the reviewers"
R1="$STATE/$ID.adversarial-review/round-1"
ls "$R1"
echo "--- round-1/meta (tier derived from the change, not chosen by the caller) ---"
cat "$R1/meta"
echo "--- staged diff excludes generated files (package-lock.json) ---"
grep -E '^(diff --git|\+\+\+)' "$R1/diff.patch"

say "STEP 4  merge is attempted with no loop-green evidence"
set +e
merge "$ID" "$PR_URL" > "$OUT/run/merge-ungreen.out" 2> "$OUT/run/merge-ungreen.err"
echo "exit=$?"
set -e
cat "$OUT/run/merge-ungreen.err"
echo "-> merge poll armed? $([ -f "$STATE/$ID.check.sh" ] && echo yes || echo 'no - refused before arming')"
echo "-> gh pr merge invoked? $(grep -c '^pr merge' "$FORGE/gh.log" || true)"

say "STEP 5  round 1 lens reports come back; one deep BLOCKER, one UI MAJOR"
lens_report "$OUT/run/frontier-1.md" GREEN '  - id: f1
    severity: MINOR
    claim: banner text is not memoized
    evidence: banner.tsx:1
    problem: re-renders on every parent render
    fix: memoize the node
'
lens_report "$OUT/run/deep-1.md" RED '  - id: d1
    severity: BLOCKER
    claim: banner text is interpolated unescaped
    evidence: banner.tsx:1
    problem: caller-supplied text reaches the DOM unescaped
    fix: escape or bind text as a child node
'
# A Design/UX lens reviews markup, so its report quotes markup: a tag, a
# closing tag that would end the collapsible the report is posted in, and a
# fenced snippet of the fix. This is the ordinary shape of a UI report, not a
# hostile input.
lens_report "$OUT/run/design-1.md" RED '  - id: u1
    severity: MAJOR
    claim: banner has no dismiss affordance
    evidence: banner.tsx:1
    problem: <div class="banner">{text}</div> renders edge to edge at 320px with no
      control, and the </details> the docs example pastes below it is caller text
    fix: give the banner a dismiss control, so that
```
<div class="banner"><span>{text}</span><button aria-label="Dismiss">x</button></div>
```
      is what ships
'
run adv record-lens "$ID" --round 1 --lens frontier \
  --report "$OUT/run/frontier-1.md" --seat fable-5.1
run adv record-lens "$ID" --round 1 --lens deep \
  --report "$OUT/run/deep-1.md" --seat opus-5-high
run adv record-lens "$ID" --round 1 --lens advisory:design-ux \
  --report "$OUT/run/design-1.md" --seat astra-high

say "STEP 6  reconcile round 1"
set +e
adv reconcile "$ID" --round 1
echo "exit=$?"
set -e
echo "-> loop-green marker written? $([ -f "$STATE/$ID.adversarial-review-green" ] && echo yes || echo no)"

say "STEP 7  merge is attempted again while the loop is RED"
set +e
merge "$ID" "$PR_URL" > "$OUT/run/merge-red.out" 2> "$OUT/run/merge-red.err"
echo "exit=$?"
set -e
cat "$OUT/run/merge-red.err"

say "STEP 8  the lane fixes both findings and pushes; a new head, so a new round"
printf 'export const Banner = ({ text, onDismiss }) => <div class="banner">{escapeHtml(text)}<button onClick={onDismiss}>x</button></div>\n' \
  > "$WT/banner.tsx"
git -C "$WT" add -A
git -C "$WT" commit -q -m 'escape banner text and add a dismiss control'
HEAD2=$(git -C "$WT" rev-parse HEAD)
printf '%s\n' "$HEAD2" > "$FORGE/head"
sed -i.bak "s/$HEAD_SHA/$HEAD2/" "$FORGE/view.json" && rm -f "$FORGE/view.json.bak"
run adv dispatch "$ID" "$PR_URL" --wt "$WT" --head "$HEAD2" --round 2 \
  --ui-impacting --seat frontier=fable-5.1 --seat deep=opus-5-high \
  --seat advisory:design-ux=astra-high

say "STEP 9  round 2 lenses come back clean, and the round-1 findings are disposed of"
lens_report "$OUT/run/clean.md" GREEN ''
run adv record-lens "$ID" --round 2 --lens frontier --report "$OUT/run/clean.md"
run adv record-lens "$ID" --round 2 --lens deep --report "$OUT/run/clean.md"
run adv record-lens "$ID" --round 2 --lens advisory:design-ux --report "$OUT/run/clean.md"
echo "--- a clean round 2 does NOT close round 1's findings on its own ---"
set +e
adv reconcile "$ID" --round 2
echo "exit=$?"
set -e
echo "-> loop-green marker written? $([ -f "$STATE/$ID.adversarial-review-green" ] && echo yes || echo no)"
run adv resolve "$ID" --round 2 --finding deep:d1 --disposition fixed_verified \
  --note 'text is escaped at the boundary now'
run adv resolve "$ID" --round 2 --finding advisory:design-ux:u1 \
  --disposition fixed_verified --note 'dismiss control added'
run adv resolve "$ID" --round 2 --finding frontier:f1 \
  --disposition rejected_with_counterevidence --note 'MINOR; no reconciliation owed'

say "STEP 10  reconcile round 2 -> GREEN"
adv reconcile "$ID" --round 2
echo "--- the loop-green marker ---"
cat "$STATE/$ID.adversarial-review-green"

say "STEP 11  the merge path now accepts the evidence"
set +e
merge "$ID" "$PR_URL" > "$OUT/run/merge-green.out" 2> "$OUT/run/merge-green.err"
echo "exit=$?"
set -e
cat "$OUT/run/merge-green.out"
sed -n '1,20p' "$OUT/run/merge-green.err"
echo "--- gh merge calls, pinned to the reviewed head ---"
grep '^pr merge' "$FORGE/gh.log" || echo '(none)'

say "STEP 11b  a push after the GREEN round does not ride on the old evidence"
set +e
adv check-green "$ID" "$PR_URL" --head 4c0ffee000000000000000000000000000000abc
echo "exit=$?"
set -e

say "STEP 12  a T0 waiver still needs the captain's own word"
set +e
adv dispatch task-waiver "$PR_URL" --tier T0 --wt "$WT" \
  --waiver-class trivial --waiver-reason 'one-line typo' --waiver-hold task-waiver
echo "exit=$?"
set -e
echo "-> waiver marker written? $([ -f "$STATE/task-waiver.adversarial-review-green" ] && echo yes || echo no)"

say "STEP 13  what the pull requests themselves now show"
echo "comments posted into PR 9:"
ls "$FORGE/comments/9"
echo "PR 9 body section synced: $([ -f "$FORGE/body-9.md" ] && echo yes || echo no)"
echo "comments posted into PR 10 (the second lane, from the re-armed watch):"
ls "$FORGE/comments/10"
echo "PR 10 body section synced: $([ -f "$FORGE/body-10.md" ] && echo yes || echo no)"

say "STEP 14  everything posted into the PR is readable from the PR alone"
# The reader of this PR is on another machine: no path that only resolves on
# the host that ran the loop may appear in anything posted, and each lens
# report must be IN the PR rather than pointed at.
POSTED="$OUT/run/posted-surface.txt"
: > "$POSTED"
for f in "$FORGE"/comments/9/*.md "$FORGE"/body-9.md \
         "$FORGE"/comments/10/*.md "$FORGE"/body-10.md; do
  [ -f "$f" ] || continue
  { printf '=== %s\n' "${f#"$FORGE"/}"; cat "$f"; printf '\n'; } >> "$POSTED"
done
echo "-> host state dir referenced in PR-facing content: $(grep -c -F "$STATE" "$POSTED" || true) occurrence(s)"
echo "-> lane worktree path referenced in PR-facing content: $(grep -c -F "$WT/" "$POSTED" || true) occurrence(s)"
echo "-> any absolute /var or /tmp path referenced: $(grep -cE '(/private)?/(var|tmp)/[A-Za-z0-9._/-]+' "$POSTED" || true) occurrence(s)"
echo "--- what the round comment points the reviewer at instead ---"
grep -n 'Evidence under review' "$FORGE/comments/9/01.md"
echo "--- the lens reports the PR carries inline ---"
grep -n '<summary>lens' "$FORGE"/comments/9/*.md
echo "--- one inlined report, verbatim as the PR shows it ---"
awk '/<summary>lens deep/,/<\/details>/' "$FORGE/comments/9/02.md"

say "STEP 15  a reviewer that cites its own staged files still posts a portable PR comment"
# The reviewer was handed the staged diff and the lane tree BY PATH, so a
# report that cites one is the expected case, not the odd one. The second lane
# (PR 10, round 1 dispatched automatically by the re-armed watch) reports that
# way here.
lens_report "$OUT/run/frontier-2.md" GREEN "  - id: p1
    severity: MINOR
    claim: banner class name is not namespaced
    evidence: $WT/banner.tsx:1
    problem: bare .banner collides, see $STATE/$ID2.adversarial-review/round-1/diff.patch
    fix: namespace the class
"
lens_report "$OUT/run/deep-2.md" GREEN ''
run adv record-lens "$ID2" --round 1 --lens frontier \
  --report "$OUT/run/frontier-2.md" --seat fable-5.1
run adv record-lens "$ID2" --round 1 --lens deep \
  --report "$OUT/run/deep-2.md" --seat opus-5-high
run adv record-lens "$ID2" --round 1 --lens advisory:design-ux \
  --report "$OUT/run/deep-2.md" --seat astra-high
run adv reconcile "$ID2" --round 1
echo "--- what the reviewer wrote, on disk (host paths and all) ---"
grep -E 'evidence:|problem:' "$OUT/run/frontier-2.md"
echo "--- what PR 10 actually carries ---"
grep -E 'evidence:|problem:' "$FORGE"/comments/10/*.md
echo "-> host paths in PR 10 content: $(grep -cE '(/private)?/(var|tmp)/[A-Za-z0-9._/-]+' "$FORGE"/comments/10/*.md | paste -sd, -)"
