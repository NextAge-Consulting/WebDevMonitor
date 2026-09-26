#!/usr/bin/env node
/* Builds a Claude Design "Design System" artifact's files from a project's UI
 * package — the code is the source, the artifact a published view of it.
 *
 *   node .claude/skills/claude-design/scripts/build.mjs <path/to/design-system.config.mjs>
 *
 * Everything project-specific lives in the config (see
 * references/config-example.mjs): where the tokens, type roles and components
 * are, which components get previews and where their guidelines come from.
 *
 * Writes <package>/<out>/project/ — tokens.json, README.md, the cover, fonts,
 * asset-group READMEs, and the components: bundle.js (window.<namespace> on the
 * design page's React 18), bundle.css, index.d.ts, React 18 in components/lib,
 * and a preview and README per component — plus <out>/index-fields.json, the
 * keys of the artifact's index this build owns. Publishing is a separate,
 * interactive step (/ui-design publish-system): headless runs have no Artifact tool.
 *
 * Fails with a non-zero exit, naming each offender, when a token has no usage
 * comment, a value cannot be translated, a token fits no family, or a component
 * has no guidelines — never a silent drop. */

import { execSync } from 'node:child_process'
import { createHash } from 'node:crypto'
import fs from 'node:fs'
import path from 'node:path'
import { pathToFileURL } from 'node:url'
import * as esbuild from 'esbuild'
import { DEFAULT_THEME_SELECTORS, isColorValue, parseTokenBlocks, resolveColor } from './resolve.mjs'

const configPath = process.argv[2]
if (!configPath) {
  console.error('usage: build.mjs <path/to/design-system.config.mjs>')
  process.exit(2)
}
const CONFIG_FILE = path.resolve(configPath)
const CONFIG_DIR = path.dirname(CONFIG_FILE)
const CONFIG = (await import(pathToFileURL(CONFIG_FILE).href)).default
const REPO = execSync('git rev-parse --show-toplevel', { cwd: CONFIG_DIR }).toString().trim()
const PKG = path.join(REPO, CONFIG.package)
const OUT = path.join(PKG, CONFIG.out ?? 'dist/design-system')
const PROJECT = path.join(OUT, 'project')
const NS = CONFIG.namespace

// The sync is dated in the project's own zone: UTC would date an evening sync
// in the Americas as tomorrow. Required — there is no safe default zone.
let SYNC_DATE
try {
  SYNC_DATE = new Intl.DateTimeFormat('en-CA', { timeZone: CONFIG.timeZone, year: 'numeric', month: '2-digit', day: '2-digit' }).format(new Date())
} catch {
  SYNC_DATE = null
}
if (!CONFIG.timeZone || !SYNC_DATE) {
  console.error(`design-system build: the config needs \`timeZone\`, the project's IANA zone (e.g. 'America/Chicago') — got ${JSON.stringify(CONFIG.timeZone)}`)
  process.exit(2)
}

// React 18 for the design page's previews, carried as files the way the Design
// System type's own worked example does. Pinned, and checked against the hashes
// of the type's copies, so a changed CDN file fails the build instead of shipping.
const PAGE_REACT_VERSION = '18.3.1'
const PAGE_REACT = [
  {
    name: 'react',
    global: 'React',
    file: 'components/lib/react.production.min.js',
    url: `https://cdn.jsdelivr.net/npm/react@${PAGE_REACT_VERSION}/umd/react.production.min.js`,
    sha256: 'd949f1c3687aedadcedac85261865f29b17cd273997e7f6b2bfc53b2f9d4c4dd',
  },
  {
    name: 'react-dom',
    global: 'ReactDOM',
    file: 'components/lib/react-dom.production.min.js',
    url: `https://cdn.jsdelivr.net/npm/react-dom@${PAGE_REACT_VERSION}/umd/react-dom.production.min.js`,
    sha256: '35f4f974f4b2bcd44da73963347f8952e341f83909e4498227d4e26b98f66f0d',
  },
]

/* Components written for React 19 receive `ref` as an ordinary prop. Design
 * pages and canvases run React 18, which strips it — so a Radix trigger rendered
 * through a component (`asChild`) loses its anchor and the overlay never opens.
 * REF_AS_PROP restores React 19's behaviour on 18, for this bundle only: a plain
 * function component given a ref is rendered through a cached forwardRef wrapper
 * that hands the ref back in as a prop. Used by the JSX runtime shim (the
 * bundle's own JSX) and by the footer (components the page mounts by name). */
const REF_AS_PROP = `function refAsProp(R, cache, t) {
  var w = cache.get(t);
  if (!w) {
    w = R.forwardRef(function (props, ref) { return t(Object.assign({}, props, { ref: ref })); });
    w.displayName = t.displayName || t.name;
    cache.set(t, w);
  }
  return w;
}
function isPlainComponent(t) {
  return typeof t === 'function' && !(t.prototype && t.prototype.isReactComponent) && t.$$typeof === undefined;
}
function soleChild(R, props) {
  var c = props && props.children;
  if (Array.isArray(c) && c.length === 1) { c = c[0]; props = Object.assign({}, props, { children: c }); }
  // In the canvas editor every x-import sits in a display:contents host div, which
  // has no box: a trigger slotted onto it measures 0,0 and the overlay lands in the
  // corner. Give that host a box the size of what it wraps.
  if (props && props.asChild && R.isValidElement(c) && c.type === 'div' && /(^|\\s)sc-host-x(\\s|$)/.test(c.props.className || '')) {
    props = Object.assign({}, props, { children: R.cloneElement(c, { style: Object.assign({}, c.props.style, { display: 'inline-flex' }) }) });
  }
  return props;
}`

const problems = []
const notCarried = []
const families = {
  radius: new RegExp(CONFIG.families?.radius ?? '^radius-'),
  shadow: new RegExp(CONFIG.families?.shadow ?? '^shadow-'),
  skip: new RegExp(CONFIG.families?.skip ?? '^$'),
}

// ─── token CSS → per-theme environments ────────────────────────────────────
const blocks = CONFIG.tokens.flatMap((rel) => parseTokenBlocks(read(rel), CONFIG.themeSelectors ?? DEFAULT_THEME_SELECTORS))
const lightDecls = blocks.filter((b) => b.theme === 'light').flatMap((b) => b.decls)
const darkDecls = blocks.filter((b) => b.theme === 'dark').flatMap((b) => b.decls)
const lightEnv = new Map(lightDecls.map((d) => [d.name, d.value]))
const darkEnv = new Map([...lightEnv, ...darkDecls.map((d) => [d.name, d.value])])
const usageOf = new Map(lightDecls.map((d) => [d.name, d.usage]))

const colorNames = new Set(
  lightDecls
    .filter((d) => isColorValue(d.value) || (/^var\(--[\w-]+\)$/.test(d.value) && isColorValue(chase(d.value, lightEnv))))
    .map((d) => d.name),
)

function chase(v, env, depth = 0) {
  const ref = /^var\(--([\w-]+)\)$/.exec(v)
  return ref && depth < 16 ? chase(env.get(ref[1]) ?? '', env, depth + 1) : v
}

const colorTokens = []
for (const d of lightDecls) {
  if (!colorNames.has(d.name)) continue
  const value = {}
  for (const [theme, env] of [
    ['light', lightEnv],
    ['dark', darkEnv],
  ]) {
    try {
      value[theme] = resolveColor(env.get(d.name), env, colorNames)
    } catch (e) {
      problems.push(`--${d.name} (${theme}): ${e.message}`)
    }
  }
  if (value.dark === value.light) delete value.dark
  colorTokens.push({ name: d.name, value, usage: requireUsage(d.name) })
}

// Every other token lands in a family, or is one the config says the type roles
// or spacing consume.
const radius = []
const shadow = []
for (const d of lightDecls) {
  if (colorNames.has(d.name) || families.skip.test(d.name)) continue
  if (families.radius.test(d.name)) radius.push({ name: d.name, value: d.value, usage: requireUsage(d.name) })
  else if (families.shadow.test(d.name)) {
    const dark = darkEnv.get(d.name)
    shadow.push({ name: d.name, value: dark === d.value ? d.value : { light: d.value, dark }, usage: requireUsage(d.name) })
  } else problems.push(`--${d.name}: no design-system family for this token — map it in the config's families rather than dropping it`)
}

// Spacing: the framework's scale as named steps, plus named measurements the
// styles expose as spacing aliases (`--spacing-control: var(--size-control)`).
const stylesCss = CONFIG.styles ? read(CONFIG.styles) : ''
const spacing = (CONFIG.spacing?.steps ?? []).map((n) => ({
  name: `spacing-${n}`,
  value: `${n * CONFIG.spacing.base}px`,
  usage: `Step ${n} — \`p-${n}\`, \`gap-${n}\`, \`m-${n}\`.`,
}))
for (const m of stylesCss.matchAll(/--spacing-([\w-]+):\s*var\(--([\w-]+)\)/g)) {
  spacing.push({ name: `spacing-${m[1]}`, value: lightEnv.get(m[2]), usage: requireUsage(m[2]) })
}

// ─── type roles ────────────────────────────────────────────────────────────
const groups = []
if (CONFIG.typeRoles) {
  const typeCss = read(CONFIG.typeRoles.file)
  const prefix = CONFIG.typeRoles.utilityPrefix ?? 'type-'
  const scale = (v) => v?.replace(/var\(--([\w-]+)\)/, (_, n) => lightEnv.get(n))
  let group = null
  const items = [
    ...[...typeCss.matchAll(/\/\*\s*─+\s*([^─*]+?)\s*─+\s*\*\//g)].map((m) => ({ at: m.index, header: m[1].trim() })),
    ...[...typeCss.matchAll(new RegExp(`@utility ${prefix}([\\w-]+)\\s*\\{([\\s\\S]*?)\\n\\}`, 'g'))].map((m) => ({ at: m.index, name: m[1], body: m[2] })),
  ].sort((a, b) => a.at - b.at)
  for (const it of items) {
    if (it.header) {
      group = { name: it.header.charAt(0).toUpperCase() + it.header.slice(1), family: 'sans', styles: [] }
      groups.push(group)
      continue
    }
    const before = typeCss.slice(0, it.at).trimEnd()
    const c = /\/\*((?:(?!\*\/)[\s\S])*)\*\/$/.exec(before)
    const usage = c && !/─|={5}/.test(c[1]) ? c[1].replace(/\s+/g, ' ').trim() : ''
    if (!usage) problems.push(`${prefix}${it.name}: no usage comment above it in ${CONFIG.typeRoles.file}`)
    const base = it.body.replace(/@media[\s\S]*?\}/, '')
    const declared = Object.fromEntries([...base.matchAll(/(?:^|\n)\s*([\w-]+):\s*([^;]+);/g)].map((m) => [m[1], m[2].trim()]))
    const get = (k) => declared[k]
    const style = {
      name: it.name,
      fontSize: scale(get('font-size')),
      lineHeight: scale(get('line-height')),
      fontWeight: Number(scale(get('font-weight'))),
      usage,
    }
    const ls = get('letter-spacing')
    if (ls) style.letterSpacing = scale(ls)
    if (get('font-family')) style.family = 'mono'
    if (!style.fontSize || !style.lineHeight || !style.fontWeight) problems.push(`${prefix}${it.name}: missing size, line height or weight`)
    if (/@media/.test(it.body)) notCarried.push(`\`${prefix}${it.name}\` changes size at a breakpoint; the format holds one, so it carries the base size (its usage note names the other).`)
    if (/font-variant-numeric/.test(it.body)) notCarried.push(`\`${prefix}${it.name}\` sets \`font-variant-numeric\`, which the format has no field for.`)
    if (!group) problems.push(`${prefix}${it.name}: sits above the first group header in ${CONFIG.typeRoles.file}`)
    else group.styles.push(style)
  }
}

// ─── fonts: variable fonts the styles import from @fontsource-variable ─────
const fonts = []
for (const m of stylesCss.matchAll(/@import\s+"@fontsource-variable\/([\w-]+)"/g)) {
  const pkg = m[1]
  const file = `${pkg}-latin-wght-normal.woff2`
  const src = path.join(REPO, 'node_modules/@fontsource-variable', pkg, 'files', file)
  if (!fs.existsSync(src)) {
    problems.push(`font @fontsource-variable/${pkg}: ${file} not found — run npm ci`)
    continue
  }
  fonts.push({ src, entry: { family: `${pkg.charAt(0).toUpperCase()}${pkg.slice(1)} Variable`, file: `fonts/${file}`, weight: '100 900', style: 'normal' } })
}

// ─── components: guidelines, from their single source ──────────────────────
const docSources = CONFIG.docSources ?? {}
const inventory = docSources.inventory ? readRepo(docSources.inventory) : ''
const designDoc = docSources.design ? readRepo(docSources.design) : ''
const COMPONENTS = CONFIG.components ?? []
const componentDocs = new Map()
for (const c of COMPONENTS) {
  const text = componentDoc(c)
  if (!text) problems.push(`${c.name}: no guidelines found for doc ${JSON.stringify(c.doc)}`)
  componentDocs.set(c.name, text)
}

if (problems.length) {
  console.error(`design-system build: ${problems.length} problem(s) — nothing written.\n`)
  for (const p of problems) console.error(`  ✗ ${p}`)
  process.exit(1)
}

// ─── write ─────────────────────────────────────────────────────────────────
const ref = gitRef()
const tokens = {
  name: CONFIG.title,
  version: 1,
  meta: {
    source: 'repo',
    package: CONFIG.package,
    ref,
    paths: {
      tokens: [...CONFIG.tokens, ...(CONFIG.typeRoles ? [CONFIG.typeRoles.file] : [])].map((r) => path.posix.join(CONFIG.package, r)),
      docs: CONFIG.readme?.source ? [CONFIG.readme.source] : [],
    },
    synced: SYNC_DATE,
  },
  color: {
    themes: [
      { id: 'light', name: 'Light' },
      { id: 'dark', name: 'Dark' },
    ],
    tokens: colorTokens,
  },
  type: {
    fonts: fonts.map((f) => f.entry),
    families: Object.fromEntries(Object.entries(CONFIG.typeFamilies ?? {}).map(([k, token]) => [k, lightEnv.get(token)])),
    groups,
  },
  spacing: { tokens: spacing },
  radius: { tokens: radius },
  shadow: { tokens: shadow },
}

fs.rmSync(OUT, { recursive: true, force: true })
fs.mkdirSync(path.join(PROJECT, 'fonts'), { recursive: true })
fs.writeFileSync(path.join(PROJECT, 'tokens.json'), `${JSON.stringify(tokens, null, 2)}\n`)
for (const f of fonts) fs.copyFileSync(f.src, path.join(PROJECT, f.entry.file))
if (CONFIG.cover) {
  fs.mkdirSync(path.join(PROJECT, 'components/Cover'), { recursive: true })
  fs.copyFileSync(path.join(CONFIG_DIR, CONFIG.cover), path.join(PROJECT, 'components/Cover/preview.html'))
}
// Asset-group READMEs are text files; the images they describe are uploads the
// publish step names in the index.
if (CONFIG.assets) fs.cpSync(path.join(CONFIG_DIR, CONFIG.assets), path.join(PROJECT, 'assets'), { recursive: true })
fs.writeFileSync(path.join(PROJECT, 'README.md'), readme())
await buildComponents()

fs.writeFileSync(
  path.join(OUT, 'index-fields.json'),
  `${JSON.stringify(
    {
      title: CONFIG.title,
      namespace: NS,
      libraries: PAGE_REACT.map(({ name, global, file }) => ({ name, version: PAGE_REACT_VERSION, global, file })),
      lastChange: { by: 'Claude', via: `Claude Code · ${CONFIG.package}@${ref}`, note: `Synced from ${CONFIG.package}@${ref}.` },
    },
    null,
    2,
  )}\n`,
)

const styleCount = groups.reduce((n, g) => n + g.styles.length, 0)
console.log(
  `design-system build: ${colorTokens.length} colours, ${styleCount} type roles, ${spacing.length} spacing, ${radius.length} radii, ${shadow.length} shadow, ${fonts.length} font, ${COMPONENTS.length} components → ${path.relative(REPO, OUT)}`,
)

// ─── helpers ───────────────────────────────────────────────────────────────
async function buildComponents() {
  const dir = path.join(PROJECT, 'components')

  // components/lib: the page's React, fetched and hash-checked.
  fs.mkdirSync(path.join(dir, 'lib'), { recursive: true })
  for (const lib of PAGE_REACT) {
    const res = await fetch(lib.url)
    if (!res.ok) throw new Error(`could not fetch ${lib.url}: HTTP ${res.status}`)
    const bytes = Buffer.from(await res.arrayBuffer())
    const got = createHash('sha256').update(bytes).digest('hex')
    if (got !== lib.sha256) throw new Error(`${lib.url} changed: sha256 ${got}, expected ${lib.sha256}`)
    fs.writeFileSync(path.join(PROJECT, lib.file), bytes)
  }

  // bundle.css: the package's own CSS build, with the theme classes moved to the
  // page's attribute and @font-face removed (fonts come from tokens.json). A
  // prefers-color-scheme rule passes through, so a design follows the OS unless
  // it sets data-theme.
  execSync(CONFIG.css.build, { cwd: PKG, stdio: 'ignore' })
  let css = fs.readFileSync(path.join(PKG, CONFIG.css.file), 'utf8')
  css = css.replace(/@font-face\s*\{[^}]*\}/g, '')
  for (const [theme, cls] of [['dark', CONFIG.css.darkClass ?? '.dark'], ['light', CONFIG.css.lightClass ?? '.light']]) {
    const escaped = cls.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')
    css = css.replace(new RegExp(`(^|[\\s,{}(])${escaped}(?=[\\s,{:)])`, 'g'), `$1[data-theme="${theme}"]`)
  }
  if (/<\/style/i.test(css)) throw new Error('bundle.css contains "</style" — it would end the inline element')
  fs.writeFileSync(path.join(dir, 'bundle.css'), css)

  // bundle.js: one classic script assigning window.<namespace>, reading React
  // from the page. The entry is generated: the feed barrel, plus the icon set.
  const entry = path.join(OUT, 'entry.mjs')
  const icons = CONFIG.icons
  fs.writeFileSync(
    entry,
    `export * from ${JSON.stringify(path.join(PKG, CONFIG.feed))}\n${
      icons
        ? `import * as React from 'react'\nimport { icons } from ${JSON.stringify(icons)}\nexport { icons }\nexport function Icon({ name, ...props }) {\n  const Glyph = icons[name]\n  if (!Glyph) throw new Error('Unknown icon "' + name + '"')\n  return React.createElement(Glyph, props)\n}\n`
        : ''
    }`,
  )
  const result = await esbuild.build({
    entryPoints: [entry],
    bundle: true,
    format: 'iife',
    globalName: NS,
    platform: 'browser',
    target: 'es2020',
    minify: true,
    write: false,
    jsx: 'automatic',
    tsconfig: path.join(PKG, CONFIG.tsconfig ?? 'tsconfig.json'),
    define: { 'process.env.NODE_ENV': '"production"' },
    plugins: [pageReact()],
    logLevel: 'silent',
    // Components the page mounts by name (a preview, a canvas x-import, Radix
    // cloning a trigger) get the same ref-as-prop wrapper as the bundle's own
    // JSX, and JSX's children semantics: a canvas passes an x-import's children
    // as an array even when there is one, and a Radix `asChild` trigger refuses
    // an array — so a one-element array is handed over as the element itself.
    footer: {
      js: `${REF_AS_PROP}
${NS} = (function (ns) {
  var R = window.React, out = {};
  for (var k in ns) {
    var v = ns[k];
    if (!/^[A-Z]/.test(k)) { out[k] = v; continue; }
    if (isPlainComponent(v)) {
      out[k] = (function (inner) {
        var w = R.forwardRef(function (props, ref) { return inner(Object.assign({}, soleChild(R, props), { ref: ref })); });
        w.displayName = inner.displayName || inner.name;
        return w;
      })(v);
    } else if (v && v.$$typeof) {
      out[k] = (function (inner) {
        var w = R.forwardRef(function (props, ref) { return R.createElement(inner, Object.assign({}, soleChild(R, props), { ref: ref })); });
        w.displayName = inner.displayName;
        return w;
      })(v);
    } else out[k] = v;
  }
  return out;
})(${NS});`,
    },
  })
  fs.rmSync(entry)
  const header = `/* @ds-bundle: ${JSON.stringify({ format: 4, namespace: NS, components: COMPONENTS.map((c) => ({ name: c.name })) })} */`
  const js = result.outputFiles[0].text
  if (/<\/script|<!--/i.test(js)) throw new Error('bundle.js contains "</script" or "<!--" — the page inlines it')
  fs.writeFileSync(path.join(dir, 'bundle.js'), `${header}\n${js}`)

  // index.d.ts: the package's own declarations, concatenated — documentation only.
  if (CONFIG.types) {
    execSync(CONFIG.types.build, { cwd: PKG, stdio: 'ignore' })
    const decls = []
    const feedDir = path.dirname(CONFIG.feed)
    const srcRoot = path.join(PKG, feedDir)
    for (const mod of fs.readFileSync(path.join(PKG, CONFIG.feed), 'utf8').matchAll(/from ["']\.\/([\w/.-]+)["']/g)) {
      const rel = mod[1].replace(/\.(tsx?|jsx?)$/, '')
      const file = path.join(PKG, CONFIG.types.dir, path.relative(srcRoot, path.join(srcRoot, rel)) + '.d.ts')
      if (!fs.existsSync(file)) throw new Error(`no declarations emitted for ${rel}`)
      decls.push(`// ─── ${rel} ───\n${fs.readFileSync(file, 'utf8').replace(/^import .*$/gm, '').trim()}`)
    }
    if (icons) {
      decls.push(`// ─── icons ───\n/** Any icon from ${icons} by name: <Icon name="Search" />. */\nexport declare function Icon(props: { name: string; className?: string }): JSX.Element;\n/** The whole icon set, for an \`icon\` prop: icon={${NS}.icons.Search}. */\nexport declare const icons: Record<string, unknown>;`)
    }
    fs.writeFileSync(path.join(dir, 'index.d.ts'), `${decls.join('\n\n')}\n`)
  }

  // one preview and one README per component
  for (const c of COMPONENTS) {
    const cdir = path.join(dir, c.name)
    fs.mkdirSync(cdir, { recursive: true })
    const width = c.width ? ` width=${c.width}` : ''
    // The script is the preview code the project's own config declares for this
    // component — written by the repository's authors, never outside input.
    fs.writeFileSync(
      path.join(cdir, 'preview.html'), // nosemgrep: javascript.lang.security.audit.unknown-value-with-script-tag.unknown-value-with-script-tag
      `<!-- @dsCard group="${c.group}" height=${c.height}${width} -->
<!doctype html>
<html>
<head><meta charset="utf-8"><title>${c.name} — preview</title>
<style>${CONFIG.previewStyle ?? 'body{margin:0;padding:16px}'}</style>
</head>
<body>
<div id="root"></div>
<script>
  var U = window.${NS}, h = React.createElement;
  function icon(name) { return U.icons[name]; }
  ReactDOM.createRoot(document.getElementById('root')).render(${c.render.replace(/\n\s*/g, ' ')});
</script>
</body>
</html>
`,
    )
    fs.writeFileSync(path.join(cdir, 'README.md'), `# ${c.name}\n\n${componentDocs.get(c.name)}\n`)
  }
}

/** Resolve react, react-dom and the JSX runtime to the page's globals. */
function pageReact() {
  const shims = {
    react: 'module.exports = window.React',
    'react-dom': 'module.exports = window.ReactDOM',
    'react-dom/client': 'module.exports = window.ReactDOM',
    'react/jsx-runtime': `var R = window.React, cache = new WeakMap(); ${REF_AS_PROP}
function j(t, p, k) {
  if (p && p.ref != null && isPlainComponent(t)) t = refAsProp(R, cache, t);
  return R.createElement(t, k === undefined ? p : Object.assign({}, p, { key: k }));
}
module.exports = { jsx: j, jsxs: j, Fragment: R.Fragment };`,
  }
  return {
    name: 'page-react',
    setup(b) {
      b.onResolve({ filter: /^(react|react-dom|react-dom\/client|react\/jsx-runtime)$/ }, (a) => ({ path: a.path, namespace: 'page-react' }))
      b.onLoad({ filter: /.*/, namespace: 'page-react' }, (a) => ({ contents: shims[a.path], loader: 'js' }))
    },
  }
}

/** A component's guidelines from its one source; empty when that source has none.
 *   { inventory: "Name" } → that `| \`Name\` |` row of the UI inventory
 *   { design: "Heading" } → that `###` section of the design doc
 *   { source: "path" }    → the doc comment above the component in <package>/<sourceRoot>/<path>,
 *                            else that file's leading doc comment */
function componentDoc(c) {
  if (c.doc?.inventory) {
    const row = inventory
      .split('\n')
      .find((l) => l.startsWith(`| \`${c.doc.inventory}\``) || l.startsWith(`| \`${c.doc.inventory}\` /`))
    return row ? row.split('|')[2].trim() : ''
  }
  if (c.doc?.design) {
    const start = designDoc.indexOf(`\n### ${c.doc.design}\n`)
    if (start < 0) return ''
    const next = designDoc.slice(start + 1).search(/\n#{2,3} /)
    return designDoc.slice(start + 1, next < 0 ? undefined : start + 1 + next).replace(/^### .*\n/, '').trim()
  }
  if (c.doc?.source) {
    const src = fs.readFileSync(path.join(PKG, docSources.sourceRoot ?? 'src', c.doc.source), 'utf8')
    const at = functionAt(src, c.name)
    const m =
      (at >= 0 ? /\/\*\*((?:(?!\*\/)[\s\S])*)\*\/\s*(?:export\s+)?$/.exec(src.slice(0, at)) : null) ??
      /^(?:import[^\n]*\n|\s*\n)*\/\*\*((?:(?!\*\/)[\s\S])*)\*\//.exec(src)
    return m ? m[1].replace(/^\s*\* ?/gm, '').trim() : ''
  }
  return ''
}

/** Where `function <name>` is declared in a source file, by plain string search;
 * -1 when it is not. */
function functionAt(src, name) {
  const needle = `function ${name}`
  for (let i = src.indexOf(needle); i >= 0; i = src.indexOf(needle, i + 1)) {
    if (!/[\w$]/.test(src[i + needle.length] ?? '')) return i
  }
  return -1
}

function read(rel) {
  return fs.readFileSync(path.join(PKG, rel), 'utf8')
}

function readRepo(rel) {
  return fs.readFileSync(path.join(REPO, rel), 'utf8')
}

function requireUsage(name) {
  const u = usageOf.get(name)
  if (!u) problems.push(`--${name}: no usage comment — every token says what it is for`)
  return u ?? ''
}

function gitRef() {
  const sha = execSync('git rev-parse --short HEAD', { cwd: REPO }).toString().trim()
  const watched = [CONFIG.package, ...(CONFIG.readme?.source ? [CONFIG.readme.source] : [])].join(' ')
  const dirty = execSync(`git status --porcelain -- ${watched}`, { cwd: REPO }).toString().trim()
  return dirty ? `${sha}+uncommitted` : sha
}

function readme() {
  const cfg = CONFIG.readme ?? {}
  let sections = []
  if (cfg.source) {
    const doc = readRepo(cfg.source)
    const body = doc.slice(Math.max(0, doc.indexOf('\n# ')))
    sections = (cfg.sections ?? []).map((title) => {
      const start = body.indexOf(`\n## ${title}\n`)
      if (start < 0) throw new Error(`${cfg.source} has no "## ${title}" section`)
      const next = body.indexOf('\n## ', start + 1)
      return body.slice(start + 1, next < 0 ? undefined : next).trim()
    })
  }
  const vocab = cfg.vocabulary?.length
    ? ['## Writing it in code', '', ...(cfg.vocabularyIntro ? [cfg.vocabularyIntro, ''] : []), '| What | Class |', '|---|---|', ...cfg.vocabulary.map(([what, cls]) => `| ${what} | ${cls} |`)].join('\n')
    : ''
  const notPreviewed = Object.entries(CONFIG.notPreviewed ?? {}).map(([n, why]) => `\`${n}\` is in the bundle but has no preview: ${why}.`)
  const all = [...notCarried, ...notPreviewed]
  const notes = all.length ? `\n\n## Not carried by the format\n\n${all.map((n) => `- ${n}`).join('\n')}` : ''
  return `# ${CONFIG.title}\n\n${CONFIG.tagline ?? ''}\n\nSynced from the repository's UI package (\`${CONFIG.package}\`, ${ref}). The code is the source: change a token there and re-sync, never here.\n\n${vocab}${vocab ? '\n\n' : ''}${sections.join('\n\n')}${notes}\n`
}
