#!/usr/bin/env node
// Shared-memory commons — librarian (the SOLE writer of the SQLite store).
//
// Ingests inbox envelopes into a tolerant WAL table, dedups by content_hash,
// quarantines unparseable junk, materializes view.json. Idempotent — safe to
// run on a 60s timer + inotify nudge. Uses the sqlite3 CLI (no npm deps);
// all values are JS-escaped before they reach SQL.
//
// Env: SM_STATE (~/.sharedmem)
const fs = require('fs');
const path = require('path');
const { execFileSync } = require('child_process');

const STATE = process.env.SM_STATE || path.join(process.env.HOME || '/tmp', '.sharedmem');
const DB    = path.join(STATE, 'memory.db');
const INBOX = path.join(STATE, 'inbox');
const PROC  = path.join(STATE, 'processed');
const QUAR  = path.join(STATE, 'quarantine');
const VIEW  = path.join(STATE, 'view.json');
for (const d of [INBOX, PROC, QUAR]) fs.mkdirSync(d, { recursive: true });

const sql = (s) => execFileSync('sqlite3', [DB], { input: s, maxBuffer: 64 << 20 }).toString();
const q = (s) => "'" + String(s ?? '').replace(/'/g, "''") + "'";

sql(`PRAGMA journal_mode=WAL;
CREATE TABLE IF NOT EXISTS atoms(
  rowid INTEGER PRIMARY KEY, id TEXT, agent TEXT, node TEXT, ts TEXT, kind TEXT,
  text TEXT, entities TEXT, blob TEXT, raw TEXT, meta TEXT,
  content_hash TEXT UNIQUE, status TEXT, confidence REAL, to_addr TEXT, topic TEXT);`);

let ingested = 0, dup = 0, quar = 0;
for (const f of fs.readdirSync(INBOX).filter((n) => n.endsWith('.json'))) {
  const fp = path.join(INBOX, f);
  const content = fs.readFileSync(fp, 'utf8');
  let m, raw;
  try {
    const env = JSON.parse(content);
    if (!env || !env.meta || !env.meta.sha256) throw 0;
    m = env.meta;
    raw = env.raw == null ? '' : (typeof env.raw === 'string' ? env.raw : JSON.stringify(env.raw));
  } catch (_) {
    // BARE DROP — any file is acceptable. The writer knew nothing about the
    // schema; we hash its bytes and ingest. Only truly empty files are junk.
    if (!content.trim()) { fs.renameSync(fp, path.join(QUAR, f)); quar++; continue; }
    raw = content;
    m = { id: path.basename(f, '.json'), ts: new Date().toISOString(), agent: null, to: null, topic: null,
          sha256: require('crypto').createHash('sha256').update(content).digest('hex') };
  }
  // tolerant: the raw payload MAY itself be a JSON atom/record — pull a few fields if so
  let kind = '', text = '', blob = '';
  try { const r = JSON.parse(raw); kind = r.kind || ''; text = r.statement || r.text || r.summary || ''; blob = JSON.stringify(r); } catch (_) {}

  const out = sql(
    `INSERT OR IGNORE INTO atoms(id,agent,node,ts,kind,text,entities,blob,raw,meta,content_hash,status,confidence,to_addr,topic) ` +
    `VALUES(${q(m.id)},${q(m.agent)},${q(m.node)},${q(m.ts)},${q(kind)},${q(text)},'',${q(blob)},${q(raw)},${q(JSON.stringify(m))},${q(m.sha256)},'',NULL,${q(m.to)},${q(m.topic)}); ` +
    `SELECT changes();`
  );
  (parseInt(out.trim(), 10) > 0) ? ingested++ : dup++;
  fs.renameSync(fp, path.join(PROC, f));
}

// materialize a small read view served by GET /view
const total = parseInt(sql(`SELECT count(*) FROM atoms;`).trim(), 10) || 0;
const recent = sql(`SELECT coalesce(json_group_array(json_object('id',id,'agent',agent,'ts',ts,'kind',kind,'topic',topic,'text',substr(coalesce(nullif(text,''),raw),1,120))),'[]') FROM (SELECT * FROM atoms ORDER BY rowid DESC LIMIT 50);`).trim();
fs.writeFileSync(VIEW, JSON.stringify({ records: total, recent: JSON.parse(recent || '[]') }));

console.log(`librarian: +${ingested} ingested · ${dup} dup · ${quar} quarantined · total ${total}`);
