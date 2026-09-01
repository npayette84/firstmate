# The seven broken extension variants

Each is a single edit to `.pi/extensions/fm-primary-pi-watch.ts`.

| Variant | Edit | Coalescing tests that fail |
| --- | --- | --- |
| `v1-upstream` | the extension at base commit `355f46f`, no coalescing at all | burst only |
| `v2-latch-after-await` | `pendingOrdinaryWakeRow = true` moved after `await pi.sendUserMessage(...)` | idle-consumed re-arm only |
| `v3-callsite-only-urgency` | `const urgent = presentation === "urgent"` (drops the `watcher: FAILED` content check) | restoration exhaustion + restoration-time lock loss |
| `v4-shared-latch` | one latch shared across generations instead of a per-generation field | session replacement only |
| `v5-no-urgency` | `const urgent = false` | all four failure-bypass tests |
| `v6-no-agent-start-clear` | the `agent_start` handler removed, clearing only on `agent_settled` | idle-consumed re-arm only |
| `v7-no-agent-settled-clear` | the `agent_settled` handler removed, clearing only on `agent_start` | busy-path re-arm + discarded-row re-arm |

The intent's original variant list included a "no rejection rollback" variant.
That variant no longer exists: the rollback and its test were removed during
review once the installed Pi 0.84.4 runtime showed `ExtensionAPI.sendUserMessage`
returns `void` and every rejection is routed to `runner.emitError`, so the
extension can never observe one. `v6` and `v7` stand in its place and show both
latch-clearing edges are load-bearing against different tests.

Verbatim results: `pi-coalescing-mutation-matrix.txt`.
