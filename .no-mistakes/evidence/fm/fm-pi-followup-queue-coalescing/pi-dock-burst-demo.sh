#!/usr/bin/env bash
# Reviewer-visible demo of the Pi follow-up dock under a burst of ordinary
# watcher closes, run through the real tracked extension and the real
# ExtensionAPI boundary (same fixture install the suite uses).
# Usage: DEFS=<defs.sh> EXT_OVERRIDE=<extension.ts> pi-dock-burst-demo.sh <label> <N>
set -u
LABEL=$1
N=$2
# shellcheck source=/dev/null
. "$DEFS"
repo="$TMP_ROOT/demo-root"
home="$TMP_ROOT/demo-home"
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
  printf '1\t1\tsignal\tclose-1\tsignal: secondmate alpha finished, needs review\n' >> "${FM_WAKE_QUEUE:?}"
  printf 'watcher: started pid=%s (beacon fresh)\n' "$$"
  printf 'signal: secondmate alpha finished, needs review\n'
  exit 0
fi
printf 'watcher: started pid=%s (beacon fresh) recovery-generation=gen-%s\n' "$$" "$count"
while [ ! -e "${FM_BURST_GO:?}/$count" ] && [ ! -e "${FM_STOP_FILE:?}" ]; do sleep 0.02; done
[ -e "${FM_STOP_FILE:?}" ] && exit 0
printf '1\t%s\tsignal\tclose-%s\tsignal: secondmate %s finished, needs review\n' "$count" "$count" "$count" >> "${FM_WAKE_QUEUE:?}"
printf 'signal: secondmate %s finished, needs review\n' "$count"
SH
chmod +x "$repo/bin/fm-watch-arm.sh"
PLUGIN="$repo/.pi/extensions/fm-primary-pi-watch.ts" \
FM_HOME="$home" FM_ROOT_OVERRIDE="$repo" \
FM_ARM_LOG="$TMP_ROOT/arm.log" FM_CONFIRM_LOG="$TMP_ROOT/confirm.log" \
FM_WAKE_QUEUE="$home/state/.wake-queue" FM_BURST_GO="$TMP_ROOT/go" \
FM_STOP_FILE="$TMP_ROOT/stop" DEMO_LABEL="$LABEL" DEMO_N="$N" \
node --input-type=module <<'EOF'
import { existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { pathToFileURL } from "node:url";

const N = Number(process.env.DEMO_N);
let tool = null;
const handlers = new Map();
const dock = [];
let running = false;
const pi = {
  on(event, handler) { handlers.set(event, handler); },
  registerCommand() {},
  registerTool(candidate) { if (candidate.name === "fm_watch_arm_pi") tool = candidate; },
  // Pi 0.84.4 ExtensionAPI.sendUserMessage: queues a follow-up row, returns void.
  sendUserMessage: (message) => { dock.push(String(message)); return undefined; },
};
writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\n`);
const mod = await import(pathToFileURL(process.env.PLUGIN).href);
mod.default(pi);
// The captain is mid-turn for the whole burst: a long handling turn is exactly
// when the dock accumulates.
running = true;
await handlers.get("agent_start")?.({ type: "agent_start" }, {});
await tool.execute("demo-arm", {}, undefined, undefined, {});
mkdirSync(process.env.FM_BURST_GO, { recursive: true });
const lines = (f) => (existsSync(f) ? readFileSync(f, "utf8").trim().split("\n").filter(Boolean) : []);
const confirms = () => lines(process.env.FM_CONFIRM_LOG).length;
async function waitFor(p, label) {
  for (let i = 0; i < 1000; i += 1) {
    if (p()) return;
    await new Promise((r) => setTimeout(r, 10));
  }
  throw new Error(`timeout waiting for ${label}`);
}
await waitFor(() => confirms() >= 1, "close 1");
for (let c = 2; c <= N; c += 1) {
  writeFileSync(`${process.env.FM_BURST_GO}/${c}`, "go\n");
  await waitFor(() => confirms() >= c, `close ${c}`);
}
await waitFor(() => lines(process.env.FM_ARM_LOG).length >= N + 1, "final successor");
await new Promise((r) => setTimeout(r, 150));
writeFileSync(process.env.FM_STOP_FILE, "stop\n");

const queue = lines(process.env.FM_WAKE_QUEUE);
console.log(`--- ${process.env.DEMO_LABEL} ---`);
console.log(`actionable watcher closes during the captain's turn : ${confirms()}`);
console.log(`durable wake-queue records (bin/fm-wake-drain.sh)   : ${queue.length}`);
console.log(`Pi follow-up dock rows presented to the captain     : ${dock.length}`);
console.log("");
console.log("Pi follow-up dock as the captain would see it:");
for (const [i, row] of dock.entries()) {
  const first = row.split("\n").find((l) => l.includes("FIRSTMATE WATCHER WAKE")) || row.split("\n")[0];
  console.log(`  [row ${String(i + 1).padStart(2, " ")}] ${first.replace(/^⁣/, "")}`);
}
console.log("");
console.log("Full text of dock row 1 (what the model actually receives):");
for (const l of dock[0].replace(/^⁣/, "").split("\n")) console.log(`  | ${l}`);
console.log("");
console.log("Durable queue (untouched by presentation coalescing):");
for (const l of queue) console.log(`  ${l.replace(/\t/g, "  ")}`);
console.log("");
process.exit(0);
EOF
