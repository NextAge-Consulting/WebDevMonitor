#!/usr/bin/env node
/**
 * Workspace-tier wall guard (see .claude/rules/ui-design.md, "The client/server wall").
 *
 * ONE INVARIANT: database code and browser code never share a package.
 *
 *   server-shared  (apps/shared | packages/shared)
 *       Data/server tier. MAY import the ORM and DB driver. MUST NOT import React/browser
 *       libs, contain .tsx, or reach the ui/web tiers at runtime. The single
 *       sanctioned crossing is `import type` from `@ui/contracts/*`.
 *   ui             (packages/ui)
 *       Presentation tier and the Claude Design source. MUST NOT import the
 *       server-shared tier, the web tier, or any database code.
 *   web            (packages/web)          — only when the tier exists
 *       Front-end app-logic tier: integrations and serverFns. MUST NOT touch
 *       the database. Exists only in projects that have shared client-side
 *       non-presentational code; most projects never need it.
 *   headless apps  (apps/* with no react dependency and no .tsx)
 *       Reach the server-shared tier ONLY — never ui, never web. This is what
 *       keeps browser libraries out of their container images.
 *   extension apps (apps/* built by a browser-extension builder)
 *       The mirror image: 100% browser, no server half at all. MAY import ui;
 *       MUST NOT import the server-shared tier or database code. Detected by
 *       the builder dependency (wxt / plasmo / crxjs) rather than by react,
 *       because a full-stack app like apps/web is also react-bearing and DOES
 *       legitimately import the data tier from its server routes.
 *
 * SELF-GATING: every tier is detected, never assumed. A repo with no
 * packages/ui, no web tier, or no headless app simply has fewer rules to check
 * and exits 0 — the condition is honestly false, not waived. A single-app repo
 * with no shared workspace is a guaranteed no-op, so this is safe to run
 * unconditionally on any Node repo.
 *
 * Pure fs walk + specifier regex — no dependencies, safe to run pre-`npm ci`.
 */

import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join } from "node:path";

const failures = [];

function* walk(dir) {
  let entries;
  try {
    entries = readdirSync(dir);
  } catch {
    return; // tier absent — nothing to check
  }
  for (const name of entries) {
    if (name === "node_modules" || name === "dist" || name === "build") continue;
    const p = join(dir, name);
    if (statSync(p).isDirectory()) yield* walk(p);
    else if (/\.(ts|tsx|mts|cts)$/.test(name)) yield p;
  }
}

/**
 * Extract {line, spec, stmt} for every static import/export-from in a file.
 * Whole-file scan so multi-line statements (formatter-wrapped named-import
 * lists ending in `} from "..."`) are matched; comments are stripped first —
 * with newlines preserved, so reported line numbers stay true to the source.
 */
function specifiers(path) {
  const out = [];
  const content = readFileSync(path, "utf8")
    .replace(/\/\*[\s\S]*?\*\//g, (m) => m.replace(/[^\n]/g, " "))
    .replace(/\/\/[^\n]*/g, "");
  const lineOf = (idx) => content.slice(0, idx).split("\n").length;
  const fromRe = /\b(import|export)\s+((?:type\s)?[\w*{},\s$]*?)from\s*["']([^"']+)["']/g;
  for (const m of content.matchAll(fromRe)) {
    out.push({ line: lineOf(m.index), spec: m[3], stmt: `${m[1]} ${m[2]}` });
  }
  for (const m of content.matchAll(/\bimport\s*["']([^"']+)["']/g)) {
    out.push({ line: lineOf(m.index), spec: m[1], stmt: "import" });
  }
  // dynamic imports: import("spec") / await import("spec") — a wall could
  // otherwise be bypassed with `await import("some-server-only-lib")`.
  for (const m of content.matchAll(/\bimport\s*\(\s*["']([^"']+)["']/g)) {
    out.push({ line: lineOf(m.index), spec: m[1], stmt: "import" });
  }
  return out;
}

const readJson = (p) => {
  try {
    return JSON.parse(readFileSync(p, "utf8"));
  } catch {
    return null;
  }
};

// --- tier detection -------------------------------------------------------
// A tier is {dir, root, prefixes}: where it lives, where to walk, and the
// import-specifier prefixes that mean "something reached into this tier".
// Prefixes cover both the conventional path alias (@ui/) and the workspace
// package name from its package.json (@acme/ui), since projects use either.
function detectTier(candidates, alias) {
  for (const dir of candidates) {
    if (!existsSync(dir)) continue;
    const prefixes = [`${alias}/`];
    const pkg = readJson(join(dir, "package.json"));
    if (pkg?.name) prefixes.push(`${pkg.name}/`, pkg.name);
    return { dir, root: existsSync(join(dir, "src")) ? join(dir, "src") : dir, prefixes };
  }
  return null;
}

const shared = detectTier(["apps/shared", "packages/shared"], "@shared");
const ui = detectTier(["packages/ui"], "@ui");
const web = detectTier(["packages/web"], "@web");

// A browser-extension builder in an app's dependencies means the whole
// workspace is browser code — there is no server half to justify a database
// import, so a stray one would ship drizzle into the extension bundle.
const EXTENSION_BUILDERS = ["wxt", "plasmo", "@plasmohq/parcel-config", "@crxjs/vite-plugin"];

const isExtensionApp = (deps) => EXTENSION_BUILDERS.some((b) => b in deps);

// Headless apps: an app workspace with no react dependency and no .tsx file.
// That two-field test separates server-only services from front-end apps
// without any per-project configuration. Extension apps are excluded — they
// have neither, but they are browser code, not server code.
function detectHeadlessApps() {
  const out = [];
  let apps;
  try {
    apps = readdirSync("apps");
  } catch {
    return out;
  }
  for (const name of apps) {
    const dir = join("apps", name);
    if (shared && dir === shared.dir) continue;
    if (!statSync(dir).isDirectory()) continue;
    const pkg = readJson(join(dir, "package.json"));
    if (!pkg) continue;
    const deps = { ...(pkg.dependencies ?? {}), ...(pkg.devDependencies ?? {}) };
    if (deps.react) continue;
    if (isExtensionApp(deps)) continue;
    const root = existsSync(join(dir, "src")) ? join(dir, "src") : dir;
    let hasTsx = false;
    for (const f of walk(root)) {
      if (f.endsWith(".tsx")) {
        hasTsx = true;
        break;
      }
    }
    if (!hasTsx) out.push({ dir, root });
  }
  return out;
}

/** Browser-extension apps: 100% client, may use ui, must not reach the data tier. */
function detectExtensionApps() {
  const out = [];
  let apps;
  try {
    apps = readdirSync("apps");
  } catch {
    return out;
  }
  for (const name of apps) {
    const dir = join("apps", name);
    if (!statSync(dir).isDirectory()) continue;
    const pkg = readJson(join(dir, "package.json"));
    if (!pkg) continue;
    const deps = { ...(pkg.dependencies ?? {}), ...(pkg.devDependencies ?? {}) };
    if (!isExtensionApp(deps)) continue;
    out.push({ dir, root: dir });
  }
  return out;
}

const headless = detectHeadlessApps();
const extensions = detectExtensionApps();

const startsWithAny = (spec, prefixes) => prefixes.some((p) => spec === p || spec.startsWith(p));

// Engine-agnostic on purpose: the wall is "database code never reaches the
// browser", and that holds whichever driver the project uses. `mssql` and
// `tedious` are here for the same reason `pg` is — a SQL Server project's data
// tier is no less server-only than a Postgres one. Adding an engine later means
// adding its driver here; a missing driver is a silent hole in the wall, not a
// failing check.
const isDbImport = (spec) =>
  /^(drizzle-orm|drizzle-kit|pg|postgres|@neondatabase|mssql|tedious|mysql2|better-sqlite3)(\/|$)/.test(spec) ||
  /\.server(\.|$|\/)/.test(spec);
const isUiFramework = (spec) =>
  /^(react|react-dom|lucide-react|radix-ui|@radix-ui\/)(\/|$)/.test(spec) ||
  /^@tanstack\/react-/.test(spec) || // react-start / react-router pull React
  /^(class-variance-authority|clsx|tailwind-merge)(\/|$)/.test(spec) || // styling-only, but client
  /^@fontsource/.test(spec) || // font CSS is a browser asset
  /^@stripe\/stripe-js/.test(spec); // browser Stripe SDK

// --- server-shared tier: no browser/UI, no web tier ------------------------
// The one sanctioned crossing is `import type` from @ui/contracts/* — row and
// param shapes rendered by UI are defined once there and type-imported back by
// server loaders. Types erase at compile, so nothing runtime crosses.
if (shared) {
  for (const f of walk(shared.root)) {
    if (f.endsWith(".tsx"))
      failures.push(`${f}: .tsx file inside the server-shared tier (${shared.dir}) — it stays UI-free`);
    for (const { line, spec, stmt } of specifiers(f)) {
      if (isUiFramework(spec))
        failures.push(`${f}:${line}: server-shared tier imports UI framework "${spec}" — browser code stays out of the data tier`);
      if (web && startsWithAny(spec, web.prefixes))
        failures.push(`${f}:${line}: server-shared tier imports "${spec}" — it must not depend on the web tier (would pull React toward headless consumers)`);
      if (ui && startsWithAny(spec, ui.prefixes)) {
        const typeOnly = /^(import|export)\s+type\b/.test(stmt);
        const isContract = /(^|\/)contracts\//.test(spec);
        if (!typeOnly)
          failures.push(`${f}:${line}: runtime ui-tier import in the server-shared tier ("${spec}") — only \`import type\` from the ui tier's contracts/ may cross`);
        else if (!isContract)
          failures.push(`${f}:${line}: type import from "${spec}" — the server-shared tier may only import types from the ui tier's contracts/`);
      }
    }
  }
}

// --- ui tier: no database, no server-shared, no web ------------------------
if (ui) {
  for (const f of walk(ui.root)) {
    for (const { line, spec } of specifiers(f)) {
      if (shared && startsWithAny(spec, shared.prefixes))
        failures.push(`${f}:${line}: ui tier imports "${spec}" — presentation must not reach the data tier`);
      if (web && startsWithAny(spec, web.prefixes))
        failures.push(`${f}:${line}: ui tier imports "${spec}" — keep presentation and app-logic tiers separate`);
      if (isDbImport(spec))
        failures.push(`${f}:${line}: ui tier imports database code "${spec}" — drizzle/pg/.server never reach the client bundle`);
    }
  }
}

// --- web tier: never touches the database ---------------------------------
if (web) {
  for (const f of walk(web.root)) {
    for (const { line, spec } of specifiers(f)) {
      if (isDbImport(spec))
        failures.push(`${f}:${line}: web tier imports database code "${spec}" — it is client-bundled; DB code belongs in the server-shared tier`);
    }
  }
}

// --- headless apps: reach the server-shared tier ONLY ----------------------
for (const app of headless) {
  for (const f of walk(app.root)) {
    for (const { line, spec } of specifiers(f)) {
      if (ui && startsWithAny(spec, ui.prefixes))
        failures.push(`${f}:${line}: headless app ${app.dir} imports "${spec}" — it must never reach the ui tier`);
      if (web && startsWithAny(spec, web.prefixes))
        failures.push(`${f}:${line}: headless app ${app.dir} imports "${spec}" — it must never reach the web tier (would pull React into the image)`);
    }
  }
}

// --- extension apps: never the data tier ----------------------------------
for (const app of extensions) {
  for (const f of walk(app.root)) {
    for (const { line, spec } of specifiers(f)) {
      if (shared && startsWithAny(spec, shared.prefixes))
        failures.push(`${f}:${line}: extension app ${app.dir} imports "${spec}" — it is entirely browser code; a data-tier import ships drizzle into the extension bundle`);
      if (isDbImport(spec))
        failures.push(`${f}:${line}: extension app ${app.dir} imports database code "${spec}" — never in a browser bundle`);
    }
  }
}

if (failures.length) {
  console.error(`✗ workspace-tier violations:\n${failures.map((f) => `  ${f}`).join("\n")}`);
  process.exit(1);
}

// Report what was actually enforced, so a silent pass is never mistaken for
// coverage the repo did not have.
const checked = [];
if (shared) checked.push(`${shared.dir} is browser-free`);
if (ui) checked.push(`${ui.dir} is database-free`);
if (web) checked.push(`${web.dir} is database-free`);
if (headless.length)
  checked.push(`${headless.map((h) => h.dir).join(", ")} reach the data tier only`);
if (extensions.length)
  checked.push(`${extensions.map((e) => e.dir).join(", ")} never reach the data tier`);
console.log(
  checked.length
    ? `✓ workspace-tiers: ${checked.join("; ")}.`
    : "✓ workspace-tiers: no tiered workspaces detected — nothing to enforce.",
);
