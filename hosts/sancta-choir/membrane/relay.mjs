import fs from "fs";
import { open, readFile, rename, stat, unlink, writeFile } from "fs/promises";
import { spawn } from "child_process";
import crypto from "crypto";
import path from "path";

const inbox = process.env.SANCTA_INBOX;
const replies = process.env.SANCTA_REPLIES;
const cursorFile = process.env.SANCTA_CURSOR;
const failureFile = process.env.SANCTA_FAILURE;
const readyFile = process.env.SANCTA_WORKER_READY;
const claudeBin = process.env.CLAUDE_BIN;
const claudeArgs = JSON.parse(process.env.CLAUDE_ARGS_JSON);
const projectDir = process.env.SANCTA_PROJECT_DIR;

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const log = message => process.stdout.write(new Date().toISOString() + " " + message + "\n");

function validateRuntime() {
  const required = { inbox, replies, cursorFile, failureFile, claudeBin, projectDir };
  for (const [name, value] of Object.entries(required)) {
    if (!value) throw new Error("missing runtime setting: " + name);
  }
  if (!Array.isArray(claudeArgs)) throw new Error("CLAUDE_ARGS_JSON must be an array");
  if (process.env.SANCTA_REQUIRE_CREDENTIAL === "1"
      && !process.env.ANTHROPIC_API_KEY
      && !process.env.CLAUDE_CODE_OAUTH_TOKEN) {
    throw new Error("missing Claude credential");
  }
  fs.accessSync(claudeBin, fs.constants.X_OK);
  fs.accessSync(projectDir, fs.constants.R_OK | fs.constants.X_OK);
  fs.accessSync(path.dirname(cursorFile), fs.constants.R_OK | fs.constants.W_OK | fs.constants.X_OK);
}

function markReady() {
  if (!readyFile) return;
  fs.writeFileSync(readyFile, "", { mode: 0o600 });
  fs.chmodSync(readyFile, 0o600);
}

function checkpointKey(offset, inboxTs, line) {
  const hash = crypto.createHash("sha256").update(line, "utf8").digest("hex");
  return { key: `${offset}:${inboxTs || ""}:${hash}`, hash };
}

async function loadCommittedCheckpoints() {
  const committed = new Set();
  let raw;
  try { raw = await readFile(replies, "utf8"); } catch (error) {
    if (error.code === "ENOENT") return committed;
    throw error;
  }
  for (const line of raw.split("\n")) {
    if (!line) continue;
    try {
      const reply = JSON.parse(line);
      if (reply.source === "sancta-worker" && typeof reply.inbox_checkpoint === "string") {
        committed.add(reply.inbox_checkpoint);
      }
    } catch (error) {
      log("ignoring malformed reply checkpoint: " + error.message);
    }
  }
  return committed;
}

async function appendReply(reply) {
  let previous = "";
  try { previous = await readFile(replies, "utf8"); } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  const temporary = replies + ".tmp";
  const handle = await open(temporary, "w", 0o600);
  try {
    await handle.writeFile(previous + JSON.stringify(reply) + "\n", "utf8");
    await handle.sync();
  } finally {
    await handle.close();
  }
  await rename(temporary, replies);
}

async function saveCursor(offset) {
  const temporary = cursorFile + ".tmp";
  await writeFile(temporary, JSON.stringify({ offset }) + "\n", { mode: 0o600 });
  await rename(temporary, cursorFile);
}
async function saveFailure(offset, inboxTs, reason) {
  const temporary = failureFile + ".tmp";
  const failure = {
    ts: new Date().toISOString(),
    inbox_ts: inboxTs || null,
    offset,
    reason,
  };
  await writeFile(temporary, JSON.stringify(failure) + "\n", { mode: 0o600 });
  await rename(temporary, failureFile);
}

async function loadFailure() {
  let raw;
  try { raw = await readFile(failureFile, "utf8"); } catch (error) {
    if (error.code === "ENOENT") return null;
    throw error;
  }
  try {
    const failure = JSON.parse(raw);
    if (!Number.isSafeInteger(failure.offset) || failure.offset < 0
        || typeof failure.reason !== "string") {
      throw new Error("invalid failure marker");
    }
    return failure;
  } catch {
    throw new Error("failure marker unreadable");
  }
}

async function clearFailure() {
  try { await unlink(failureFile); } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
}

async function loadCursor() {
  try {
    const saved = JSON.parse(await readFile(cursorFile, "utf8"));
    if (Number.isSafeInteger(saved.offset) && saved.offset >= 0) return saved.offset;
  } catch (error) {
    if (error.code !== "ENOENT") log("ignoring invalid cursor: " + error.message);
  }

  let size = 0;
  try { size = (await stat(inbox)).size; } catch (error) {
    if (error.code !== "ENOENT") throw error;
  }
  await saveCursor(size);
  log("initialized cursor at current inbox end: " + size);
  return size;
}

function textFromEvent(event) {
  if (event.type === "result" && typeof event.result === "string") return event.result;
  if (event.type !== "assistant" || !Array.isArray(event.message?.content)) return "";
  return event.message.content
    .filter(block => block.type === "text" && typeof block.text === "string")
    .map(block => block.text)
    .join("\n");
}

async function runTurn(message, inboxTs, checkpoint, inboxOffset, nextOffset) {
  log("starting resumed turn for inbox ts=" + (inboxTs || "unknown"));
  const child = spawn(claudeBin, claudeArgs, {
    cwd: projectDir,
    env: process.env,
    stdio: ["pipe", "pipe", "pipe"],
  });

  let stdoutBuffer = "";
  let assistantText = "";
  let resultText = "";

  child.stdout.setEncoding("utf8");
  child.stdout.on("data", chunk => {
    stdoutBuffer += chunk;
    const lines = stdoutBuffer.split("\n");
    stdoutBuffer = lines.pop() || "";
    for (const line of lines) {
      if (!line.trim()) continue;
      try {
        const event = JSON.parse(line);
        const text = textFromEvent(event);
        if (event.type === "result" && text) resultText = text;
        else if (event.type === "assistant" && text) assistantText = text;
      } catch (error) {
        log("ignoring malformed Claude output event: " + error.message);
      }
    }
  });
  child.stderr.resume();

  const input = {
    type: "user",
    message: { role: "user", content: [{ type: "text", text: message }] },
  };
  child.stdin.end(JSON.stringify(input) + "\n");

  const exitCode = await new Promise((resolve, reject) => {
    child.on("error", reject);
    child.on("close", resolve);
  });
  if (exitCode !== 0) {
    throw new Error("Claude exited " + exitCode);
  }

  const text = (resultText || assistantText).trim();
  if (!text) throw new Error("Claude completed without assistant text");
  const reply = {
    ts: new Date().toISOString(),
    from: "sancta",
    text,
    source: "sancta-worker",
    inbox_ts: inboxTs || null,
    inbox_offset: inboxOffset,
    inbox_next_offset: nextOffset,
    inbox_hash: checkpoint.hash,
    inbox_checkpoint: checkpoint.key,
  };
  try {
    await appendReply(reply);
  } catch {
    throw new Error("reply commit failed after Claude success");
  }
  log("appended live reply for inbox ts=" + (inboxTs || "unknown"));
}

validateRuntime();
let offset = await loadCursor();
const committedCheckpoints = await loadCommittedCheckpoints();
let unresolvedFailure = await loadFailure();
if (unresolvedFailure && unresolvedFailure.offset < offset) {
  await clearFailure();
  unresolvedFailure = null;
}
markReady();
log("relay initialized and ready");
for (;;) {
  let size;
  try { size = (await stat(inbox)).size; } catch (error) {
    if (error.code === "ENOENT") { await sleep(500); continue; }
    throw error;
  }
  if (size < offset) {
    log("inbox shrank; clamping cursor to current EOF: " + size);
    offset = size;
    await saveCursor(offset);
  }
  if (size === offset) { await sleep(500); continue; }

  const length = size - offset;
  const buffer = Buffer.alloc(length);
  const handle = await open(inbox, "r");
  try { await handle.read(buffer, 0, length, offset); } finally { await handle.close(); }
  const newline = buffer.lastIndexOf(10);
  if (newline < 0) { await sleep(500); continue; }

  const complete = buffer.subarray(0, newline + 1).toString("utf8");
  for (const line of complete.slice(0, -1).split("\n")) {
    const bytes = Buffer.byteLength(line + "\n");
    let entry;
    try {
      entry = line ? JSON.parse(line) : null;
    } catch (error) {
      await saveFailure(offset, null, "invalid inbox JSON");
      throw new Error("invalid inbox JSON at offset " + offset);
    }
    if (entry?.decision === "proceed" && typeof entry.message === "string" && entry.message.trim()) {
      const checkpoint = checkpointKey(offset, entry.ts, line);
      if (committedCheckpoints.has(checkpoint.key)) {
        log("reply checkpoint already committed; advancing cursor without replay at " + offset);
        offset += bytes;
        await saveCursor(offset);
        await clearFailure();
        unresolvedFailure = null;
        continue;
      }
      if (unresolvedFailure) {
        throw new Error("unresolved prior turn requires operator review");
      }
      try {
        await saveFailure(offset, entry.ts, "Claude turn in progress");
        unresolvedFailure = { offset, inbox_ts: entry.ts || null, reason: "Claude turn in progress" };
        await runTurn(entry.message, entry.ts, checkpoint, offset, offset + bytes);
        committedCheckpoints.add(checkpoint.key);
        offset += bytes;
        await saveCursor(offset);
        await clearFailure();
        unresolvedFailure = null;
        continue;
      } catch (error) {
        const reason = /^Claude exited [0-9]+$/.test(error.message)
          ? error.message
          : error.message === "Claude completed without assistant text"
            ? error.message
            : error.message === "reply commit failed after Claude success"
              ? error.message
              : "Claude invocation failed";
        await saveFailure(offset, entry.ts, reason);
        unresolvedFailure = { offset, inbox_ts: entry.ts || null, reason };
        log("resumed turn failed; cursor retained at " + offset);
        throw new Error(reason);
      }
    }
    offset += bytes;
    await saveCursor(offset);
  }
}
