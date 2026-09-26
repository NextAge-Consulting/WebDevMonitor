#!/usr/bin/env node
/* Renders every component preview the way the design system page does — React 18
 * first, then bundle.css and bundle.js — and fails on a script error, a React
 * error, a preview that draws nothing anywhere on the page (overlays portal
 * outside the preview's root), an overlay preview whose overlay does not open,
 * or an overlay that opens detached from its trigger. Each preview also renders
 * the way a Design canvas mounts components: children always handed over as an
 * array, and every mounted component wrapped in the editor's display:contents
 * host element. Run after build.mjs:
 *
 *   node .claude/skills/claude-design/scripts/render-check.mjs <path/to/design-system.config.mjs>
 *
 * Drives agent-browser's Chromium, headless, in its own named session. Writes
 * light, dark and canvas screenshots of each preview to <out>/render/ for
 * review. */

import { execFileSync, execSync } from 'node:child_process'
import fs from 'node:fs'
import path from 'node:path'
import { pathToFileURL } from 'node:url'

const configPath = process.argv[2]
if (!configPath) {
  console.error('usage: render-check.mjs <path/to/design-system.config.mjs>')
  process.exit(2)
}
const CONFIG_FILE = path.resolve(configPath)
const CONFIG = (await import(pathToFileURL(CONFIG_FILE).href)).default
const REPO = execSync('git rev-parse --show-toplevel', { cwd: path.dirname(CONFIG_FILE) }).toString().trim()
const OUT = path.join(REPO, CONFIG.package, CONFIG.out ?? 'dist/design-system')
const COMPONENTS_DIR = path.join(OUT, 'project/components')
const RENDER = path.join(OUT, 'render')
const SESSION = `${path.basename(REPO)}-design-system`
// The React the build carries in components/lib — exactly what the page loads.
const REACT = '../project/components/lib/react.production.min.js'
const REACT_DOM = '../project/components/lib/react-dom.production.min.js'

if (!fs.existsSync(path.join(COMPONENTS_DIR, 'bundle.js'))) {
  console.error('render-check: no build found — run build.mjs first')
  process.exit(1)
}

fs.rmSync(RENDER, { recursive: true, force: true })
fs.mkdirSync(RENDER, { recursive: true })

const browser = (...args) => execFileSync('agent-browser', ['--session', SESSION, ...args], { encoding: 'utf8' })
const failures = []
const components = CONFIG.components ?? []

const PROBE = `JSON.stringify({
  errors: window.__errors,
  drawn: [].filter.call(document.body.querySelectorAll("*"), function (el) { var r = el.getBoundingClientRect(); return r.width > 8 && r.height > 8 && el.id !== "root" }).length,
  overlay: [].filter.call(document.querySelectorAll("[data-radix-popper-content-wrapper], [role=dialog], [role=tooltip], [role=menu], [role=listbox]"), function (el) { var r = el.getBoundingClientRect(); return r.width > 8 && r.height > 8 }).length,
  detached: (function () {
    var o = document.querySelector("[data-radix-popper-content-wrapper]");
    var t = document.querySelector("[aria-expanded=true], [data-state=delayed-open], [data-state=instant-open]");
    if (!o || !t) return false;
    var a = o.firstElementChild.getBoundingClientRect(), b = t.getBoundingClientRect();
    if (b.width === 0) return true;
    var gap = Math.min(Math.abs(a.top - b.bottom), Math.abs(b.top - a.bottom));
    return gap > 24 || a.right < b.left || a.left > b.right;
  })()
})`

// How a canvas hands components their children, and the host it wraps them in.
const CANVAS_H =
  'h = function (t, p) { var k = [].slice.call(arguments, 2); var el = k.length ? React.createElement(t, Object.assign({}, p, { children: k })) : React.createElement(t, p); return typeof t === "string" ? el : React.createElement("div", { className: "sc-host-x", "data-dc-tpl": "t", style: { display: "contents" }, key: p && p.key }, el) }'

try {
  browser('set', 'viewport', '1200', '800')
  for (const c of components) {
    const preview = fs.readFileSync(path.join(COMPONENTS_DIR, c.name, 'preview.html'), 'utf8')
    const body = /<body>([\s\S]*)<\/body>/.exec(preview)[1]
    const style = /<style>([\s\S]*?)<\/style>/.exec(preview)?.[1] ?? ''
    for (const mode of ['light', 'dark', 'canvas']) {
      const harness = path.join(RENDER, `${c.name}.${mode}.html`)
      const mount = mode === 'canvas' ? body.replace('h = React.createElement', CANVAS_H) : body
      // A local harness page around this repository's own build output, opened
      // headless by this check and never served — no outside input reaches it.
      fs.writeFileSync(
        harness, // nosemgrep: javascript.lang.security.audit.unknown-value-with-script-tag.unknown-value-with-script-tag
        `<!doctype html><html data-theme="${mode === 'dark' ? 'dark' : 'light'}"><head><meta charset="utf-8">
<script>window.__errors=[];addEventListener('error',function(e){__errors.push(String(e.message))});var ce=console.error;console.error=function(){__errors.push([].slice.call(arguments).join(' '));ce.apply(console,arguments)};</script>
<link rel="stylesheet" href="../project/components/bundle.css"><style>${style}</style>
<script src="${REACT}"></script><script src="${REACT_DOM}"></script>
<script src="../project/components/bundle.js"></script>
</head><body>${mount}</body></html>`,
      )
      browser('open', `file://${harness}`)
      browser('wait', '600')
      const report = JSON.parse(JSON.parse(browser('eval', PROBE)))
      browser('screenshot', path.join(RENDER, `${c.name}.${mode}.png`))
      if (report.errors.length) failures.push(`${c.name} (${mode}): ${report.errors[0].slice(0, 200)}`)
      else if (report.drawn === 0) failures.push(`${c.name} (${mode}): drew nothing`)
      else if (c.cardMode === 'overlay' && report.overlay === 0) failures.push(`${c.name} (${mode}): the overlay did not open`)
      else if (report.detached) failures.push(`${c.name} (${mode}): the overlay is not attached to its trigger`)
    }
  }
} finally {
  try {
    browser('close')
  } catch {}
}

if (failures.length) {
  console.error(`render-check: ${failures.length} failure(s)\n`)
  for (const f of failures) console.error(`  ✗ ${f}`)
  process.exit(1)
}
console.log(`render-check: ${components.length} components render in light, dark and canvas mounting — screenshots in ${path.relative(process.cwd(), RENDER)}`)
