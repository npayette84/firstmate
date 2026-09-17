#!/usr/bin/env bash
# Repro for the inlined-report rendering gap: a lens finding that quotes markup
# loses that markup on the rendered PR comment, because bin/fm-adversarial-review.sh
# inlines the report as markdown prose rather than inside a fenced code block.
#
# Usage: FM_SRC=<firstmate worktree> repro-inlined-report-render-gap.sh <tmpdir>
set -eu
SRC=${FM_SRC:?path to the firstmate worktree}
D=${1:?work dir}
rm -rf "$D"; mkdir -p "$D"/{state,fakebin,wt}
git -C "$D/wt" init -q
git -C "$D/wt" config user.name t; git -C "$D/wt" config user.email t@e.invalid
printf 'a\n' > "$D/wt/a.txt"; git -C "$D/wt" add -A; git -C "$D/wt" commit -q -m init
printf '<div class="banner">x</div>\n' > "$D/wt/banner.html"
git -C "$D/wt" add -A; git -C "$D/wt" commit -q -m ui
BASE=$(git -C "$D/wt" rev-parse HEAD~1); HEAD_SHA=$(git -C "$D/wt" rev-parse HEAD)
printf '%s\n' "$HEAD_SHA" > "$D/head"; printf '%s\n' "$BASE" > "$D/base"
cat > "$D/fakebin/gh" <<SH
#!/usr/bin/env bash
f=; while [ \$# -gt 0 ]; do case "\$1" in --json) f=\$2; shift 2;; *) shift;; esac; done
case "\$f" in headRefOid) cat "$D/head";; baseRefOid) cat "$D/base";; title) echo 'UI tweak';; body) echo 'body';; *) exit 1;; esac
SH
cat > "$D/fakebin/gh-axi" <<SH
#!/usr/bin/env bash
b=; p=; for a in "\$@"; do [ "\$p" = --body-file ] && b=\$a; p=\$a; done
case "\${1:-} \${2:-}" in
  "pr comment") mkdir -p "$D/posted"; n=\$(( \$(ls "$D/posted" 2>/dev/null | wc -l) + 1 )); cp "\$b" "$D/posted/\$n.md";;
esac
exit 0
SH
chmod +x "$D/fakebin/gh" "$D/fakebin/gh-axi"
printf 'window=fm-task-p\nworktree=%s\nharness=claude\nmodel=default\n' "$D/wt" > "$D/state/task-p.meta"
adv() { FM_STATE_OVERRIDE="$D/state" PATH="$D/fakebin:$PATH" "$SRC/bin/fm-adversarial-review.sh" "$@"; }
adv dispatch task-p https://github.com/example/repo/pull/5 --wt "$D/wt" \
  --base "$BASE" --head "$HEAD_SHA" --seat frontier=fable-5.1 --seat deep=opus-5 >/dev/null
cat > "$D/r1.md" <<'MD'
verdict: RED
boundary_class: merge
findings:
  - id: h1
    severity: MAJOR
    claim: banner markup is not escaped
    evidence: banner.html:1
    problem: the template emits <div class="banner"> with raw text, and </details> in caller text ends the block
    fix: escape it
blind_spots: none seen
MD
printf 'verdict: GREEN\nboundary_class: merge\nfindings:\nblind_spots: none seen\n' > "$D/r2.md"
adv record-lens task-p --round 1 --lens frontier --report "$D/r1.md" >/dev/null
adv record-lens task-p --round 1 --lens deep --report "$D/r2.md" >/dev/null
adv reconcile task-p --round 1
echo '--- the reconciliation comment posted into the PR ---'
cat "$D/posted/2.md"
echo '--- what survives GitHub markdown rendering of that comment ---'
echo 'the quoted <div class="banner"> is parsed as HTML and vanishes;'
echo 'the quoted </details> closes the collapsible early, pushing the rest of the finding outside it.'
