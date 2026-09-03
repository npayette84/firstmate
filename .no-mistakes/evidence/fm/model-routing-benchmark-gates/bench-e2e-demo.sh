#!/usr/bin/env bash
# Evidence driver: exercise the real model-routing benchmark gate CLI and the
# real fm-spawn launch boundary end to end, as an operator would.
# Fixture builders are extracted verbatim from tests/fm-bench-gate.test.sh so
# the demonstrated benchmark is the same shape the suite validates.
set -u
ROOT_ARG=$1
. "$ROOT_ARG/tests/lib.sh"
TESTFILE="$ROOT/tests/fm-bench-gate.test.sh"
TMP_ROOT=$(fm_test_tmproot fm-bench-evidence)
LIB="$TMP_ROOT/fixtures.sh"
: > "$LIB"
AWKP="$TMP_ROOT/extract.awk"
cat > "$AWKP" <<'AWKEOF'
$0 ~ "^" fn "\\(\\) \\{" { inside = 1 }
!inside { next }
{ print }
!inhd && $0 ~ /<<-?["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?[[:space:]]*$/ {
  t = $0
  sub(/^.*<<-?/, "", t)
  gsub(/["'"'"'[:space:]]/, "", t)
  term = t; inhd = 1; next
}
inhd && $0 ~ ("^[[:space:]]*" term "[[:space:]]*$") { inhd = 0; next }
!inhd && $0 == "}" { exit }
AWKEOF
for fn in write_plan write_freeze_inputs write_provenance run_gate write_evaluator write_isolation; do
  awk -v fn="$fn" -f "$AWKP" "$TESTFILE" >> "$LIB"
done
GATE="$ROOT/bin/fm-bench-gate.sh"
# shellcheck disable=SC1090
. "$LIB"

# --- the ISO entrant world the isolation gate probes -------------------------
ISO="$TMP_ROOT/iso"
mkdir -p "$ISO/sealed"
printf 'K7 -> Fable 5 High\n' > "$ISO/sealed/key.json"
for entrant in e1 e2; do
  mkdir -p "$ISO/$entrant/objects" "$ISO/$entrant/tmp" "$ISO/$entrant/home" "$ISO/$entrant/session"
  printf 'objects/\ntmp/\nhome/\nsession/\n' > "$ISO/$entrant/.gitignore"
  for private in objects tmp home session; do
    printf 'private %s material for %s\n' "$private" "$entrant" > "$ISO/$entrant/$private/canary.txt"
  done
  fm_git_init_commit "$ISO/$entrant" >/dev/null
  printf 'candidate work %s\n' "$entrant" > "$ISO/$entrant/answer.txt"
  git -C "$ISO/$entrant" add -A
  git -C "$ISO/$entrant" -c user.name=t -c user.email=t@x commit -qm work
  mkdir -p "$ISO/$entrant/.git/worktrees/w"
  git -C "$ISO/$entrant" -c user.name=t -c user.email=t@x commit -qm detached --allow-empty
  git -C "$ISO/$entrant" reset -q --hard HEAD~1
done

BENCH="$TMP_ROOT/bench"
write_plan "$BENCH"
write_provenance "$BENCH" A1 cleared
write_provenance "$BENCH" C1 cleared
write_evaluator "$BENCH"
write_freeze_inputs "$BENCH"
write_isolation "$BENCH" container
cat > "$BENCH/allowance.json" <<'ALLOWANCE'
{"schema":"fm-bench-allowance.v1","providers":{"cursor":{
 "required_runs":12,"reserve_runs":3,"measured_available_runs":20,
 "measured_at":"2026-09-02T09:00:00Z","source":"quota-axi",
 "concurrency_proof":{"tuples":["cursor/composer-2.5","cursor/cursor-grok-4.6-high"],
  "concurrent_sessions":2,"used_benchmark_packet":false,"verified_at":"2026-09-02T09:10:00Z"},
 "full_field_start_proof":{"entrants":5,"verified_at":"2026-09-02T09:20:00Z"}}}}
ALLOWANCE

echo "======================================================================"
echo " 1. An operator tries to launch a benchmark entrant with no clearance"
echo "======================================================================"
SPAWNHOME="$TMP_ROOT/spawnhome"
fm_git_init_commit "$TMP_ROOT/repo" >/dev/null
printf '\n$ bin/fm-spawn.sh --mode local-only --yolo off bench-b1-k7 <repo>\n'
( unset FM_BENCH_ROOT FM_BENCH_LAUNCH_BYPASS
  FM_ROOT_OVERRIDE="$SPAWNHOME" FM_HOME="$SPAWNHOME" FM_STATE_OVERRIDE="$SPAWNHOME/state" \
    "$ROOT/bin/fm-spawn.sh" --mode local-only --yolo off bench-b1-k7 "$TMP_ROOT/repo" 2>&1 )
printf '[exit %s]\n' "$?"

echo
echo "======================================================================"
echo " 2. The captain-stop exit code (3), distinct from an ordinary refusal"
echo "======================================================================"
STOP="$TMP_ROOT/stop-provenance"
write_plan "$STOP"; write_provenance "$STOP" A1 cleared; write_provenance "$STOP" C1 absent
printf '\n$ bin/fm-bench-gate.sh --bench <bench> provenance-check   # both historical packets unclearable\n'
run_gate "$STOP" provenance-check; printf '[exit %s]\n' "$?"
STOP2="$TMP_ROOT/stop-cost"
write_plan "$STOP2" 'plan["approved_cost_class_usd"] = 400.0'
run_gate "$STOP2" manifest-build >/dev/null
printf '\n$ bin/fm-bench-gate.sh --bench <bench> manifest-check   # measured high case above the approved class\n'
run_gate "$STOP2" manifest-check; printf '[exit %s]\n' "$?"

echo
echo "======================================================================"
echo " 3. A complete benchmark clears every gate through preflight"
echo "======================================================================"
printf '\n$ bin/fm-bench-gate.sh --bench <bench> manifest-build\n'
run_gate "$BENCH" manifest-build; printf '[exit %s]\n' "$?"
printf '\n$ bin/fm-bench-gate.sh --bench <bench> freeze\n'
run_gate "$BENCH" freeze; printf '[exit %s]\n' "$?"
printf '\n$ bin/fm-bench-gate.sh --bench <bench> preflight\n'
run_gate "$BENCH" preflight; status=$?; printf '[exit %s]\n' "$status"
printf '\n$ cat <bench>/preflight.receipt\n'
sed -e "s#$BENCH#<bench>#g" "$BENCH/preflight.receipt" 2>/dev/null || echo "(no receipt)"

echo
echo "======================================================================"
echo " 4. The cleared entrant is now allowed through the launch boundary"
echo "======================================================================"
guard() {
  local id=$1 bench=${2:-}
  ( unset FM_BENCH_ROOT FM_BENCH_LAUNCH_BYPASS
    [ -z "$bench" ] || export FM_BENCH_ROOT="$bench"
    # shellcheck disable=SC1091
    . "$ROOT/bin/fm-bench-launch-lib.sh"
    fm_refuse_ungated_benchmark_entrant "$id" 2>&1
    printf 'launch-boundary rc=%s\n' "$?" )
}
printf '\n$ fm_refuse_ungated_benchmark_entrant bench-b1-k7   # the fm-spawn hook, with the clearance in place\n'
guard bench-b1-k7 "$BENCH"
printf '\n$ fm_refuse_ungated_benchmark_entrant ordinary-crew-task   # a non-benchmark id is untouched\n'
guard ordinary-crew-task "$BENCH"

echo
echo "======================================================================"
echo " 5. Evidence changed after the clearance withdraws it again"
echo "======================================================================"
mkdir -p "$BENCH/shared"
printf 'shared packet fixture\n' > "$BENCH/shared/fixture.bin"
ln -s "$BENCH/shared/fixture.bin" "$BENCH/packets/A1/fixture.bin"
run_gate "$BENCH" freeze >/dev/null
printf '\n$ ln -s <bench>/shared/fixture.bin <bench>/packets/A1/fixture.bin\n'
printf '$ bin/fm-bench-gate.sh --bench <bench> preflight\n'
run_gate "$BENCH" preflight; printf '[exit %s]\n' "$?"
printf '\n$ ls <bench>/preflight.receipt\n'
if [ -e "$BENCH/preflight.receipt" ]; then echo "receipt STILL PRESENT (unexpected)"; else echo "ls: no such file: <bench>/preflight.receipt"; fi
printf '\n$ fm_refuse_ungated_benchmark_entrant bench-b1-k7\n'
guard bench-b1-k7 "$BENCH"
