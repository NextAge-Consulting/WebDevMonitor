/* Pure functions that turn the UI package's token CSS into a Claude Design
 * "Design System" artifact's tokens.json. No filesystem — build.mjs does I/O.
 *
 * The artifact reads a narrower colour language than a browser: literals and
 * aliases only — no var(), no color-mix(), no named colours. The source keeps its
 * references (a dark token defined as a mix of another follows that token when
 * it changes); this module resolves them per theme at sync time. Anything it does
 * not recognise throws, so a new construct fails the sync instead of dropping a
 * token silently — the artifact would otherwise fill a missing dark value with the
 * light one. */

const HEADER = /─/;

/** The selectors a token file may use for its light and dark themes, unless the
 * project's config names its own. */
export const DEFAULT_THEME_SELECTORS = {
  light: [':root', 'html'],
  dark: ['.dark', ':root.dark', 'html.dark', '[data-theme="dark"]', ':root[data-theme="dark"]', 'html[data-theme="dark"]'],
};

const normalizeSelector = (s) => s.replace(/\s+/g, '').replace(/['"]/g, '');

/** Parse the top-level blocks that declare custom properties into declarations
 * with their usage comment: the comment directly above a declaration, or trailing
 * it on the same line. A comment containing `─` is a group header and belongs to
 * no token. Each block is `light` or `dark`; a block declaring tokens under any
 * other selector throws, because skipping it would silently give its tokens the
 * light values. A light block holding only `@variant dark { … }` — Tailwind's
 * way of writing dark values once for both the OS preference and a class — is
 * a dark block. */
export function parseTokenBlocks(css, selectors = DEFAULT_THEME_SELECTORS) {
  const light = new Set(selectors.light.map(normalizeSelector));
  const dark = new Set(selectors.dark.map(normalizeSelector));
  const blocks = [];
  const flat = css.replace(
    /(^|\n)([^\n{}]+?)\s*\{\s*\n\s*@variant\s+([\w-]+)\s*\{([^{}]*)\n\s*\}\s*\n\}/g,
    (_, lead, selector, variant, body) => {
      if (!light.has(normalizeSelector(selector.trim())) || variant !== 'dark')
        throw new Error(`token block under an unrecognised variant: ${selector.trim()} @variant ${variant}`);
      if (/^\s*--[\w-]+\s*:/m.test(body)) blocks.push({ selector: `${selector.trim()} @variant dark`, theme: 'dark', decls: parseDecls(body) });
      return lead;
    },
  );
  for (const m of flat.matchAll(/(^|\n)([^\n{}]+?)\s*\{([^{}]*)\n\}/g)) {
    const selector = m[2].trim();
    if (!/^\s*--[\w-]+\s*:/m.test(m[3])) continue;
    const key = normalizeSelector(selector);
    const theme = light.has(key) ? 'light' : dark.has(key) ? 'dark' : null;
    if (!theme) throw new Error(`token block under an unrecognised selector: ${selector}`);
    blocks.push({ selector, theme, decls: parseDecls(m[3]) });
  }
  return blocks;
}

function parseDecls(body) {
  const decls = [];
  let pending = null;
  let open = null;
  for (const raw of body.split('\n')) {
    const line = raw.trim();
    if (open !== null) {
      open.push(line);
      if (line.endsWith('*/')) {
        pending = clean(open.join(' '));
        open = null;
      }
      continue;
    }
    if (line === '') {
      pending = null;
      continue;
    }
    if (line.startsWith('/*')) {
      if (line.endsWith('*/')) pending = clean(line);
      else open = [line];
      continue;
    }
    const d = /^--([\w-]+):\s*(.+?);\s*(\/\*(.*?)\*\/)?$/.exec(line);
    if (!d) throw new Error(`unparsed line in token block: ${line}`);
    const trailing = d[4] ? d[4].trim() : '';
    const above = pending && !HEADER.test(pending) ? pending : '';
    decls.push({ name: d[1], value: d[2].trim(), usage: trailing || above });
    pending = null;
  }
  return decls;
}

const clean = (s) =>
  s
    .replace(/^\/\*/, '')
    .replace(/\*\/$/, '')
    .replace(/\s+/g, ' ')
    .trim();

const COLOR_FN = /^(oklch|oklab)\(\s*([\d.]+)\s+(-?[\d.]+)\s+(-?[\d.]+)\s*(?:\/\s*([\d.]+%?))?\s*\)$/;
const RGBA_FN = /^rgba?\([^()]*\)$/;

/** Is this raw CSS value a colour expression (as opposed to a number or length)? */
export function isColorValue(raw) {
  return /^(oklch|oklab|rgba?|color-mix)\(/.test(raw) || raw === 'transparent' || /^#[0-9a-f]{3,8}$/i.test(raw);
}

/**
 * Resolve one colour token's raw value in a theme.
 * @param {string} raw        the declared value
 * @param {Map<string,string>} env  every token's raw value in this theme
 * @param {Set<string>} colorNames   tokens that are colours (aliases allowed to these)
 * @returns {string} a literal the artifact accepts, or `{name}` for an alias
 */
export function resolveColor(raw, env, colorNames) {
  const v = substituteNumbers(raw, env);
  const alias = /^var\(--([\w-]+)\)$/.exec(v);
  if (alias) {
    if (!colorNames.has(alias[1])) throw new Error(`alias to a token that is not a colour: ${raw}`);
    return `{${alias[1]}}`;
  }
  if (v === 'transparent') return 'oklch(0 0 0 / 0)';
  if (COLOR_FN.test(v) || RGBA_FN.test(v) || /^#[0-9a-f]{3,8}$/i.test(v)) return v;
  if (v.startsWith('color-mix(')) return mix(v, env, colorNames);
  throw new Error(`unsupported colour value: ${raw}`);
}

/** var(--x) where --x is a plain number (a hue knob) → that number. */
function substituteNumbers(raw, env) {
  return raw.replace(/var\(--([\w-]+)\)/g, (whole, name) => {
    const val = env.get(name);
    return val !== undefined && /^-?[\d.]+$/.test(val) ? val : whole;
  });
}

/** color-mix(in oklab, A p%, B q%) with premultiplied alpha, per CSS Color 5. */
function mix(raw, env, colorNames) {
  const inner = /^color-mix\(\s*in oklab\s*,(.*)\)$/.exec(raw);
  if (!inner) throw new Error(`unsupported colour-mix space (only oklab): ${raw}`);
  const parts = splitTopLevel(inner[1]);
  if (parts.length !== 2) throw new Error(`unsupported colour-mix arguments: ${raw}`);
  const [a, b] = parts.map((p) => {
    const m = /^(.*?)(?:\s+([\d.]+)%)?$/.exec(p.trim());
    return { color: concrete(m[1].trim(), env, colorNames), pct: m[2] === undefined ? undefined : Number(m[2]) };
  });
  let pa = a.pct;
  let pb = b.pct;
  if (pa === undefined && pb === undefined) pa = pb = 50;
  else if (pa === undefined) pa = 100 - pb;
  else if (pb === undefined) pb = 100 - pa;
  const total = pa + pb;
  const wa = pa / total;
  const wb = pb / total;
  const alpha = a.color.alpha * wa + b.color.alpha * wb;
  const scale = total < 100 ? total / 100 : 1;
  if (alpha === 0) return 'oklch(0 0 0 / 0)';
  const L = (a.color.L * a.color.alpha * wa + b.color.L * b.color.alpha * wb) / alpha;
  const A = (a.color.a * a.color.alpha * wa + b.color.a * b.color.alpha * wb) / alpha;
  const B = (a.color.b * a.color.alpha * wa + b.color.b * b.color.alpha * wb) / alpha;
  const outAlpha = round(alpha * scale);
  // Mixing with transparent keeps the colour and only lowers alpha — write it in
  // the source colour's own oklch form so it reads like the token it came from.
  if (b.color.alpha === 0 && a.color.oklch) return oklch(a.color.oklch, outAlpha);
  if (a.color.alpha === 0 && b.color.oklch) return oklch(b.color.oklch, outAlpha);
  const tail = outAlpha < 1 ? ` / ${outAlpha}` : '';
  return `oklab(${round(L)} ${round(A)} ${round(B)}${tail})`;
}

function oklch([L, C, H], alpha) {
  return `oklch(${L} ${C} ${H}${alpha < 1 ? ` / ${alpha}` : ''})`;
}

/** Resolve an operand to concrete oklab, following aliases within the theme. */
function concrete(expr, env, colorNames, depth = 0) {
  if (depth > 16) throw new Error(`alias chain too deep at ${expr}`);
  const v = substituteNumbers(expr, env);
  if (v === 'transparent') return { L: 0, a: 0, b: 0, alpha: 0 };
  const ref = /^var\(--([\w-]+)\)$/.exec(v);
  if (ref) {
    if (!colorNames.has(ref[1])) throw new Error(`colour-mix operand is not a colour token: ${expr}`);
    return concrete(env.get(ref[1]), env, colorNames, depth + 1);
  }
  const m = COLOR_FN.exec(v);
  if (!m) throw new Error(`unsupported colour-mix operand: ${expr}`);
  const n = [Number(m[2]), Number(m[3]), Number(m[4])];
  const alpha = m[5] === undefined ? 1 : m[5].endsWith('%') ? Number(m[5].slice(0, -1)) / 100 : Number(m[5]);
  if (m[1] === 'oklab') return { L: n[0], a: n[1], b: n[2], alpha };
  const [L, C, H] = n;
  const rad = (H * Math.PI) / 180;
  return { L, a: C * Math.cos(rad), b: C * Math.sin(rad), alpha, oklch: [m[2], m[3], m[4]] };
}

function splitTopLevel(s) {
  const out = [];
  let depth = 0;
  let cur = '';
  for (const ch of s) {
    if (ch === '(') depth++;
    if (ch === ')') depth--;
    if (ch === ',' && depth === 0) {
      out.push(cur);
      cur = '';
    } else cur += ch;
  }
  out.push(cur);
  return out;
}

const round = (n) => Math.round(n * 10000) / 10000;
