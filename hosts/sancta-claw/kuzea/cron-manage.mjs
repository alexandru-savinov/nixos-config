#!/usr/bin/env node
/**
 * OpenClaw Cron Manager — gateway RPC client
 *
 * Uses the internal OpenClaw GatewayClient to call cron.* RPC methods
 * directly over WebSocket, bypassing the /tools/invoke HTTP endpoint
 * (which only handles tools, not gateway methods).
 *
 * Usage:
 *   node cron-manage.mjs list [--all]
 *   node cron-manage.mjs status
 *   node cron-manage.mjs add <json-file-or-inline-json>
 *   node cron-manage.mjs update <id> <json-patch>
 *   node cron-manage.mjs remove <id>
 *   node cron-manage.mjs run <id>
 *   node cron-manage.mjs runs <id>
 *   node cron-manage.mjs call <method> [json-params]
 *
 * Environment:
 *   OPENCLAW_GATEWAY_URL   (default: ws://127.0.0.1:18789)
 *   OPENCLAW_GATEWAY_TOKEN (default: reads from openclaw config)
 */

import { createRequire } from "node:module";
import { readFileSync, readdirSync, existsSync } from "node:fs";
import { randomUUID } from "node:crypto";
import path from "node:path";

// Resolve the OpenClaw dist directory
const OPENCLAW_DIST = "/var/lib/openclaw/.npm-global/lib/node_modules/openclaw/dist";

// The gateway client lives in a content-hashed bundle file (e.g. call-B3Ur5x-r.js).
// The filename changes on every OpenClaw update, so we resolve it dynamically by
// scanning the dist directory for the expected export signature instead of
// hardcoding a name that will silently break after an upgrade.
function findCallGatewayBundle(distDir) {
  if (!existsSync(distDir)) {
    throw new Error(`OpenClaw dist directory not found: ${distDir}`);
  }
  // Prefer an explicit override via env (useful during upgrades / debugging)
  const override = process.env.OPENCLAW_CALL_BUNDLE;
  if (override) return path.join(distDir, override);

  // Scan for call-*.js files; pick the one that exports `n` (callGateway)
  const candidates = readdirSync(distDir).filter((f) => /^call-[A-Za-z0-9_-]+\.js$/.test(f));
  if (candidates.length === 0) {
    throw new Error(
      `No call-*.js bundle found in ${distDir}. ` +
        "OpenClaw may have been upgraded — set OPENCLAW_CALL_BUNDLE=<filename> to override."
    );
  }
  // Return the first match (there should only be one)
  return path.join(distDir, candidates[0]);
}

const callBundlePath = findCallGatewayBundle(OPENCLAW_DIST);
const { n: callGateway } = await import(callBundlePath);

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

// If OPENCLAW_GATEWAY_URL is set, treat as explicit override (requires token too).
// Otherwise let callGateway resolve from ~/.openclaw/openclaw.json automatically.
const GW_URL = process.env.OPENCLAW_GATEWAY_URL || undefined;
const GW_TOKEN = process.env.OPENCLAW_GATEWAY_TOKEN || process.env.CLAWDBOT_GATEWAY_TOKEN || undefined;

async function rpc(method, params = {}, { timeout = 30000, expectFinal = false } = {}) {
  const opts = {
    method,
    params,
    timeoutMs: timeout,
    expectFinal,
    clientName: "gateway-client",
    mode: "backend",
    scopes: ["operator.admin"],
  };
  if (GW_URL) opts.url = GW_URL;
  if (GW_TOKEN) opts.token = GW_TOKEN;
  return await callGateway(opts);
}

function parseJsonArg(arg) {
  if (!arg) return {};
  // If it looks like a file path, read it
  if (arg.endsWith(".json") || arg.startsWith("/") || arg.startsWith("./")) {
    try {
      return JSON.parse(readFileSync(arg, "utf8"));
    } catch {
      // fall through to parse as inline JSON
    }
  }
  return JSON.parse(arg);
}

function printJson(obj) {
  console.log(JSON.stringify(obj, null, 2));
}

function printTable(jobs) {
  if (!jobs || jobs.length === 0) {
    console.log("(no jobs)");
    return;
  }
  const now = Date.now();
  for (const job of jobs) {
    const next = job.state?.nextRunAtMs
      ? new Date(job.state.nextRunAtMs).toISOString()
      : "—";
    const status = job.enabled ? "ON " : "OFF";
    const sched =
      job.schedule?.kind === "cron"
        ? job.schedule.expr
        : job.schedule?.kind === "every"
        ? `every ${job.schedule.everyMs}ms`
        : job.schedule?.kind === "at"
        ? `at ${job.schedule.at}`
        : "?";
    console.log(
      `  [${status}] ${job.id}  ${job.name || "(unnamed)"}  schedule=${sched}  next=${next}`
    );
  }
}

// ---------------------------------------------------------------------------
// commands
// ---------------------------------------------------------------------------

const [, , command, ...rest] = process.argv;

try {
  switch (command) {
    case "list": {
      const includeDisabled = rest.includes("--all");
      const res = await rpc("cron.list", { includeDisabled });
      if (rest.includes("--json")) {
        printJson(res);
      } else {
        console.log(`Cron jobs (${res.jobs?.length ?? 0}):`);
        printTable(res.jobs);
      }
      break;
    }

    case "status": {
      const res = await rpc("cron.status", {});
      printJson(res);
      break;
    }

    case "add": {
      const input = rest[0];
      if (!input) {
        console.error("Usage: cron-manage.mjs add <json-file-or-inline-json>");
        console.error("\nExample (inline):");
        console.error(`  node cron-manage.mjs add '${JSON.stringify({
          name: "test-job",
          schedule: { kind: "cron", expr: "0 9 * * *", tz: "Europe/Chisinau" },
          sessionTarget: "isolated",
          wakeMode: "now",
          payload: { kind: "systemEvent", text: "Hello from cron" },
          delivery: { mode: "none" },
        })}'`);
        process.exit(1);
      }
      const jobDef = parseJsonArg(input);
      const res = await rpc("cron.add", jobDef);
      console.log("Job added:");
      printJson(res);
      break;
    }

    case "update": {
      const id = rest[0];
      const patchArg = rest[1];
      if (!id) {
        console.error("Usage: cron-manage.mjs update <id> <json-patch>");
        process.exit(1);
      }
      const patch = patchArg ? parseJsonArg(patchArg) : {};
      const res = await rpc("cron.update", { id, ...patch });
      console.log("Job updated:");
      printJson(res);
      break;
    }

    case "remove": {
      const id = rest[0];
      if (!id) {
        console.error("Usage: cron-manage.mjs remove <id>");
        process.exit(1);
      }
      const res = await rpc("cron.remove", { id });
      console.log("Job removed:");
      printJson(res);
      break;
    }

    case "run": {
      const id = rest[0];
      if (!id) {
        console.error("Usage: cron-manage.mjs run <id>");
        process.exit(1);
      }
      const res = await rpc("cron.run", { id });
      console.log("Job triggered:");
      printJson(res);
      break;
    }

    case "runs": {
      const id = rest[0];
      if (!id) {
        console.error("Usage: cron-manage.mjs runs <id>");
        process.exit(1);
      }
      const res = await rpc("cron.runs", { id });
      printJson(res);
      break;
    }

    case "call": {
      // Generic RPC call: cron-manage.mjs call <method> [json-params]
      const method = rest[0];
      const params = rest[1] ? parseJsonArg(rest[1]) : {};
      if (!method) {
        console.error("Usage: cron-manage.mjs call <method> [json-params]");
        console.error("Examples:");
        console.error('  node cron-manage.mjs call health');
        console.error('  node cron-manage.mjs call system-event \'{"text":"hello"}\'');
        process.exit(1);
      }
      const res = await rpc(method, params);
      printJson(res);
      break;
    }

    default:
      console.log(`OpenClaw Cron Manager

Usage: node cron-manage.mjs <command> [args]

Commands:
  list [--all] [--json]     List cron jobs (--all includes disabled)
  status                    Show cron scheduler status
  add <json>                Add a new cron job (JSON file or inline)
  update <id> <json>        Update a cron job
  remove <id>               Remove a cron job
  run <id>                  Trigger a job immediately
  runs <id>                 Show run history for a job
  call <method> [json]      Call any gateway RPC method

Environment:
  OPENCLAW_GATEWAY_URL      Gateway WebSocket URL (default: ws://127.0.0.1:18789)
  OPENCLAW_GATEWAY_TOKEN    Auth token (reads from config if not set)
`);
      break;
  }
} catch (err) {
  console.error(`Error: ${err.message}`);
  process.exit(1);
}
