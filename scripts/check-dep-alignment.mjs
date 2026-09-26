#!/usr/bin/env node
// Cross-workspace dependency alignment gate.
//
// WHY THIS EXISTS: in a monorepo every workspace is meant to run on ONE shared
// stack. When a dependency is declared at different versions across workspaces
// (e.g. better-auth ^1.5.5 in one app but ^1.6.11 in another) you get "works in
// one app, breaks in another" production failures that are brutal to diagnose.
// Dependabot bumps each manifest independently and has no concept of cross-app
// consistency, so it CREATES this skew rather than catching it. This gate is the
// safety net: it fails the moment any shared dependency drifts to more than one
// version across the workspaces.
//
// Single-package repos (no `workspaces` field) have exactly one manifest, so the
// gate is a guaranteed no-op pass — safe to run unconditionally on any Node repo.
//
// Background + the discipline this enforces: dependency-management.md in the
// dev kit (project-documentation/).
//
// Run: node scripts/check-dep-alignment.mjs   (exit 1 on skew, 0 when aligned)

import { existsSync, readdirSync, readFileSync } from "node:fs";
import { resolve, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const repoRoot = resolve(dirname(fileURLToPath(import.meta.url)), "..");

const rootPkg = JSON.parse(readFileSync(resolve(repoRoot, "package.json"), "utf8"));

// npm workspaces is either an array of patterns or `{ packages: [...] }`.
const rawWorkspaces = Array.isArray(rootPkg.workspaces)
  ? rootPkg.workspaces
  : (rootPkg.workspaces?.packages ?? []);

// Expand workspace patterns to concrete `<dir>/package.json` manifest paths.
// Supports literal dirs ("apps/shop") and a trailing-glob ("apps/*", the common
// npm form) — dependency-free, works on any Node version. A globbed dir that has
// no package.json is simply skipped; a *literal* entry that can't be read fails
// loud below (it's a declared workspace that's broken).
const workspaceDirs = [];
for (const pattern of rawWorkspaces) {
  if (pattern.endsWith("/*")) {
    const parent = pattern.slice(0, -2);
    let entries;
    try {
      entries = readdirSync(resolve(repoRoot, parent), { withFileTypes: true });
    } catch {
      continue; // parent dir absent — nothing to expand
    }
    for (const ent of entries) {
      if (!ent.isDirectory()) continue;
      const dir = `${parent}/${ent.name}`;
      try {
        readFileSync(resolve(repoRoot, dir, "package.json"));
        workspaceDirs.push(dir);
      } catch {
        // globbed dir without a package.json is not a workspace — skip silently
      }
    }
  } else {
    workspaceDirs.push(pattern);
  }
}

// Single-root-lockfile invariant. In an npm-workspaces monorepo the root
// package-lock.json is authoritative; a stray per-workspace lockfile is dead
// (npm installs from the root lockfile and ignores it) yet Dependabot still
// scans it independently — resurfacing already-patched transitives as phantom
// security alerts against a manifest nothing installs from. Fail loud so an
// incomplete unification (one app's lockfile left behind) is caught here, not
// weeks later as a ghost CVE on the board.
const strayLockfiles = workspaceDirs
  .map((w) => `${w}/package-lock.json`)
  .filter((rel) => existsSync(resolve(repoRoot, rel)));
if (strayLockfiles.length > 0) {
  console.error(
    `✗ lockfile hygiene: ${strayLockfiles.length} stray per-workspace lockfile(s) found. ` +
      `Only the root package-lock.json is authoritative in a workspaces monorepo — delete these (they cause phantom Dependabot alerts):\n`,
  );
  for (const rel of strayLockfiles) console.error(`      ${rel}`);
  process.exit(1);
}

const manifests = ["package.json", ...workspaceDirs.map((w) => `${w}/package.json`)];

// package name -> { range -> [manifests] }
const seen = new Map();
for (const rel of manifests) {
  let pkg;
  try {
    pkg = JSON.parse(readFileSync(resolve(repoRoot, rel), "utf8"));
  } catch (err) {
    // Fail-loud: a declared workspace manifest that can't be read/parsed is a
    // real configuration error — never silently skip it (that would let the gate
    // report "aligned" while a manifest is broken).
    console.error(`✗ Failed to read or parse ${rel}: ${err instanceof Error ? err.message : String(err)}`);
    process.exit(1);
  }
  const label = rel.replace(/\/package\.json$/, "") || "root";
  for (const section of ["dependencies", "devDependencies"]) {
    for (const [name, range] of Object.entries(pkg[section] ?? {})) {
      if (!seen.has(name)) seen.set(name, new Map());
      const byRange = seen.get(name);
      if (!byRange.has(range)) byRange.set(range, []);
      byRange.get(range).push(label);
    }
  }
}

const skewed = [];
for (const [name, byRange] of seen) {
  if (byRange.size > 1) skewed.push([name, byRange]);
}

if (skewed.length === 0) {
  console.log("✓ dependency alignment: every shared dependency is a single version across all workspaces.");
  process.exit(0);
}

console.error(`✗ dependency alignment: ${skewed.length} shared dependency(ies) declared at conflicting versions across workspaces.\n`);
console.error("A monorepo runs ONE stack. Pick one version and align every workspace (see dependency-management.md in the dev kit).\n");
for (const [name, byRange] of skewed.sort((a, b) => a[0].localeCompare(b[0]))) {
  console.error(`  ${name}:`);
  for (const [range, where] of byRange) {
    console.error(`      ${range}  ← ${where.join(", ")}`);
  }
}
process.exit(1);
