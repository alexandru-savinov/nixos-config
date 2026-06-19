#!/usr/bin/env node
// Shared-memory commons — HTTP ingest (single-owner drop-box writer).
//
// Any agent POSTs /write however it can (curl is enough). The service only ever
// appends an IMMUTABLE envelope to the inbox via temp+rename — it never touches
// the DB and never rewrites another agent's bytes. The librarian (separate, the
// SOLE DB writer) ingests the inbox. Reads are served from the materialized view.
// Auth is a no-op-allow seam (admit()) — later: Tailscale node identity / age sig.
//
// Env: SM_BIND_IP (default 127.0.0.1) · SM_PORT (8730) · SM_STATE (~/.sharedmem)
const http = require('http');
const fs = require('fs');
const path = require('path');
const crypto = require('crypto');

const BIND  = process.env.SM_BIND_IP || '127.0.0.1';
const PORT  = parseInt(process.env.SM_PORT || '8730', 10);
const STATE = process.env.SM_STATE || path.join(process.env.HOME || '/tmp', '.sharedmem');
const INBOX = path.join(STATE, 'inbox');
const VIEW  = path.join(STATE, 'view.json');
const SOFT  = 1  * (1 << 20); //  1 MiB — flagged, still accepted
const HARD  = 20 * (1 << 20); // 20 MiB — rejected (413)

fs.mkdirSync(INBOX, { recursive: true });

// AUTH SEAM — MVP allows everyone. The whole future auth story slots in here.
function admit(_req) { return true; }

function send(res, code, obj) {
  res.writeHead(code, { 'content-type': 'application/json' });
  res.end(JSON.stringify(obj));
}

const server = http.createServer((req, res) => {
  const url = (req.url || '/').split('?')[0];

  if (req.method === 'GET' && url === '/healthz') return send(res, 200, { ok: true });

  if (req.method === 'GET' && url === '/view') {
    return fs.readFile(VIEW, (e, d) => {
      if (e) return send(res, 200, { records: 0, note: 'no view materialized yet' });
      res.writeHead(200, { 'content-type': 'application/json' });
      res.end(d);
    });
  }

  if (req.method === 'POST' && url === '/write') {
    if (!admit(req)) return send(res, 403, { error: 'denied' });
    let size = 0;
    const chunks = []; // capped at HARD; extra bytes are counted but not buffered
    req.on('data', (c) => { size += c.length; if (size <= HARD) chunks.push(c); });
    req.on('error', () => { try { send(res, 400, { error: 'stream error' }); } catch (_) {} });
    req.on('end', () => {
      if (size > HARD) return send(res, 413, { error: 'too large', limit_bytes: HARD });
      const raw = Buffer.concat(chunks).toString('utf8');
      const sha = crypto.createHash('sha256').update(raw).digest('hex');
      const id = Date.now().toString(36) + '-' + crypto.randomBytes(5).toString('hex');
      const remote = String(req.socket.remoteAddress || '').replace('::ffff:', '');
      const envelope = {
        meta: {
          id, ts: new Date().toISOString(), remote, size, sha256: sha,
          agent: req.headers['x-agent'] || null,
          to:    req.headers['x-to']    || null,   // dormant comms seam
          topic: req.headers['x-topic'] || null,   // dormant comms seam
          soft_exceeded: size > SOFT,
        },
        raw,
      };
      const tmp = path.join(INBOX, id + '.json.tmp');
      const fin = path.join(INBOX, id + '.json');
      // temp+rename: the writer never needs to know this atomic convention
      fs.writeFile(tmp, JSON.stringify(envelope), (e) => {
        if (e) return send(res, 500, { error: 'write failed' });
        fs.rename(tmp, fin, (e2) =>
          e2 ? send(res, 500, { error: 'rename failed' }) : send(res, 200, { ok: true, id, sha256: sha }));
      });
    });
    return;
  }

  send(res, 404, { error: 'not found' });
});

server.listen(PORT, BIND, () => console.log(`shared-memory ingest · ${BIND}:${PORT} · state ${STATE}`));
