#!/usr/bin/env bash
# Reviewer-visible demo: with one ordinary work-waiting row already docked, a
# continuity-restoration failure must still present its own row. Runs the real
# tracked extension through the real ExtensionAPI boundary.
# Usage: DEFS=<defs.sh> EXT_OVERRIDE=<extension.ts> pi-dock-failure-visibility-demo.sh <label>
set -u
LABEL=$1
# shellcheck source=/dev/null
. "$DEFS"
repo="$TMP_ROOT/fail-root"
home="$TMP_ROOT/fail-home"
mkdir -p "$repo/bin" "$home/state" "$home/config"
install_pi_watch_extension_fixture "$repo"
cat > "$repo/bin/fm-watch-arm.sh" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = --handling-delivered ]; then
  printf 'confirmed\n' >> "${FM_CONFIRM_LOG:?}"
  exit 0
fi
printf 'arm=%s\n' "$$" >> "${FM_ARM_LOG:?}"
count=$(grep -c '^arm=' "$FM_ARM_LOG")
if [ "$count" -eq 1 ]; then
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: secondmate alpha finished, needs review\n'
  exit 0
fi
if [ "$count" -eq 2 ]; then
  printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-2\n' "$$"
  while [ ! -e "${FM_BURST_GO:?}/2" ] && [ ! -e "${FM_STOP_FILE:?}" ]; do sleep 0.02; done
  [ -e "${FM_STOP_FILE:?}" ] && exit 0
  printf 'signal: secondmate bravo finished, needs review\n'
  exit 0
fi
# Every successor for the second close hangs without reporting readiness, so
# continuity restoration exhausts its bounded retries.
trap 'exit 0' TERM INT
while :; do sleep 0.02; done
SH
chmod +x "$repo/bin/fm-watch-arm.sh"
PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts" \
FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
FM_ARM_LOG="$TMP_ROOT/fail-arm.log" FM_CONFIRM_LOG="$TMP_ROOT/fail-confirm.log" \
FM_BURST_GO="$TMP_ROOT/fail-go" FM_STOP_FILE="$TMP_ROOT/fail.stop" \
FM_PI_ARM_READY_TIMEOUT_MS="$ARM_READY_TIMEOUT_MS" \
FM_WATCH_REARM_RETRY_BASE_MS=5 FM_WATCH_REARM_RETRY_MAX_MS=10 FM_WATCH_REARM_RETRY_LIMIT=1 \
DEMO_LABEL="$LABEL" node --input-type=module <<'EOF'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

let tool = null;
const handlers = new Map();
const dock = [];
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  registerCommand() {},
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
  sendUserMessage: (message) => { dock.push(String(message)); return undefined; },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
await handlers.get("agent_start")?.({ type: "agent_start" }, {});
await tool.execute("demo-fail", {}, undefined, undefined, {});
mkdirSync(process.env.FM_BURST_GO, { recursive: true });
const confirms = () => (existsSync(process.env.FM_CONFIRM_LOG) ? readFileSync(process.env.FM_CONFIRM_LOG, "utf8").trim().split("\n").filter(Boolean).length : 0);
async function waitFor(p, label, ticks = 800) {
  for (let i = 0; i < ticks; i += 1) { if (p()) return true; await new Promise((r) => setTimeout(r, 10)); }
  return false;
}
await waitFor(() => confirms() >= 1 && dock.length >= 1, "ordinary row docked");
writeFileSync(`${process.env.FM_BURST_GO}/2`, "go\n");
// Give restoration its bounded retries and then some settling time whether or
// not a second row ever appears.
await waitFor(() => dock.length >= 2, "supervision-failure row", 1500);
await new Promise((r) => setTimeout(r, 300));
writeFileSync(process.env.FM_STOP_FILE, "stop\n");
console.log(`--- ${process.env.DEMO_LABEL} ---`);
console.log("scenario: one ordinary work-waiting row already docked, then a second close");
console.log("          whose continuity restoration exhausts its retries");
console.log(`Pi follow-up dock rows presented to the captain: ${dock.length}`);
console.log("");
for (const [i, row] of dock.entries()) {
  console.log(`  [row ${i + 1}]`);
  for (const l of row.replace(/^⁣/, "").split("\n")) console.log(`    | ${l}`);
}
if (!dock.some((r) => r.includes("watcher: FAILED"))) {
  console.log("");
  console.log("  *** no supervision-failure row reached the captain: the failure was coalesced away ***");
}
console.log("");
process.exit(0);
EOF
