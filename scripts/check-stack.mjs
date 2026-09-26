#!/usr/bin/env node
/**
 * Kit stack gate — the fleet's blessed versions, enforced.
 *
 * WHY THIS EXISTS: the kit is a platform. It ships configs, CI jobs and a
 * library standard, and a platform that asserts a tool has to pin it. Otherwise
 * every project answers "which version do we run?" alone and the fleet diverges
 * with nothing to say so. The rule the manifest encodes:
 *
 *     THE KIT PINS WHAT THE KIT SHIPS, OR WHAT THE KIT'S CHOICES DRAG IN.
 *
 * Anything the kit says nothing about stays the project's call — Dependabot and
 * the dependency-triage pass own those.
 *
 * EACH ENTRY CARRIES ITS OWN TRIGGER, which is what keeps the kit opinionated
 * without blocking a project the opinion does not apply to:
 *
 *   whenDeclared   this project declares it -> it must be the blessed version
 *   whenFile       a kit-shipped config is present -> the tool behind it must be
 *                  pinned. No config, no opinion, no output.
 *   whenResolved   present anywhere in the LOCKFILE, transitive included -> one
 *                  major across the whole tree
 *
 * `whenResolved` is the one that catches what nobody wrote down. `zod` is the
 * live case: better-auth needs v4, drizzle-kit and shadcn pull v3, npm resolves
 * by hoist order, and the loser fails at RUNTIME — never at build, never in CI.
 * No declaration check could have seen it.
 *
 * SEVERITY is a field, not a convention. `required` fails; `advisory` prints and
 * passes, for a real problem whose fix is a fleet decision not yet taken.
 * Silence is not an option for either — an unreported advisory is the state that
 * let the biome hole live.
 *
 * SELF-GATING: no package.json, or no manifest and no TanStack dependency, exits
 * 0 in silence — the same marker-file cascade the gitflow scripts use.
 *
 * HERMETIC: reads package.json files, the lockfile, the manifest, CI workflow
 * text and sync-substitutions.json. Never the network, so it is safe in CI and
 * fast enough for pre-commit.
 *
 * Run: node scripts/check-stack.mjs   (exit 1 on a required violation)
 */

import { existsSync, readdirSync, readFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const failures = [];
const advisories = [];
const readJson = (p) => JSON.parse(readFileSync(p, "utf8"));

/** Record a violation under the severity its manifest entry declared. */
const report = (severity, message) =>
  (severity === "advisory" ? advisories : failures).push(message);

// --- marker-file gate: is this even a Node repo? ---------------------------
const rootPkgPath = resolve(repoRoot, "package.json");
if (!existsSync(rootPkgPath)) process.exit(0);
const rootPkg = readJson(rootPkgPath);

// --- collect every workspace manifest (root included) ----------------------
const rawWorkspaces = Array.isArray(rootPkg.workspaces)
  ? rootPkg.workspaces
  : (rootPkg.workspaces?.packages ?? []);

const manifests = [{ dir: ".", pkg: rootPkg }];
for (const pattern of rawWorkspaces) {
  const dirs = [];
  if (pattern.endsWith("/*")) {
    const parent = pattern.slice(0, -2);
    let entries;
    try {
      entries = readdirSync(resolve(repoRoot, parent), { withFileTypes: true });
    } catch {
      continue; // parent dir absent — nothing to expand
    }
    for (const ent of entries) if (ent.isDirectory()) dirs.push(`${parent}/${ent.name}`);
  } else {
    dirs.push(pattern);
  }
  for (const dir of dirs) {
    const p = resolve(repoRoot, dir, "package.json");
    if (existsSync(p)) manifests.push({ dir, pkg: readJson(p) });
  }
}

const depsOf = (pkg) => ({ ...(pkg.dependencies ?? {}), ...(pkg.devDependencies ?? {}) });
const where = (dir) => `${dir === "." ? "" : `${dir}/`}package.json`;

// --- the manifest ----------------------------------------------------------
const manifestPath = resolve(repoRoot, ".claude/stack-manifest.json");
if (!existsSync(manifestPath)) {
  // A repo using the kit's library standard MUST have it. Anything else simply
  // has not adopted the gate, which is not this script's business to announce.
  const usesTanStack = manifests.some((m) =>
    Object.keys(depsOf(m.pkg)).some((d) => d.startsWith("@tanstack/")),
  );
  if (!usesTanStack) process.exit(0);
  console.error(
    "✗ stack: this repo uses TanStack but .claude/stack-manifest.json is missing.\n" +
      "  The manifest ships with this script via /sync-dev-kit — run a sync.",
  );
  process.exit(1);
}
const manifest = readJson(manifestPath);
const blessed = manifest.packages ?? {};
const banned = manifest.banned ?? {};
const formLib = manifest.form_library ?? "@tanstack/react-form";

const lockPath = resolve(repoRoot, "package-lock.json");
const lock = existsSync(lockPath) ? readJson(lockPath) : null;

// --- 1. blessed packages, each under its own trigger -----------------------
for (const [name, spec] of Object.entries(blessed)) {
  const severity = spec.severity ?? "required";
  const why = spec.why ? `\n      ${spec.why}` : "";
  const applies = spec.applies ?? "whenDeclared";

  // -- whenFile: a kit-shipped config is present, so the tool behind it is ours.
  if (typeof applies === "object" && Array.isArray(applies.whenFile)) {
    const present = applies.whenFile.find((f) => existsSync(resolve(repoRoot, f)));
    if (!present) continue; // no config, no opinion

    // Installed by a workflow at run time: this file owns the version so the
    // workflow has one thing to read. A project declaration is not expected.
    if (spec.installedBy === "ci") {
      const wf = spec.ciWorkflow ? resolve(repoRoot, spec.ciWorkflow) : null;
      if (wf && existsSync(wf) && !readFileSync(wf, "utf8").includes(`${name}@${spec.version}`)) {
        report(
          severity,
          `${spec.ciWorkflow}: installs ${name} without the blessed version ${spec.version}.\n` +
            `      An unpinned install on a runner executes whatever the registry currently\n` +
            `      serves under that name, and --no-save leaves no record of what ran.${why}`,
        );
      }
      continue;
    }

    const declaredIn = manifests.filter((m) => depsOf(m.pkg)[name] !== undefined);
    if (declaredIn.length === 0) {
      report(
        severity,
        `${present} is present but "${name}" is declared nowhere.\n` +
          `      The kit ships that config, so the kit owns the tool behind it.\n` +
          `      Fix: npm i -D --save-exact ${name}@${spec.version}${why}`,
      );
      continue;
    }
  }

  // -- declaration check, shared by whenDeclared and whenFile/installedBy:project.
  for (const { dir, pkg } of manifests) {
    const got = depsOf(pkg)[name];
    if (got === undefined) continue; // not used here — lockstep is not "must use"
    if (got === spec.version) continue;
    if (/^[\^~><=*]|\s|\|\|/.test(got)) {
      report(
        severity,
        `${where(dir)}: ${name} is "${got}" — declare the exact blessed version "${spec.version}".\n` +
          `      A range lets a fresh install drift off the kit's version, and \`npm install\`\n` +
          `      adds a caret by DEFAULT — use --save-exact.${why}`,
      );
    } else {
      report(severity, `${where(dir)}: ${name} is "${got}" — the kit blesses "${spec.version}".${why}`);
    }
  }

  // -- the lockfile can still resolve something the declarations do not say.
  if (spec.installedBy !== "ci") {
    const top = lock?.packages?.[`node_modules/${name}`];
    if (top?.version && spec.version && top.version !== spec.version) {
      report(
        severity,
        `package-lock.json: ${name} resolves to ${top.version}, blessed is ${spec.version}. Reinstall so the lockfile matches.`,
      );
    }
  }
}

// --- 1b. Better Auth apps: the declaration (required) + bundling (advisory) --
// Vite inlines better-auth into the server bundle, and the inlined `import 'x'`
// resolves from the APP's directory. An app that declares the major itself is
// immune to whatever npm hoisted to the root — which is why three projects with
// two different root hoists all run in production.
//
// So the DECLARATION fails and the bundling only advises. Measured, not assumed:
// 6 of 7 apps in the fleet carry no `ssr.noExternal` and none of them is broken.
// A check that failed them would be wrong, not strict.
const ssr = manifest.ssr_no_external;
if (ssr?.whenAppDeclares) {
  for (const { dir, pkg } of manifests) {
    if (dir === ".") continue;
    const deps = depsOf(pkg);
    if (deps[ssr.whenAppDeclares] === undefined) continue;

    // No vite config means this workspace is not a Vite app — a shared library
    // can depend on better-auth without ever bundling it.
    const cfg = ["vite.config.ts", "vite.config.js", "vite.config.mts"]
      .map((f) => resolve(repoRoot, dir, f))
      .find((f) => existsSync(f));
    if (!cfg) continue;

    // -- required half.
    for (const [name, wantMajor] of Object.entries(ssr.requireDeclared ?? {})) {
      const got = deps[name];
      if (got === undefined) {
        failures.push(
          `${where(dir)}: declares ${ssr.whenAppDeclares} but not "${name}".\n` +
            `      The inlined server bundle resolves "${name}" from THIS app's directory, so\n` +
            `      without its own dependency the app gets whatever major is hoisted to the\n` +
            `      root. Fix: add "${name}": "^${wantMajor}" here. See ${ssr.reference}.`,
        );
        continue;
      }
      const gotMajor = Number.parseInt(got.replace(/^[^0-9]*/, ""), 10);
      if (gotMajor !== wantMajor) {
        failures.push(
          `${where(dir)}: ${name} is "${got}" — an app declaring ${ssr.whenAppDeclares} needs v${wantMajor}. See ${ssr.reference}.`,
        );
      }
    }

    // -- advisory half.
    const wanted = ssr.adviseSsrNoExternal ?? [];
    if (wanted.length === 0) continue;
    const src = readFileSync(cfg, "utf8");
    const arr = src.match(/noExternal:\s*\[([\s\S]*?)\]/);
    const matchers = [];
    if (arr) {
      for (const raw of arr[1].split(",")) {
        const e = raw.trim();
        if (!e) continue;
        // Entries are strings OR regexes, and a regex legitimately covers a
        // family (`/^@noble\//` covers @noble/ciphers). Match, never substring.
        const asRegex = e.match(/^\/(.*)\/[a-z]*$/);
        if (asRegex) {
          try { matchers.push(new RegExp(asRegex[1])); } catch { /* unparseable — treated as missing */ }
        } else {
          const str = e.replace(/^['"`]|['"`]$/g, "");
          if (str) matchers.push(str);
        }
      }
    }
    const missing = wanted.filter(
      (name) => !matchers.some((mt) => (typeof mt === "string" ? mt === name || name.startsWith(`${mt}/`) : mt.test(name))),
    );
    if (missing.length) {
      advisories.push(
        `${dir}/${cfg.split("/").pop()}: ssr.noExternal does not cover ${missing.join(", ")}.\n` +
          `      Not a defect — the app declares its own majors, which is what protects it.\n` +
          `      This is hardening against a future hoist change. See ${ssr.reference}.`,
      );
    }
  }
}

// --- 2. banned dependencies ------------------------------------------------
for (const { dir, pkg } of manifests) {
  for (const [name, whyBanned] of Object.entries(banned)) {
    if (depsOf(pkg)[name] === undefined) continue;
    failures.push(`${where(dir)}: "${name}" is banned. ${whyBanned}`);
  }
}
for (const name of Object.keys(banned)) {
  if (lock?.packages?.[`node_modules/${name}`]) {
    failures.push(
      `package-lock.json: banned package "${name}" is in the tree (possibly transitive). Find what pulls it: npm ls ${name}`,
    );
  }
}

// --- 3. the form-library question is answered, per front-end app -----------
// A front-end app is an apps/* workspace that declares react. Headless apps
// (rest, worker, shared) declare none and are correctly out of scope.
const subsPath = resolve(repoRoot, ".claude/sync-substitutions.json");
let exempt = [];
if (existsSync(subsPath)) {
  exempt = String(readJson(subsPath).FORM_LIB_EXEMPT_APPS ?? "").split(/\s+/).filter(Boolean);
}
const undecided = manifests
  .filter((m) => m.dir.startsWith("apps/") && depsOf(m.pkg).react !== undefined)
  .filter((m) => depsOf(m.pkg)[formLib] === undefined)
  .map((m) => m.dir.slice("apps/".length))
  .filter((app) => !exempt.includes(app));
if (undecided.length) {
  failures.push(
    `form-library question unanswered for: ${undecided.join(", ")}.\n` +
      `    Every front-end app decides ONCE, all-in for that app. Either:\n` +
      `      - add "${formLib}" to apps/<app>/package.json  (data-entry app), or\n` +
      `      - add the app to FORM_LIB_EXEMPT_APPS in .claude/sync-substitutions.json\n` +
      `    Leaving it in neither state is what fails here — an unasked question,\n` +
      `    not a missing dependency.`,
  );
}

// --- 4. vendored reference docs are present --------------------------------
const refDir = resolve(repoRoot, ".claude/skills/mfing-bible-of-tanstack/references");
const missingRefs = (manifest.references ?? [])
  .map((r) => r.file)
  .filter((f) => !existsSync(resolve(refDir, f)));
if (missingRefs.length) {
  failures.push(
    `manifest names reference docs that are not present: ${missingRefs.join(", ")}.\n` +
      `    Expected under .claude/skills/mfing-bible-of-tanstack/references/ — run /sync-dev-kit.`,
  );
}

// --- report ----------------------------------------------------------------
// Advisories print whether or not anything failed. They name real problems the
// fleet has not adopted a fix for, and a problem that only prints on a green
// run is a problem nobody ever reads.
if (advisories.length) {
  console.error(`! stack advisories (not blocking):\n${advisories.map((a) => `  ${a}`).join("\n")}\n`);
}
if (failures.length) {
  console.error(`✗ stack standard violations:\n${failures.map((f) => `  ${f}`).join("\n")}`);
  process.exit(1);
}

const counts = Object.keys(blessed).length;
console.log(
  `✓ stack: ${counts} blessed package(s) checked; ${Object.keys(banned).length} banned dep(s) absent; ` +
    `form question answered; ${(manifest.references ?? []).length} reference doc(s) present` +
    (advisories.length ? `; ${advisories.length} advisory(ies) above` : "") +
    ` (blessed ${manifest.blessed_at}).`,
);
