// Render the exact markdown the loop posted into the simulated forge as the PR
// surface a reviewer sees: the PR description plus every round comment, in
// order, through a GitHub-flavored markdown renderer (marked, GFM + breaks off,
// matching GitHub's comment rendering of soft line breaks).
//
// Nothing here rewrites the markdown: each card's HTML is marked's render of
// one file byte-for-byte as gh-axi received it.
//
// Usage: node render-pr-surface.js <forge-dir> <pr-number> <out.html>
const fs = require('fs')
const path = require('path')
const MARKED = '/Users/npayette/.npm/_npx/4b4c857f6efdfb61/node_modules/marked'
const { marked } = require(MARKED)
marked.setOptions({ gfm: true, breaks: false, headerIds: false, mangle: false })

const [forge, num, out] = process.argv.slice(2)
const body = fs.readFileSync(path.join(forge, `body-${num}.md`), 'utf8')
const dir = path.join(forge, 'comments', num)
const files = fs.readdirSync(dir).filter((f) => f.endsWith('.md')).sort()

const verdictClass = (md) =>
  /round \d+ GREEN/.test(md) ? 'green' : /round \d+ RED/.test(md) ? 'red' : 'neutral'

const cards = [
  `<div class="card body"><div class="hdr"><span class="who">firstmate</span> pull request description</div><div class="content">${marked.parse(body)}</div></div>`,
]
files.forEach((f, i) => {
  const md = fs.readFileSync(path.join(dir, f), 'utf8')
  cards.push(
    `<div class="card ${verdictClass(md)}"><div class="hdr"><span class="who">firstmate</span> commented &middot; comment ${i + 1} <span class="src">(${f})</span></div><div class="content">${marked.parse(md)}</div></div>`
  )
})

fs.writeFileSync(
  out,
  `<!doctype html><html><head><meta charset="utf-8"><title>Adversarial-review evidence in PR #${num}</title>
<style>
 body { font: 14px/1.55 -apple-system,"Segoe UI",Helvetica,Arial,sans-serif; background:#f6f8fa; color:#1f2328; margin:0; padding:28px; }
 .wrap { max-width: 940px; margin: 0 auto; }
 h1 { font-size: 21px; margin: 4px 0 14px; }
 .num { color:#59636e; font-weight:400; }
 .lede { color:#59636e; font-size:13px; margin-bottom:10px; }
 .card { background:#fff; border:1px solid #d1d9e0; border-radius:8px; margin-bottom:14px; overflow:hidden; }
 .hdr { background:#f6f8fa; border-bottom:1px solid #d1d9e0; padding:7px 14px; font-size:12px; color:#59636e; }
 .who { font-weight:600; color:#1f2328; }
 .src { color:#8c959f; }
 .content { padding: 11px 16px; }
 .content h2 { font-size:16px; margin:2px 0 10px; padding:0; border:0; }
 .content h3 { font-size:14px; margin:16px 0 8px; }
 .green { border-left:4px solid #1a7f37; } .green .content h2 { color:#1a7f37; }
 .red { border-left:4px solid #cf222e; } .red .content h2 { color:#cf222e; }
 .body { border-left:4px solid #0969da; }
 code { background:#eff1f3; border-radius:4px; padding:1px 5px; font-size:12px; word-break:break-all; }
 ul { margin:6px 0 10px; padding-left:20px; } p { margin:6px 0; }
 details { border:1px solid #d1d9e0; border-radius:6px; padding:8px 12px; margin:8px 0; background:#f6f8fa; }
 summary { cursor:pointer; font-weight:600; font-size:13px; }
 pre { background:#f6f8fa; color:#1f2328; border:1px solid #d1d9e0; padding:10px 12px; border-radius:6px; overflow:auto; font:12px/1.5 ui-monospace,SFMono-Regular,Menlo,monospace; white-space:pre; }
 pre code { background:none; padding:0; font-size:12px; }
</style></head><body><div class="wrap">
<div class="lede">The exact markdown <code>bin/fm-adversarial-review.sh</code> posted through <code>gh-axi</code> during the end-to-end run, rendered as GitHub renders a PR comment. Simulated forge, real script output, no hand editing.</div>
<h1>Add the launch banner <span class="num">#${num}</span></h1>
${cards.join('\n')}
</div></body></html>`
)
console.log(`rendered ${files.length + 1} PR-surface cards -> ${out}`)
