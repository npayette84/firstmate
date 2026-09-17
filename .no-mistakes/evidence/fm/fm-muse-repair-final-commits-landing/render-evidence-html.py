#!/usr/bin/env python3
"""Render the captured evidence into one reviewer-visible HTML page.

The pane capture is real ANSI from `herdr pane read --format ansi`, so the
truecolor Muse prompt glyph and the rule pair are shown as the pane drew them.
"""
import html
import re
import sys
from pathlib import Path

SGR = re.compile(r"\x1b\[([0-9;]*)m")
OTHER_ESC = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]|\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)|\x1b[()][0-9A-B]")

BASE16 = ["#000000", "#cc0000", "#4e9a06", "#c4a000", "#3465a4", "#75507b",
          "#06989a", "#d3d7cf", "#555753", "#ef2929", "#8ae234", "#fce94f",
          "#729fcf", "#ad7fa8", "#34e2e2", "#eeeeec"]


def ansi_to_html(text: str) -> str:
    out, fg, bg, bold, dim = [], None, None, False, False
    open_span = False

    def style() -> str:
        bits = []
        if fg:
            bits.append(f"color:{fg}")
        if bg:
            bits.append(f"background:{bg}")
        if bold:
            bits.append("font-weight:700")
        if dim:
            bits.append("opacity:.6")
        return ";".join(bits)

    pos = 0
    for m in SGR.finditer(text):
        chunk = text[pos:m.start()]
        if chunk:
            out.append(html.escape(OTHER_ESC.sub("", chunk)))
        pos = m.end()
        codes = [c for c in m.group(1).split(";")] or ["0"]
        i = 0
        while i < len(codes):
            c = codes[i] or "0"
            if c == "0":
                fg = bg = None
                bold = dim = False
            elif c == "1":
                bold = True
            elif c == "2":
                dim = True
            elif c == "22":
                bold = dim = False
            elif c == "39":
                fg = None
            elif c == "49":
                bg = None
            elif c in ("38", "48") and i + 1 < len(codes):
                mode = codes[i + 1]
                if mode == "2" and i + 4 < len(codes):
                    col = "#%02x%02x%02x" % tuple(int(codes[i + j] or 0) for j in (2, 3, 4))
                    i += 4
                elif mode == "5" and i + 2 < len(codes):
                    n = int(codes[i + 2] or 0)
                    col = BASE16[n] if n < 16 else "#%02x%02x%02x" % ((n, n, n) if n >= 232 else (128, 128, 128))
                    i += 2
                else:
                    i += 1
                    col = None
                if col:
                    if c == "38":
                        fg = col
                    else:
                        bg = col
            elif c.isdigit() and 30 <= int(c) <= 37:
                fg = BASE16[int(c) - 30]
            elif c.isdigit() and 90 <= int(c) <= 97:
                fg = BASE16[int(c) - 90 + 8]
            elif c.isdigit() and 40 <= int(c) <= 47:
                bg = BASE16[int(c) - 40]
            i += 1
        if open_span:
            out.append("</span>")
            open_span = False
        st = style()
        if st:
            out.append(f'<span style="{st}">')
            open_span = True
    out.append(html.escape(OTHER_ESC.sub("", text[pos:])))
    if open_span:
        out.append("</span>")
    return "".join(out)


def read(p: Path) -> str:
    return p.read_text(errors="replace") if p.exists() else "(missing)"


ev = Path(sys.argv[1])
pane_ansi = read(ev / "live-muse" / "muse-idle-pane.ansi")
after = read(ev / "live-muse" / "muse-after-steer-pane.txt")
summary = read(ev / "live-muse" / "summary.txt")
before_tx = read(ev / "run-before" / "before-fix.transcript.txt")
after_tx = read(ev / "run-after" / "after-fix.transcript.txt")
swallow_tx = read(ev / "run-after-swallow" / "after-fix-swallowed-enter.transcript.txt")

# Keep the pane frames to the composer region a reviewer cares about.
def tail(txt: str, n: int) -> str:
    lines = [l for l in txt.splitlines() if l.strip()]
    return "\n".join(lines[-n:])


page = f"""<!doctype html>
<meta charset="utf-8">
<title>Muse-on-Herdr send confirmation: before / after</title>
<style>
 body {{ background:#14161c; color:#dfe3ea; font:14px/1.5 -apple-system,Segoe UI,sans-serif; margin:0; padding:28px 32px; }}
 h1 {{ font-size:20px; margin:0 0 4px; }}
 h2 {{ font-size:15px; margin:26px 0 8px; color:#9fb4d6; font-weight:600; }}
 .sub {{ color:#8b93a4; margin:0 0 6px; }}
 pre {{ background:#0b0d12; border:1px solid #262b36; border-radius:8px; padding:12px 14px;
       font:12.5px/1.45 SFMono-Regular,Menlo,monospace; white-space:pre-wrap; overflow-x:auto; margin:0 0 10px; }}
 .bad {{ border-color:#7a2c2c; }}
 .good {{ border-color:#2c7a45; }}
 .tag {{ display:inline-block; font:11px/1 SFMono-Regular,Menlo,monospace; padding:4px 8px; border-radius:5px; margin-bottom:6px; }}
 .tag.bad {{ background:#3a1616; color:#ff9d9d; }}
 .tag.good {{ background:#11331f; color:#8be3ab; }}
 .cols {{ display:grid; grid-template-columns:1fr 1fr; gap:18px; }}
</style>
<h1>Muse-on-Herdr steer: the false-negative send confirmation, before and after</h1>
<p class="sub">Real Muse Code 1.3.0-R3233.1 on real herdr 0.9.0, in an isolated Herdr lab on <code>--provider echo</code>.</p>

<h2>1. The live Muse composer that used to classify <code>unknown</code></h2>
<p class="sub">Captured with <code>herdr pane read --format ansi</code>: a TITLED opening rule, the truecolor <code>❯</code> row, the solid closing rule, then the footer.</p>
<pre>{ansi_to_html(tail(pane_ansi, 6))}</pre>

<h2>2. The same live pane read through the shared classifier at both revisions</h2>
<pre>{html.escape(summary)}</pre>

<h2>3. The same pane after one real steer through the adapter fm-send calls</h2>
<pre>{html.escape(tail(after, 7))}</pre>

<h2>4. What the captain sees at the CLI (real bin/fm-send.sh, faithful fake Muse pane)</h2>
<div class="cols">
 <div>
  <span class="tag bad">before the repair</span>
  <pre class="bad">{html.escape(before_tx)}</pre>
 </div>
 <div>
  <span class="tag good">after the repair</span>
  <pre class="good">{html.escape(after_tx)}</pre>
 </div>
</div>

<h2>5. Duplicate-send protection is unchanged</h2>
<p class="sub">Same fixed build, but the fake Muse pane swallows the Enter and keeps holding the text: the send still refuses to claim delivery.</p>
<pre class="bad">{html.escape(swallow_tx)}</pre>
"""

outfile = ev / "muse-send-confirmation-evidence.html"
outfile.write_text(page)
print(outfile)
