#!/usr/bin/env node
// comm/server.mjs — communication membrane iPhone gateway
// Loopback-only service; Tailscale Serve provides the authenticated HTTPS edge.
// POST /send {message} → runs comm-membrane via stdin (no shell/argv) → {decision, line}
// GET  /              → index.html
// GET  /thread-merged → chronological merged thread (PII-redacted)
// GET  /sim           → membrane-simulation HTML page
// All else            → 405

'use strict';

import http             from 'http';
import fs               from 'fs';
import path             from 'path';
import { fileURLToPath } from 'url';
import { execFile }     from 'child_process';
import crypto           from 'crypto';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

const PORT           = parseInt(process.env.PORT || '8743', 10);
const BIND           = process.env.BIND          || '127.0.0.1';
const INDEX_DIR      = process.env.SANCTA_INDEX_DIR || path.join(__dirname, '..');
const HTML_FILE      = path.join(__dirname, 'index.html');
const INBOX_FILE     = path.join(INDEX_DIR, 'comm-inbox.jsonl');
const REPLIES_FILE   = path.join(INDEX_DIR, 'comm-replies.jsonl');
const HEARTBEAT_FILE = path.join(INDEX_DIR, 'comm-heartbeat.json');
const MEMBRANE_PATH  = process.env.SANCTA_MEMBRANE_PATH || path.join(__dirname, '..', 'bin', 'comm-membrane');

function log(...args) {
  process.stdout.write(new Date().toISOString() + ' ' + args.join(' ') + '\n');
}

// Run the membrane without exposing message text in shell syntax or process argv.
function runMembrane(message) {
  return new Promise((resolve) => {
    const child = execFile('node', [MEMBRANE_PATH], { timeout: 10000 }, (err, stdout, stderr) => {
      const line = (stdout || '').trim();
      // err is set for any non-zero exit; err.code carries the exit code.
      const code = err ? (err.code ?? 2) : 0;
      // Map exit code → decision label
      let decision;
      if      (code === 0) decision = 'proceed';
      else if (code === 1) decision = 'block';
      else                 decision = 'escalate';
      resolve({ decision, line, code });
    });
    child.stdin.on('error', () => {});
    child.stdin.end(message);
  });
}

// Append to inbox (only for proceed + escalate; NEVER log raw blocked messages)
function appendInbox(ts, decision, message) {
  if (decision === 'block') {
    // log the structural event only — no raw text
    fs.appendFileSync(INBOX_FILE, JSON.stringify({ ts, decision: 'block' }) + '\n', { mode: 0o600 });
  } else {
    fs.appendFileSync(INBOX_FILE, JSON.stringify({ ts, decision, message }) + '\n', { mode: 0o600 });
  }
}

function messageHash(message) {
  return crypto.createHash('sha256').update(message, 'utf8').digest('hex').slice(0, 16);
}

// Read all lines from a JSONL file; returns [] on missing/empty/corrupt file
function readJSONL(filepath) {
  try {
    const raw = fs.readFileSync(filepath, 'utf8').trim();
    if (!raw) return [];
    return raw.split('\n').filter(Boolean).map(line => {
      try { return JSON.parse(line); } catch { return null; }
    }).filter(Boolean);
  } catch {
    return [];
  }
}

// Redact obvious PII classes: email addresses, 7+ digit runs, @handles
function redactPII(text) {
  return String(text)
    .replace(/[a-zA-Z0-9._%+\-]+@[a-zA-Z0-9.\-]+\.[a-zA-Z]{2,}/g, '[email]')
    .replace(/\b\d{7,}\b/g, '[number]')
    .replace(/@[A-Za-z0-9_]+/g, '[handle]');
}

// Read raw body as UTF-8 string (small messages only; cap at 64 KB)
function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let total = 0;
    let tooLarge = false;
    req.on('data', chunk => {
      if (tooLarge) return;
      total += chunk.length;
      if (total > 65536) {
        tooLarge = true;
        chunks.length = 0;
        return;
      }
      chunks.push(chunk);
    });
    req.on('end', () => {
      if (tooLarge) reject(new Error('body too large'));
      else resolve(Buffer.concat(chunks).toString('utf8'));
    });
    req.on('error', reject);
  });
}

const SIM_HTML = `<!DOCTYPE html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Sancta · Membrane Sim</title>
<style>
  *{box-sizing:border-box;margin:0;padding:0}
  body{font-family:monospace;background:#0d0d0d;color:#e0e0e0;min-height:100vh;display:flex;flex-direction:column}
  header{padding:10px 16px;background:#111;border-bottom:1px solid #222;font-size:13px;color:#888;display:flex;align-items:center;gap:8px}
  header span.dot{width:8px;height:8px;border-radius:50%;background:#3a3;display:inline-block;animation:pulse 2s infinite}
  @keyframes pulse{0%,100%{opacity:1}50%{opacity:.4}}
  #thread{flex:1;overflow-y:auto;padding:16px;display:flex;flex-direction:column;gap:10px}
  .bubble{max-width:72%;padding:8px 12px;border-radius:12px;font-size:13px;line-height:1.5;word-break:break-word}
  .alex{align-self:flex-end;background:#1a3a5c;border-bottom-right-radius:3px}
  .sancta{align-self:flex-start;background:#1a1a2e;border:1px solid #2a2a4a;border-bottom-left-radius:3px}
  .meta{font-size:10px;color:#555;margin-top:4px}
  .alex .meta{text-align:right}
  .tag{display:inline-block;font-size:9px;padding:1px 5px;border-radius:3px;margin-left:6px;vertical-align:middle}
  .tag.proceed{background:#1a4a1a;color:#5d5}
  .tag.escalate{background:#4a2a00;color:#da0}
  .tag.block{background:#4a1a1a;color:#d55}
  #status{padding:6px 16px;font-size:11px;color:#444;border-top:1px solid #1a1a1a}
  .empty{color:#333;text-align:center;margin:40px auto;font-size:13px}
</style>
</head>
<body>
<header>
  <span class="dot"></span>
  Sancta · Membrane Simulation &nbsp;·&nbsp; PII-redacted view &nbsp;·&nbsp; polls every 4s
</header>
<div id="thread"><div class="empty">loading thread…</div></div>
<div id="status">—</div>
<script>
const threadEl = document.getElementById('thread');
const statusEl = document.getElementById('status');

function fmt(ts) {
  try {
    const d = new Date(ts);
    return d.toISOString().replace('T',' ').replace(/\\.\\d{3}Z$/, ' UTC');
  } catch(e) { return ts || ''; }
}

function escHtml(s) {
  return String(s)
    .replace(/&/g,'&amp;').replace(/</g,'&lt;').replace(/>/g,'&gt;')
    .replace(/"/g,'&quot;').replace(/\\n/g,'<br>');
}

function render(entries) {
  if (!entries || !entries.length) {
    threadEl.innerHTML = '<div class="empty">no messages yet</div>';
    return;
  }
  threadEl.innerHTML = entries.map(function(e) {
    const cls = e.role === 'alex' ? 'alex' : 'sancta';
    const tag = e.decision ? '<span class="tag ' + e.decision + '">' + e.decision + '</span>' : '';
    const who = e.role === 'alex' ? 'Alexandru' : 'Sancta';
    return '<div class="bubble ' + cls + '">' +
      escHtml(e.text) +
      '<div class="meta">' + who + tag + ' &nbsp; ' + fmt(e.ts) + '</div>' +
      '</div>';
  }).join('');
  threadEl.scrollTop = threadEl.scrollHeight;
}

function poll() {
  fetch('/thread-merged')
    .then(function(r) { if (!r.ok) throw new Error('HTTP ' + r.status); return r.json(); })
    .then(function(data) {
      render(data.thread || []);
      statusEl.textContent = 'last update: ' + new Date().toISOString() + '  entries: ' + (data.thread||[]).length;
    })
    .catch(function(err) {
      statusEl.textContent = 'poll error: ' + err.message;
    });
}

poll();
setInterval(poll, 4000);
</script>
</body>
</html>`;

const server = http.createServer(async (req, res) => {
  const ip  = req.socket.remoteAddress || '?';
  const url = (req.url || '/').split('?')[0];
  log(`[req] ${req.method} ${url} from ${ip}`);

  // ── GET / → index.html ──────────────────────────────────────────────────────
  if (req.method === 'GET' && url === '/') {
    let html;
    try { html = fs.readFileSync(HTML_FILE, 'utf8'); }
    catch (e) { res.writeHead(500); return res.end('index.html not found'); }
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-cache' });
    return res.end(html);
  }

  // ── POST /send → membrane ───────────────────────────────────────────────────
  if (req.method === 'POST' && url === '/send') {
    let body;
    try { body = await readBody(req); }
    catch (e) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: e.message }));
    }

    let parsed;
    try { parsed = JSON.parse(body); }
    catch {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'invalid JSON' }));
    }

    const message = String(parsed.message || '').trim();
    if (!message) {
      res.writeHead(400, { 'Content-Type': 'application/json' });
      return res.end(JSON.stringify({ error: 'message required' }));
    }

    const { decision, line } = await runMembrane(message);
    const ts = new Date().toISOString();
    try {
      appendInbox(ts, decision, message);
    } catch (error) {
      log('[inbox-write-error]', error.message);
      res.writeHead(503, { 'Content-Type': 'application/json; charset=utf-8' });
      return res.end(JSON.stringify({ error: 'message not accepted' }));
    }

    log(`[membrane] decision=${decision} msg_hash=${messageHash(message)}`);

    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-cache' });
    return res.end(JSON.stringify({ decision, line }));
  }

  // ── GET /heartbeat → comm-heartbeat.json ────────────────────────────────────
  if (req.method === 'GET' && url === '/heartbeat') {
    let hb;
    try { hb = fs.readFileSync(HEARTBEAT_FILE, 'utf8'); }
    catch { hb = JSON.stringify({ error: 'no heartbeat file', ts: null, status: 'unknown' }); }
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-cache' });
    return res.end(hb);
  }

  // ── GET /thread → merged inbox (proceed|escalate) + sancta replies ──────────
  if (req.method === 'GET' && url === '/thread') {
    const inbox   = readJSONL(INBOX_FILE);
    const sent    = inbox
      .filter(e => e.decision === 'proceed' || e.decision === 'escalate')
      .map(e => ({ ts: e.ts, decision: e.decision, message: e.message || '' }));
    const replies = readJSONL(REPLIES_FILE)
      .map(e => ({ ts: e.ts, from: e.from || 'sancta', text: e.text || '' }));
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-cache' });
    return res.end(JSON.stringify({ sent, replies }));
  }

  // ── GET /thread-merged → single chronological array (sorted by ts, PII-redacted) ──
  if (req.method === 'GET' && url === '/thread-merged') {
    const inbox   = readJSONL(INBOX_FILE);
    const replies = readJSONL(REPLIES_FILE);

    const alexEntries = inbox
      .filter(e => e.decision === 'proceed' || e.decision === 'escalate')
      .map(e => ({ ts: e.ts, role: 'alex', text: redactPII(e.message || ''), decision: e.decision }));

    const sanctaEntries = replies
      .map(e => ({ ts: e.ts, role: 'sancta', text: redactPII(e.text || '') }));

    const thread = [...alexEntries, ...sanctaEntries]
      .sort((a, b) => (a.ts < b.ts ? -1 : a.ts > b.ts ? 1 : 0));

    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-cache' });
    return res.end(JSON.stringify({ thread }));
  }

  // ── GET /sim → membrane-simulation HTML page (PII-redacted chat bubbles) ────
  if (req.method === 'GET' && url === '/sim') {
    res.writeHead(200, { 'Content-Type': 'text/html; charset=utf-8', 'Cache-Control': 'no-cache' });
    return res.end(SIM_HTML);
  }

  // ── Everything else → 405 ───────────────────────────────────────────────────
  res.writeHead(405, { Allow: 'GET, POST' });
  return res.end('Method Not Allowed');
});

server.requestTimeout   = 15000;
server.headersTimeout   = 10000;
server.keepAliveTimeout = 65000;

server.listen(PORT, BIND, () => {
  log(`[comm-8743] listening on http://${BIND}:${PORT} — comm membrane gateway`);
});

process.on('uncaughtException', err => {
  log('[uncaught]', err.message);
  process.exit(1);
});
process.on('unhandledRejection', err => {
  log('[unhandled]', err && err.message);
  process.exit(1);
});
