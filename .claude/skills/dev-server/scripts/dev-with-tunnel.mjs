#!/usr/bin/env node

/**
 * Cloudflare named tunnel + Vite dev server in one tab.
 *
 * Invoked by `/dev <app> --tunnel` via the package.json script
 * `dev:tunnel:<app>` → `node .claude/skills/dev-server/scripts/dev-with-tunnel.mjs <app>`.
 *
 * Spawns:
 *   1. cloudflared tunnel run    (reads ~/.cloudflared/config.yml — user-machine)
 *   2. npm run dev:<app>         (with PORT propagated from /dev's lsof pick)
 *
 * Hostname convention:
 *   `<app>.thenextage.com` — fixed across all consumer projects. This shop's
 *   standard tunnel parent domain. Not configurable.
 *
 * Per-user-machine values:
 *   Tunnel UUID + ingress rules live in ~/.cloudflared/config.yml. The user
 *   wires `<app>.thenextage.com` → http://localhost:<port> ingress rules
 *   there, and points the wildcard `*.thenextage.com` DNS record at the
 *   tunnel UUID once in the Cloudflare dashboard.
 *
 * PORT propagation:
 *   /dev runs lsof first, picks a free port, exports PORT=<n> when invoking
 *   `npm run dev:tunnel:<app>`. This script reads PORT from env and surfaces
 *   it to the user. The inner `npm run dev:<app>` inherits PORT, and vite
 *   honors it via `port: Number(process.env.PORT) || <default>` in
 *   vite.config.ts (the convention /dev itself encourages).
 */

import { spawn } from "node:child_process";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const __dirname = dirname(fileURLToPath(import.meta.url));
// Resolve project root by walking up to the nearest package.json.
function findProjectRoot(start) {
  let dir = start;
  while (dir !== "/") {
    try {
      readFileSync(join(dir, "package.json"));
      return dir;
    } catch {
      dir = dirname(dir);
    }
  }
  throw new Error("no package.json found walking up from " + start);
}
const ROOT_DIR = findProjectRoot(__dirname);

const APP = process.argv[2];
if (!APP) {
  console.error("Usage: node dev-with-tunnel.mjs <app>");
  process.exit(1);
}

const HOSTNAME = `${APP}.thenextage.com`;
const PORT = process.env.PORT || "(default)";
const APP_DIR = join(ROOT_DIR, "apps", APP);

let tunnelProcess = null;
let devProcess = null;

const colors = {
  cyan: "\x1b[36m",
  magenta: "\x1b[35m",
  green: "\x1b[32m",
  yellow: "\x1b[33m",
  red: "\x1b[31m",
  reset: "\x1b[0m",
  bold: "\x1b[1m",
};

function log(prefix, color, message) {
  console.log(`${color}[${prefix}]${colors.reset} ${message}`);
}

function startTunnel() {
  return new Promise((resolve, reject) => {
    log("tunnel", colors.magenta, "Starting named Cloudflare tunnel...");

    tunnelProcess = spawn("cloudflared", ["tunnel", "run"], { cwd: ROOT_DIR });

    let tunnelReady = false;
    const onReady = (output) => {
      if (!tunnelReady && output.includes("Registered tunnel connection")) {
        tunnelReady = true;
        log(
          "tunnel",
          colors.green + colors.bold,
          `Tunnel connected: https://${HOSTNAME}`,
        );
        resolve();
      }
    };

    tunnelProcess.stdout.on("data", (data) => {
      const output = data.toString();
      process.stdout.write(`${colors.magenta}[tunnel]${colors.reset} ${output}`);
      onReady(output);
    });

    tunnelProcess.stderr.on("data", (data) => {
      const output = data.toString();
      process.stderr.write(`${colors.magenta}[tunnel]${colors.reset} ${data}`);
      onReady(output);
    });

    tunnelProcess.on("error", (error) => {
      log("tunnel", colors.red, `Failed to start: ${error.message}`);
      if (error.code === "ENOENT") {
        log(
          "tunnel",
          colors.yellow,
          "cloudflared not found. Install it with: brew install cloudflared",
        );
      }
      reject(error);
    });

    tunnelProcess.on("close", (code) => {
      if (code !== 0 && code !== null) {
        log("tunnel", colors.red, `Exited with code ${code}`);
      }
    });

    setTimeout(() => {
      if (!tunnelReady) {
        reject(new Error("Timeout waiting for tunnel connection"));
      }
    }, 30000);
  });
}

function startDevServer() {
  log("vite", colors.cyan, `Starting dev server for ${APP}...`);

  // Inject tunnel-aware URL env vars so any service that needs to know its
  // public origin (better-auth, OAuth callbacks, Stripe return URLs, etc.)
  // sees the tunnel hostname instead of localhost.
  //
  // BETTER_AUTH_URL: server-side better-auth instance reads this at startup
  // for its baseURL — controls cookie domain + auth-API absolute URLs.
  // VITE_BETTER_AUTH_URL: same value, exposed to the client bundle so the
  // browser-side better-auth client POSTs to the tunnel, not localhost.
  //
  // Both are noops in apps that don't use better-auth. Generic.
  const publicOrigin = `https://${HOSTNAME}`;
  const env = {
    ...process.env,
    BETTER_AUTH_URL: publicOrigin,
    VITE_BETTER_AUTH_URL: publicOrigin,
  };

  // nosemgrep: javascript.lang.security.audit.spawn-shell-true.spawn-shell-true - local dev tool; APP is validated above; static literals only
  devProcess = spawn("npm", ["run", `dev:${APP}`], {
    cwd: ROOT_DIR,
    shell: true,
    env,
  });

  devProcess.stdout.on("data", (data) => {
    process.stdout.write(`${colors.cyan}[vite]${colors.reset} ${data}`);
  });

  devProcess.stderr.on("data", (data) => {
    process.stderr.write(`${colors.cyan}[vite]${colors.reset} ${data}`);
  });

  devProcess.on("close", (code) => {
    if (code !== 0 && code !== null) {
      log("vite", colors.red, `Exited with code ${code}`);
    }
  });
}

function cleanup() {
  log("cleanup", colors.yellow, "Shutting down...");
  if (devProcess) devProcess.kill("SIGTERM");
  if (tunnelProcess) tunnelProcess.kill("SIGTERM");
  setTimeout(() => process.exit(0), 2000);
}

process.on("SIGINT", cleanup);
process.on("SIGTERM", cleanup);
process.on("exit", cleanup);

// Silence unused-var lint for APP_DIR; reserved for future per-app cwd if needed.
void APP_DIR;

(async () => {
  try {
    console.log(
      `${colors.bold}${colors.green}Starting ${APP} with Cloudflare tunnel${colors.reset}\n`,
    );
    await startTunnel();
    console.log();
    startDevServer();
    console.log(
      `\n${colors.bold}${colors.green}✓ Both services running${colors.reset}`,
    );
    console.log(`${colors.cyan}Local:${colors.reset}  http://localhost:${PORT}`);
    console.log(`${colors.magenta}Tunnel:${colors.reset} https://${HOSTNAME}`);
    console.log(
      `\n${colors.yellow}Press Ctrl+C to stop both services${colors.reset}\n`,
    );
  } catch (error) {
    log("error", colors.red, error.message);
    cleanup();
    process.exit(1);
  }
})();
