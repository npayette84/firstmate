# Cross-check: the strings the final head produces are the strings in the live screenshots

The committed `.evidence/screenshots/*.png` were captured against a real
`lavish-axi` session at the *selected* head (`d71db14`). Four commits landed
after that: two upstream-compatibility fixes and two no-mistakes review commits.
Whether that committed visual evidence is still valid at the branch head
(`2178e9b`) depends on one thing only: whether the visible receipt text changed.

## The visible-text producers are byte-identical

    $ git show d71db14:bin/fm-procevent-lavish.sh | awk '/^receipt_build_text\(\)/,/^}$/' > selected
    $ git show HEAD:bin/fm-procevent-lavish.sh    | awk '/^receipt_build_text\(\)/,/^}$/' > head
    $ diff selected head && echo BYTE-IDENTICAL
    BYTE-IDENTICAL            # 2429 bytes both sides

    (same result for cmd_receipt_text; `git diff d71db14..HEAD -- .evidence` is empty)

## The final head emits the same shapes the screenshots show

Read off `live-lavish-screenshots/completion-laptop.png` (live Lavish
conversation panel, selected head):

    Round 1: received 1 answer at 2026-08-31 17:10 UTC; saved 0 of 1 at
    2026-08-31 17:10 UTC (1 not saved - firstmate follows up in chat);
    complete at 2026-08-31 17:12 UTC. Round 2: already received at
    2026-08-31 17:12 UTC (identical to round 1); no new action.

Produced live by `receipt-lifecycle-e2e.sh` against the branch head
(see `receipt-lifecycle-e2e.txt`, acknowledgement #3):

    Round 1: received 3 answers and a message at ... UTC; saved 2 of 3 at
    ... UTC (1 not saved - firstmate follows up in chat); complete at ... UTC.
    Round 2: already received at ... UTC (identical to round 1); no new action.
    Round 3: received 1 answer at ... UTC; saved 0 of 1 at ... UTC
    (1 not saved - firstmate follows up in chat).

Same sentence grammar, same state vocabulary, same counts-and-UTC-only
discipline: no answer values, decision keys, captain prose, paths or hosts.
The committed screenshots therefore remain valid delivery evidence at the head.
