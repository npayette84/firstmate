# Pi Follow-up wake presentation coalescing: test evidence

All artifacts here were produced by driving the tracked extension
`.pi/extensions/fm-primary-pi-watch.ts` through the real Pi `ExtensionAPI`
boundary (the same fixture install `tests/fm-pi-watch-extension.test.sh` uses),
with a `sendUserMessage` fake that matches the real surface: Pi 0.84.4 declares
`ExtensionAPI.sendUserMessage(...): void` and its loader discards the runtime
promise, so the fake queues a dock row and returns, and runtime effects
(`agent_start`, inline drain, `agent_settled`) happen afterwards off that call
stack. That surface was read from the installed runtime, not assumed.

| Artifact | What it shows |
| --- | --- |
| `pi-dock-burst-transcript.txt` | The end-user symptom and the fix: 20 actionable watcher closes during one long captain turn produce 20 dock rows on upstream `355f46f` and 1 dock row on this change, with all 20 durable wake-queue records intact in both runs. |
| `pi-dock-failure-visibility-transcript.txt` | With an ordinary row already docked, continuity-restoration exhaustion still presents its own `watcher: FAILED` row. The counterexample run shows the call-site-only urgency shape swallowing that failure. |
| `pi-coalescing-mutation-matrix.txt` | Non-vacuity: each of the 9 new coalescing tests run individually against 7 deliberately broken extension variants. |
| `pi-watch-extension-suite.log` | `bash tests/fm-pi-watch-extension.test.sh`: 46 ok, exit 0. |
| `pi-related-suites.log` | The other suites that load this extension. primary-types skips (no `tsc` on this machine); branch-extension (31) and calm-extension (9) both exit 0. |
| `pi-dock-burst-demo.sh`, `pi-dock-failure-visibility-demo.sh` | The demo drivers that produced the two transcripts. |

## Reproducing

Both demos and the per-test variant runner need a `defs.sh`: the test file with
its runner list stripped, so its fixture helpers can be sourced and the
extension under test can be swapped with `EXT_OVERRIDE`.

```sh
sed -n '1,3827p' tests/fm-pi-watch-extension.test.sh \
  | sed "6s|.*|. \"$PWD/tests/lib.sh\"|" \
  | sed '9s|.*|EXT="${EXT_OVERRIDE:-$ROOT/.pi/extensions/fm-primary-pi-watch.ts}"|' \
  > /tmp/defs.sh

DEFS=/tmp/defs.sh bash pi-dock-burst-demo.sh "AFTER" 20
DEFS=/tmp/defs.sh bash pi-dock-failure-visibility-demo.sh "AFTER"
```

`tests/lib.sh` `fail()` exits on the first failure, so the mutation matrix was
produced by appending a runner that calls each of the 9 coalescing tests in its
own subshell and records a per-test verdict, then running that file once per
variant with `EXT_OVERRIDE` pointed at the broken copy.
