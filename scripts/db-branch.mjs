#!/usr/bin/env node
// Which Neon branch does DATABASE_URL actually point at?
//
// POSTGRES/NEON ONLY. Meaningless when DB_ENGINE is anything but
// "PostgreSQL" — on another engine it can only ever exit 2 (UNKNOWN),
// which reads as a warning about production rather than as "wrong tool".
// The rules that invoke it are engine-gated; do not reach for it directly
// on a project that is not on Neon.
//
// Exists because "am I about to write to production?" was being answered by
// guesswork. Guessing wrong in the cautious direction stalls real work — refused
// test runs, refused migrations, half-hour holds — and guessing wrong the other
// way writes to prod. Neither is acceptable when the answer is one API call.
//
// Exit codes are the contract:
//   0  a non-default branch — a dev/preview branch, resettable from parent
//   1  the project's DEFAULT branch — treat as production
//   2  could not determine (missing vars, non-Neon host, API failure)
//
// Never infers. A 2 means "unknown", never "probably fine".

import { readFileSync } from "node:fs";

const API = "https://console.neon.tech/api/v2";

function readEnvFile(path = ".env") {
  const out = {};
  let text;
  try {
    text = readFileSync(path, "utf8");
  } catch {
    return out;
  }
  for (const raw of text.split("\n")) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const eq = line.indexOf("=");
    if (eq === -1) continue;
    const key = line.slice(0, eq).trim();
    let val = line.slice(eq + 1).trim();
    // strip surrounding quotes, then a trailing ` # comment` on unquoted values
    if ((val.startsWith('"') && val.endsWith('"')) || (val.startsWith("'") && val.endsWith("'"))) {
      val = val.slice(1, -1);
    } else {
      const hash = val.indexOf(" #");
      if (hash !== -1) val = val.slice(0, hash).trim();
    }
    out[key] = val;
  }
  return out;
}

function fail(code, msg) {
  console.log(msg);
  process.exit(code);
}

const fileEnv = readEnvFile();
const env = (k) => process.env[k] ?? fileEnv[k];

const dbUrl = env("DATABASE_URL");
if (!dbUrl) fail(2, "UNKNOWN — no DATABASE_URL in the environment or .env.");

let host;
try {
  host = new URL(dbUrl).hostname;
} catch {
  fail(2, "UNKNOWN — DATABASE_URL is not a parseable URL.");
}

if (!host.endsWith(".neon.tech")) {
  fail(2, `UNKNOWN — ${host} is not a Neon host; this check only speaks Neon.`);
}

const apiKey = env("NEON_API_KEY");
const projectId = env("NEON_PROJECT_ID");
if (!apiKey || !projectId) {
  fail(
    2,
    "UNKNOWN — NEON_API_KEY and NEON_PROJECT_ID are needed to resolve the branch, " +
      "and at least one is missing. Do NOT read this as safe.",
  );
}

// Neon gives every endpoint its own host, so the host in DATABASE_URL identifies
// the endpoint, and the endpoint names its branch. Pooled hosts carry a
// `-pooler` suffix the endpoint record does not.
const bare = host.replace("-pooler.", ".");

async function get(path) {
  const res = await fetch(`${API}${path}`, {
    headers: { Authorization: `Bearer ${apiKey}`, Accept: "application/json" },
  });
  if (!res.ok) throw new Error(`${res.status} ${res.statusText}`);
  return res.json();
}

let endpoints;
let branches;
try {
  ({ endpoints } = await get(`/projects/${projectId}/endpoints`));
  ({ branches } = await get(`/projects/${projectId}/branches`));
} catch (err) {
  fail(2, `UNKNOWN — Neon API call failed (${err.message}). Do NOT read this as safe.`);
}

const endpoint = endpoints.find((e) => e.host === bare || e.host === host);
if (!endpoint) {
  fail(2, `UNKNOWN — no endpoint in project ${projectId} matches host ${host}.`);
}

const branch = branches.find((b) => b.id === endpoint.branch_id);
if (!branch) {
  fail(2, `UNKNOWN — endpoint ${endpoint.id} names branch ${endpoint.branch_id}, which the API did not return.`);
}

const flags = [branch.default ? "default" : "not default", branch.protected ? "protected" : null]
  .filter(Boolean)
  .join(", ");

if (branch.default || branch.protected) {
  fail(
    1,
    `PRODUCTION — DATABASE_URL points at branch "${branch.name}" (${flags}).\n` +
      "Writes here are real. Stop and get explicit approval.",
  );
}

fail(
  0,
  `DEV — DATABASE_URL points at branch "${branch.name}" (${flags}), a fork of the ` +
    "parent branch and resettable from it.\n" +
    "Reads, tests and migrations against it are normal work. Proceed.",
);
