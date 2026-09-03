# fleet usage ledger: end-to-end against the real harness session trees

Read-only against the unmodified `~/.pi/agent/sessions` and `~/.claude/projects`
trees on this host. Two synthetic task records (`state/<id>.meta` +
`state/<id>.status`) were pointed at worktrees that real sessions actually ran
in, and each meta's mtime was deliberately touched forward to the END of the
task, which is what a late PR-registration write does in production.

## 1. pi task, meta rewritten to the end of the task

meta: harness=pi, model=default, spawn_gen=s1788344756..., worktree=
/Users/npayette/.treehouse/specira-website-34a67e/1/specira-website
meta mtime and status mtime both forced to 2026-09-03T00:56:17Z (the task end).

    $ bin/fm-usage-harvest.sh ship-website-perf
    $ cat data/usage-ledger.jsonl
    {"task":"ship-website-perf","spawn_gen":"s1788344756.4711.a1b2c3","harness":"pi","model":"openai-codex/gpt-5.6-sol","effort":null,"spawned_at":"2026-09-02T10:25:56Z","completed_at":"2026-09-03T00:56:17Z","wall_secs":52221,"turns":2,"input_tokens":116211,"cached_input_tokens":1368832,"output_tokens":15567,"reasoning_tokens":6976,"source":"pi-sessions"}

Independent recomputation over the same real log, straight from jq:

    $ jq -s '[.[]|select(.type=="message" and .message.role=="assistant" and .message.usage!=null)]
             | {records:length, input:(map(.message.usage.input//0)|add),
                cacheRead:(map(.message.usage.cacheRead//0)|add),
                cacheWrite:(map(.message.usage.cacheWrite//0)|add),
                output:(map(.message.usage.output//0)|add),
                reasoning:(map(.message.usage.reasoning//0)|add)}' \
        ~/.pi/agent/sessions/--Users-npayette-.treehouse-specira-website-34a67e-1-specira-website--/*.jsonl
    { "records": 40, "input": 116211, "cacheRead": 1368832, "cacheWrite": 0,
      "output": 15567, "reasoning": 6976 }

input 116211, cached 1368832 (cacheRead + cacheWrite), output 15567 and
reasoning 6976 match the ledger row exactly. wall_secs 52221 is the real span
from the spawn_gen epoch to the last status append, and the model is reported
provider-qualified as openai-codex/gpt-5.6-sol.

### counterfactual: strip the durable spawn_gen from that same meta

The start then has no durable source and falls back to the file timestamps,
which is the collapse the change exists to avoid:

    {"task":"ship-website-perf","spawn_gen":null,"harness":"pi","model":"openai-codex/gpt-5.6-sol","effort":null,"spawned_at":"2026-09-03T00:56:17Z","completed_at":"2026-09-03T00:56:17Z","wall_secs":0,"turns":2,"input_tokens":116211,"cached_input_tokens":1368832,"output_tokens":15567,"reasoning_tokens":6976,"source":"pi-sessions"}

wall_secs drops 52221 -> 0 and spawned_at collapses onto completed_at.

## 2. claude task: per-request dedupe on .message.id over real logs

meta: harness=claude, model=default, effort=high, worktree=
/Users/npayette/.no-mistakes/worktrees/337060f4dfd2/01M1D1VTTW7SQ2RWF5T2H7NH68
That project directory holds 1773 raw usage entries across 1125 distinct
.message.id values, so the dedupe is load-bearing here rather than a no-op.

    $ bin/fm-usage-harvest.sh fix-ledger-window
    {"task":"fix-ledger-window","spawn_gen":"s1788218000.9021.zz9plu","harness":"claude","model":"claude-opus-5","effort":"high","spawned_at":"2026-08-31T23:13:20Z","completed_at":"2026-09-03T08:12:43Z","wall_secs":205163,"turns":7,"input_tokens":2240,"cached_input_tokens":216242085,"output_tokens":578158,"reasoning_tokens":279700,"source":"claude-projects"}

Independent deduped recomputation over the same logs:

    $ cat ~/.claude/projects/-Users-npayette--no-mistakes-worktrees-337060f4dfd2-01M1D1VTTW7SQ2RWF5T2H7NH68/*.jsonl |
      jq -rs '[.[]|select(.type=="assistant" and .message.usage!=null)] | group_by(.message.id)
              | map(.[0].message.usage)
              | {reqs:length, input:(map(.input_tokens//0)|add),
                 cached:(map((.cache_read_input_tokens//0)+(.cache_creation_input_tokens//0))|add),
                 output:(map(.output_tokens//0)|add),
                 reasoning:(map(.output_tokens_details.thinking_tokens//0)|add)}'
    { "reqs": 1125, "input": 2240, "cached": 216242085,
      "output": 578158, "reasoning": 279700 }

All four token fields match the ledger row.

## 3. sources that report no tokens

A cursor task and a pi task carrying remote_host=orca-02.fleet both land as
null tokens with source unavailable, and the remote one is not credited with
any local pi log even though its worktree has one:

    {"task":"audit-cursor-run","spawn_gen":"s1788300000.100.aaa","harness":"cursor","model":null,"effort":null,"spawned_at":"2026-09-01T22:00:00Z","completed_at":"2026-09-01T23:00:00Z","wall_secs":3600,"turns":1,"input_tokens":null,"cached_input_tokens":null,"output_tokens":null,"reasoning_tokens":null,"source":"unavailable"}
    {"task":"remote-crew-task","spawn_gen":"s1788300000.100.aaa","harness":"pi","model":"zai/glm-5.3-flash","effort":null,"spawned_at":"2026-09-01T22:00:00Z","completed_at":"2026-09-01T23:00:00Z","wall_secs":3600,"turns":1,"input_tokens":null,"cached_input_tokens":null,"output_tokens":null,"reasoning_tokens":null,"source":"unavailable"}

## 4. the report reader over that ledger

    $ bin/fm-usage-report.sh
    usage ledger: /var/folders/70/p814fs691f103nxddhx58mhh0000gn/T//fm-usage-e2e.LVOWSu/home/data/usage-ledger.jsonl (4 rows)
    
    per-model totals (source-available rows):
    model                     tasks        input       cached       output    reasoning  wall_secs
    claude-opus-5                 1         2240    216242085       578158       279700     205163
    openai-codex/gpt-5.6-sol      1       116211      1368832        15567         6976      52221
    
    per-task rows:
    task                     spawned_at           harness  model                effort          input       cached       output    reasoning  wall_secs source          
    audit-cursor-run         2026-09-01T22:00:00Z cursor   -                    -                   -            -            -            -       3600 unavailable     
    fix-ledger-window        2026-08-31T23:13:20Z claude   claude-opus-5        high             2240    216242085       578158       279700     205163 claude-projects 
    remote-crew-task         2026-09-01T22:00:00Z pi       zai/glm-5.3-flash    -                   -            -            -            -       3600 unavailable     
    ship-website-perf        2026-09-02T10:25:56Z pi       openai-codex/gpt-5.6-sol -              116211      1368832        15567         6976      52221 pi-sessions     

Unavailable rows render "-" in every token column without shifting the columns,
and they are excluded from the per-model totals.

## 5. idempotency and the report's failure mode

    $ for t in ship-website-perf fix-ledger-window audit-cursor-run remote-crew-task; do
        bin/fm-usage-harvest.sh "$t"; done
    $ wc -l data/usage-ledger.jsonl
    rows before=4 after=4

    $ bin/fm-usage-report.sh /absent/usage-ledger.jsonl
    no usage ledger at /absent/usage-ledger.jsonl
    exit=0

    $ printf '{"task":"half-written"\n' >> broken.jsonl && bin/fm-usage-report.sh broken.jsonl
    jq: parse error: Unfinished JSON term at EOF at line 6, column 0
    error: broken.jsonl: ledger is not readable as JSON lines
    exit=1
