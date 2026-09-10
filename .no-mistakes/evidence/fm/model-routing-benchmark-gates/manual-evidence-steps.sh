#!/usr/bin/env bash
# Behavior tests for the model-routing benchmark gates: the corrected sampling
# and promotion rule, the common neutral judge panel, positive provenance,
# the derived run and cost manifest, the calibrated evaluator, content-addressed
# archives with a real restore drill, and the fail-closed launch guard.
#
# The isolation gate is covered here for non-vacuity - the probe set really does
# detect a leak, and a denial with no positive control is refused - while the
# full-denial proof needs a real confinement and lives in
# tests/fm-bench-isolation-e2e.test.sh.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

GATE="$ROOT/bin/fm-bench-gate.sh"
CONFINE="$ROOT/bin/fm-bench-confine.sh"
IMAGE=${FM_BENCH_CONFINE_IMAGE:-python:3.12-slim}
TMP_ROOT=$(fm_test_tmproot fm-bench-gate)

command -v python3 >/dev/null 2>&1 || { echo "skip: python3 not found"; exit 0; }
command -v git >/dev/null 2>&1 || { echo "skip: git not found"; exit 0; }

RESTORE_MECHANISM=
if command -v bwrap >/dev/null 2>&1; then
  RESTORE_MECHANISM=bwrap
else
  for runtime in docker podman; do
    if command -v "$runtime" >/dev/null 2>&1 && "$runtime" info >/dev/null 2>&1 \
      && "$runtime" image inspect "$IMAGE" >/dev/null 2>&1; then
      IMAGE=$("$runtime" image inspect "$IMAGE" --format '{{.Id}}')
      RESTORE_MECHANISM=container
      break
    fi
  done
fi

# Every fixture starts from one corrected plan and then breaks exactly one thing,
# so a refusal is always attributable to the correction under test.
write_plan() {  # <bench-dir> [python-mutation]
  local bench=$1 mutation=${2:-}
  mkdir -p "$bench"
  python3 - "$bench/benchmark.json" "$mutation" <<'PY'
import json, sys

path, mutation = sys.argv[1], sys.argv[2]

def candidate(name, family, harness, model, effort="high", **extra):
    row = {"name": name, "family": family, "harness": harness, "model": model,
           "effort": effort, "metered_provider": False}
    row.update(extra)
    return row

fable = candidate("Fable 5 High", "anthropic", "claude", "fable")
sol = candidate("GPT 5.6 Sol High", "openai", "pi", "openai-codex/gpt-5.6-sol")
opus5 = candidate("Opus 5 High", "anthropic", "claude", "opus")
glm = candidate("GLM 5.3 Flash", "zai", "pi", "zai/glm-5.3-flash")
terra = candidate("Terra 5.6 High", "openai", "pi", "openai-codex/gpt-5.6-terra")
opus48 = candidate("Opus 4.8 High", "anthropic", "claude", "claude-opus-4-8")
grok = candidate("Grok 4.6", "xai", "cursor", "cursor-grok-4.6-high",
                 effort=None, effort_axis=False, metered_provider="cursor")
composer = candidate("Composer 2.5", "cursor", "cursor", "composer-2.5",
                     effort=None, effort_axis=False, metered_provider="cursor")

def track(prefix, entrants, judges, baseline, cost_class, kinds, **extra):
    row = {
        "packets": [{"id": f"{prefix}{i + 1}", "kind": kinds[i]} for i in range(6)],
        "entrants": entrants,
        "judges": judges,
        "judge_call_unit": "per-candidate-output-per-judge",
        "run_cost_class": cost_class,
        "baseline_required": baseline is not None,
        "capture_required": False,
        "specification_required": False,
    }
    if baseline:
        row["baseline"] = baseline
        row["baseline_packets"] = [f"{prefix}1", f"{prefix}3", f"{prefix}5"]
    row.update(extra)
    return row

neutral_ac = [{"name": "GLM 5.3 Max", "family": "zai"}, {"name": "Grok 4.6 Judge", "family": "xai"}]
neutral_b = [{"name": "Luna 5.6", "family": "mistral"}, {"name": "Nova 3", "family": "cohere"}]
historical_first = ["historical"] + ["synthetic"] * 5

plan = {
    "schema": "fm-bench-plan.v1",
    "benchmark_id": "model-routing-benchmark-test",
    "isolation_mode": "enforced",
    "candidate_disposition": "archive-then-discard",
    "direct_ship": False,
    "approved_cost_class_usd": 1100.0,
    "randomisation_seed": "7f3c1a9e",
    "samples_per_entrant": 6,
    "samples_per_baseline": 3,
    "adaptive_extension": False,
    "sample_winner_rule": {
        "definition": "highest composite under the track's common panel",
        "ties": "an exact tie is a declared tie and breaks the sweep",
        "voids": "a void is rerun as the same approved sample",
        "missing": "no valid final commit is void, not a loss",
    },
    "promotion_rule": {
        "type": "paired-sweep",
        "composite": {
            "weights": {"deterministic": 0.5, "panel": 0.5},
            "score_scale": {"min": 0.0, "max": 10.0},
        },
        "required_wins": 6,
        "of_samples": 6,
        "practical_margin": 1.0,
        "allow_blocker_class_failure": False,
        "baseline_role": "regression_veto",
        "baseline_veto": {"max_negative_mean_quality_delta": 0.0, "max_losses_of_three": 1},
        "tie_breakers": ["deterministic_evidence", "neutral_judge_pairwise", "declared_tie"],
    },
    "failure_policy": {
        "candidate_caused": "score_zero",
        "evaluator_infrastructure": "void_and_rerun",
        "provider_outage": "void_and_rerun",
        "quota_exhaustion": "void_and_rerun",
        "sibling_access": "blocker_class",
    },
    "timing": {
        "clock": "utc-wall-clock-plus-monotonic-local-receipt",
        "intervals": [
            "dispatch_accepted_to_first_valid_final_commit",
            "first_assistant_event_to_first_valid_final_commit",
        ],
        "queue_trust_delay_recorded": True,
        "no_commit_timeout_s": 10800,
        "no_commit_disposition": "void_and_rerun",
    },
    "cost_model": {
        "job_classes": {
            "planning_run": {"low": 3.0, "base": 5.5, "high": 8.0},
            "implementation_run": {"low": 4.0, "base": 8.0, "high": 12.0},
            "security_run": {"low": 4.0, "base": 8.0, "high": 12.0},
            "spec_authoring": {"low": 3.0, "base": 5.0, "high": 8.0},
            "judge_call": {"low": 1.0, "base": 2.0, "high": 3.0},
            "capture_job": {"low": 0.0, "base": 0.0, "high": 0.0},
        }
    },
    "tracks": {
        "A": track("A", [fable, sol], neutral_ac, opus5, "planning_run", historical_first),
        "B": track(
            "B",
            [glm, grok, composer, terra, opus48],
            neutral_b,
            None,
            "implementation_run",
            ["synthetic"] * 6,
            capture_required=True,
            specification_required=True,
            wave="single-complete",
            spec_author={
                "name": "Fable 5",
                "family": "anthropic",
                "family_adjacency_disclosed": ["Opus 4.8 High"],
            },
            spec_audit=[
                {
                    "packet": f"B{i + 1}",
                    "auditor": "independent spec auditor",
                    "auditor_family": "mistral",
                    "pre_freeze": True,
                    "verdict": "accepted",
                }
                for i in range(6)
            ],
        ),
        "C": track("C", [sol, fable], neutral_ac, opus5, "security_run", historical_first),
    },
}

if mutation:
    exec(mutation, {"plan": plan})

json.dump(plan, open(path, "w"), indent=2, sort_keys=True)
PY
}

write_freeze_inputs() {  # <bench-dir>
  local bench=$1
  python3 - "$bench" <<'PY'
import json, sys
from pathlib import Path

bench = Path(sys.argv[1])
plan = json.loads((bench / "benchmark.json").read_text())
for track in plan["tracks"].values():
    for packet in track["packets"]:
        packet_id = packet["id"]
        packet_dir = bench / "packets" / packet_id
        packet_dir.mkdir(parents=True, exist_ok=True)
        (bench / "packets" / f"{packet_id}.md").write_text(f"packet {packet_id}\n")
        truth = bench / "ground-truth" / f"{packet_id}.md"
        truth.parent.mkdir(parents=True, exist_ok=True)
        truth.write_text(f"sealed truth {packet_id}\n")
(bench / "scoring").mkdir(parents=True, exist_ok=True)
(bench / "scoring" / "composite.py").write_text("def score(): return 1\n")
(bench / "judge-prompts").mkdir(parents=True, exist_ok=True)
(bench / "judge-prompts" / "common.md").write_text("common neutral judge prompt\n")
PY
}

write_provenance() {  # <bench-dir> <packet> <mode>
  local bench=$1 packet=$2 mode=$3
  mkdir -p "$bench/provenance"
  if [ "$mode" = cleared ]; then
    cat > "$bench/provenance/$packet.json" <<EOF
{"schema":"fm-bench-provenance.v1","packet":"$packet","source":"replayed history",
 "checked_families":["anthropic","openai"],
 "role_absences":{"judge":"the original work had no judge"},
 "participants":[
  {"task_id":"$packet-author","role":"author","model_id":"zai/glm-5.3-flash","family":"zai","session_id":"pi-1"},
  {"task_id":"$packet-review","role":"reviewer","model_id":"zai/glm-5.3","family":"zai","session_id":"pi-2"}]}
EOF
  else
    cat > "$bench/provenance/$packet.json" <<EOF
{"schema":"fm-bench-provenance.v1","packet":"$packet","source":"replayed history",
 "checked_families":["anthropic","openai"],
 "role_absences":{"reviewer":"the review record is unavailable","judge":"the original work had no judge"},
 "participants":[
  {"task_id":"$packet-author","role":"author","model_id":"no record found","family":"unknown","session_id":"unavailable"}]}
EOF
  fi
}

run_gate() {  # <bench-dir> <gate> [args...]
  local bench=$1
  shift
  "$GATE" --bench "$bench" --probe-timeout 30 "$@" 2>&1
}

bench_evidence_digest() {  # <bench-dir>
  run_gate "$1" evidence-digest \
    | sed -n 's/^BENCH_CHECK launch\.evidence_digest ok //p' | head -n 1
}

# Mint the receipt a passing preflight would write, taking the evidence binding
# from the gate itself rather than recomputing the gate's digest in the test.
write_receipt() {  # <bench-dir> [isolation-hash-override]
  local bench=$1 isolation_override=${2:-} digest
  digest=$(bench_evidence_digest "$bench")
  [ -n "$digest" ] || fail "the gate reported no evidence digest for $bench"
  python3 - "$bench" "$digest" "$isolation_override" <<'PY'
import hashlib, json, sys
from pathlib import Path
bench, evidence, isolation_override = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
isolation = bench / "isolation.json"
receipt = {
    "schema": "fm-bench-preflight-receipt.v1",
    "verdict": "pass",
    "plan_sha256": hashlib.sha256((bench / "benchmark.json").read_bytes()).hexdigest(),
    "evidence_sha256": evidence,
    "stages": ["plan"],
}
if isolation_override:
    receipt["isolation_sha256"] = isolation_override
elif isolation.is_file():
    receipt["isolation_sha256"] = hashlib.sha256(isolation.read_bytes()).hexdigest()
(bench / "preflight.receipt").write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
PY
}

bind_result_plan() {
  write_freeze_inputs "$1"
  run_gate "$1" freeze >/dev/null || fail "result fixture must freeze"
  write_receipt "$1"
}

run_gate_env() {  # <env-argument...> -- <bench-dir> <gate> [args...]
  local -a assignments=()
  while [ "$#" -gt 0 ] && [ "$1" != -- ]; do
    assignments+=("$1")
    shift
  done
  shift
  local bench=$1
  shift
  env "${assignments[@]}" "$GATE" --bench "$bench" --probe-timeout 30 "$@" 2>&1
}


BENCH="$TMP_ROOT/manual-evidence"
write_plan "$BENCH"
printf '$ fm-bench-gate.sh --bench <fixture> plan-check\n'
run_gate "$BENCH" plan-check || exit 1
printf '$ fm-bench-gate.sh --bench <fixture> manifest-build\n'
run_gate "$BENCH" manifest-build || exit 1
printf '$ fm-bench-gate.sh --bench <fixture> manifest-check\n'
run_gate "$BENCH" manifest-check
expect_code 1 "$?" "missing allowance must refuse"
write_freeze_inputs "$BENCH"
printf '$ fm-bench-gate.sh --bench <fixture> freeze\n'
run_gate "$BENCH" freeze || exit 1
printf '\nModify a frozen input, then verify rejection:\n'
printf 'tampered\n' >> "$BENCH/packets/A1.md"
run_gate "$BENCH" freeze-check
status=$?
expect_code 1 "$status" "tampered freeze must refuse"
