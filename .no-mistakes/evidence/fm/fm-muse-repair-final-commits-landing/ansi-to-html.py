#!/usr/bin/env python3
"""Render a captured herdr pane (ANSI) as HTML so a reviewer can see the real
Muse composer surface the shared classifier reads.

Usage: ansi-to-html.py <capture.ansi> <title> > out.html
"""
import html
import re
import sys

SGR = re.compile(r"\x1b\[([0-9;]*)m")
OTHER_CSI = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
BASIC = {
    30: "#1b1f23", 31: "#d1373a", 32: "#3fa34d", 33: "#c8a415", 34: "#3b7dd8",
    35: "#a05fd3", 36: "#2aa8a8", 37: "#c9d1d9",
    90: "#6b7681", 91: "#ff6b6e", 92: "#5fd47a", 93: "#e6c84a", 94: "#6fa8ff",
    95: "#c58bf0", 96: "#5fd4d4", 97: "#f0f6fc",
}


def style(state):
    bits = []
    if state.get("fg"):
        bits.append("color:%s" % state["fg"])
    if state.get("bg"):
        bits.append("background:%s" % state["bg"])
    if state.get("bold"):
        bits.append("font-weight:700")
    if state.get("dim"):
        bits.append("opacity:.55")
    if state.get("rev"):
        bits.append("filter:invert(1)")
    return ";".join(bits)


def apply_codes(state, codes):
    i = 0
    while i < len(codes):
        c = codes[i]
        if c in (0,):
            state.clear()
        elif c == 1:
            state["bold"] = True
        elif c == 2:
            state["dim"] = True
        elif c == 7:
            state["rev"] = True
        elif c in (22,):
            state.pop("bold", None)
            state.pop("dim", None)
        elif c == 27:
            state.pop("rev", None)
        elif c == 39:
            state.pop("fg", None)
        elif c == 49:
            state.pop("bg", None)
        elif c in BASIC:
            state["fg"] = BASIC[c]
        elif c - 10 in BASIC and 40 <= c <= 47 or 100 <= c <= 107:
            state["bg"] = BASIC.get(c - 10, BASIC.get(c - 10 + 60))
        elif c in (38, 48) and i + 1 < len(codes):
            key = "fg" if c == 38 else "bg"
            if codes[i + 1] == 2 and i + 4 < len(codes):
                state[key] = "rgb(%d,%d,%d)" % tuple(codes[i + 2:i + 5])
                i += 4
            elif codes[i + 1] == 5 and i + 2 < len(codes):
                i += 2
        i += 1


def render(text):
    out = []
    state = {}
    pos = 0
    open_span = False
    for m in SGR.finditer(text):
        chunk = text[pos:m.start()]
        if chunk:
            st = style(state)
            if st:
                out.append('<span style="%s">%s</span>' % (st, html.escape(chunk)))
            else:
                out.append(html.escape(chunk))
        raw = m.group(1)
        codes = [int(p) if p else 0 for p in raw.split(";")] if raw else [0]
        apply_codes(state, codes)
        pos = m.end()
    out.append(html.escape(text[pos:]))
    return "".join(out)


def main():
    src, title = sys.argv[1], sys.argv[2]
    with open(src, "r", encoding="utf-8", errors="replace") as fh:
        data = fh.read()
    data = data.replace("\r\n", "\n").replace("\r", "\n")
    data = OTHER_CSI.sub("", data)
    body = render(data)
    print(
        "<!doctype html><meta charset=utf-8><title>%s</title>"
        "<style>body{background:#0d1117;color:#c9d1d9;font:13px/1.35 "
        "'SF Mono',Menlo,Consolas,monospace;padding:20px}"
        "h1{font:600 14px/1.4 -apple-system,system-ui,sans-serif;color:#8b949e}"
        "pre{white-space:pre;overflow-x:auto;border:1px solid #30363d;"
        "border-radius:6px;padding:14px;background:#010409}</style>"
        "<h1>%s</h1><pre>%s</pre>" % (html.escape(title), html.escape(title), body)
    )


main()
