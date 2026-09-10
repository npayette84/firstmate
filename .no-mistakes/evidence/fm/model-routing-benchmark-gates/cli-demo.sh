#!/usr/bin/env bash
set -eu
. tests/lib.sh
GATE="$ROOT/bin/fm-bench-gate.sh"
eval "$(sed -n '41,285p' tests/fm-bench-gate.test.sh)"
TMP_ROOT=$(fm_test_tmproot fm-bench-cli-evidence)
BENCH="$TMP_ROOT/benchmark"
write_plan "$BENCH"
write_freeze_inputs "$BENCH"
for stage in plan-check manifest-build freeze freeze-check; do
  printf '\n$ fm-bench-gate.sh --bench <fixture> %s\n' "$stage"
  run_gate "$BENCH" "$stage"
done
printf '\n$ edit ground-truth/A1.md after freeze\n'
printf 'changed sealed truth\n' > "$BENCH/ground-truth/A1.md"
printf '$ fm-bench-gate.sh --bench <fixture> freeze-check\n'
status=0
run_gate "$BENCH" freeze-check || status=$?
test "$status" = 1
printf 'exit=%s\n' "$status"
printf '\n$ fm-bench-gate.sh --bench <fixture> launch-check\n'
status=0
run_gate "$BENCH" launch-check || status=$?
test "$status" = 1
printf 'exit=%s\n' "$status"
