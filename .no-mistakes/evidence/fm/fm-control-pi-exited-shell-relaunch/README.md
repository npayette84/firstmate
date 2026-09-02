# Safe relaunch over an exited Pi shell - end-to-end evidence

The reported defect: on a Herdr endpoint whose Pi worker had exited cleanly to a
zsh shell, `bin/fm-control.sh <task> relaunch` classified the agent as alive,
typed `/quit` at the shell, and failed without launching a replacement.

Everything below ran on this machine against the real installed `herdr 0.8.2`,
inside private throwaway `fm-lab-*` sessions only (`bin/fm-herdr-lab.sh`), never
the captain's default session. `relaunch-e2e-demo.sh` is the exact reproduction
script; it stands up a real git worktree with committed and uncommitted work, a
real Herdr task pane holding nothing but zsh, and a stale `pane report-agent`
registration, then runs the supported operator command.

No model tokens were spent: the replacement harness is a shim that idles in the
pane's foreground, which is what the liveness classifier actually reads.

## The two transcripts

| file | code under test | result |
| --- | --- | --- |
| `relaunch-e2e-before-prefix-classifier.txt` | pre-fix `bin/backends/herdr.sh` | reproduces the bug |
| `relaunch-e2e-after-fixed-classifier.txt` | this branch | relaunch succeeds |

Pre-fix, from the same fixture:

    firstmate's own classifier    ->  fm_backend_agent_state herdr = alive
    error: exit-delivered demo interrupt=not-needed exit-command=delivered agent-state=alive exit=unconfirmed; the agent did not stop within 3s
    error: relaunch of demo failed while stopping the old agent, which is still running; its original instructions were restored
    exit status: 1
    pane received /quit: YES  <- the harness exit command was typed at a zsh prompt
    pane foreground now: [{"name":"zsh","argv0":"zsh"}]

On this branch, same fixture, same command:

    firstmate's own classifier    ->  fm_backend_agent_state herdr = dead
    relaunched demo harness=pi from=pi model=default effort=default backend=herdr endpoint=... worktree=...
    exit status: 0
    pane received /quit: no
    pane foreground now: [{"name":"sleep","argv0":"sleep"}]        <- the replacement is running
    branch:            task-demo
    HEAD unchanged:    yes
    uncommitted file:  work the previous worker had not committed
    committed file:    committed on the preserved branch
    journal exit_result: exit_result=already-stopped
    progress note in the replacement's instructions: yes

Both runs read the identical Herdr disagreement first, so the change of verdict
comes from the corroboration and nothing else:

    $ herdr agent get w1:p2      ->  agent_status: idle
    $ herdr pane process-info    ->  foreground: [{"name":"zsh","argv0":"zsh"}]

## Supporting artifacts

- `real-herdr-control-plane-smoke.txt` - `tests/fm-control-herdr-smoke.test.sh`
  against the real binary: exit is idempotent on the proved-agent-free pane and
  types no `/quit`, interrupt still refuses there, the same registration over a
  genuinely running foreground process stays alive, an agent that cannot be
  stopped still fails closed, and no verb removed the endpoint, the local copy,
  or the branch.
- `installed-harness-agent-free-drift-guard.txt` - the opt-in per-harness guard
  (`FM_HERDR_AGENT_FREE_PROOF=1`), launching every INSTALLED harness for real in
  a Herdr pane. claude 2.1.257, codex 0.150.1, opencode 1.17.11, pi 0.84.4, and
  cursor 2026.08.31 each own the pane foreground and read `alive`; none is
  mistaken for a bare idle shell. pi-signed, grok, kimi, and muse are reported
  as not installed rather than silently passing.
- `classifier-and-relaunch-behavioral-cases.txt` - the deterministic cases:
  live process, ambiguous inventory, shell with a child, unreadable inventory,
  inventory about another pane, unregistered pane, husk replacement, and both
  relaunch paths (success and replacement-launch failure with work preserved).
