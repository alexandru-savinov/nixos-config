import fs from "fs";
import { open, readFile, rename, stat, unlink, writeFile } from "fs/promises";
import { spawn } from "child_process";

const inbox = process.env.SANCTA_INBOX;
const replies = process.env.SANCTA_REPLIES;
const cursorFile = process.env.SANCTA_CURSOR;
const failureFile = process.env.SANCTA_FAILURE;
const claudeBin = process.env.CLAUDE_BIN;
const claudeArgs = JSON.parse(process.env.CLAUDE_ARGS_JSON);

const sleep = ms => new Promise(resolve => setTimeout(resolve, ms));
const log = message => process.stdout.write(new Date().toISOString() + " " + message + "\n");

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

async function runTurn(message, inboxTs) {
  log("starting resumed turn for inbox ts=" + (inboxTs || "unknown"));
  const child = spawn(claudeBin, claudeArgs, {
    cwd: process.env.SANCTA_PROJECT_DIR,
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
  };
  fs.appendFileSync(replies, JSON.stringify(reply) + "\n", { mode: 0o600 });
  await clearFailure();
  log("appended live reply for inbox ts=" + (inboxTs || "unknown"));
}

let offset = await loadCursor();
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
      try {
        await runTurn(entry.message, entry.ts);
      } catch (error) {
        const reason = /^Claude exited [0-9]+$/.test(error.message)
          ? error.message
          : error.message === "Claude completed without assistant text"
            ? error.message
            : "Claude invocation failed";
        await saveFailure(offset, entry.ts, reason);
        log("resumed turn failed; cursor retained at " + offset);
        throw new Error(reason);
      }
    }
    offset += bytes;
    await saveCursor(offset);
  }
}
