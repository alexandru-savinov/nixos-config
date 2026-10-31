import fs from 'node:fs/promises';
import net from 'node:net';
import http from 'node:http';
import https from 'node:https';
import { execFile } from 'node:child_process';
import { Worker } from 'node:worker_threads';
import { duration, validTime } from './common.mjs';
import { tcpTarget } from './schema.mjs';

const LIMIT = 65536;
const CROWDSEC_LIMIT = 4 * 1024 * 1024;
const OSQUERY_TAIL = 4 * 1024 * 1024;
const OSQUERY_DETAIL = 3;
const OSQUERY_DETAIL_LENGTH = 128;
const NETDATA_FRESH = 60000;
// The row key of each pack query. `vacant` says an empty snapshot is a real answer: only
// the event table may be quiet, a host with no listeners, users or wrappers is a blind sensor.
const OSQUERY_QUERIES = new Map([
  ['listening_ports', { columns: ['port', 'protocol', 'name'], vacant: false }],
  ['local_users', { columns: ['username'], vacant: false }],
  ['suid_bins', { columns: ['path'], vacant: false }],
  ['etc_fim', { columns: ['target_path'], vacant: true }],
]);
const answer = (verdict, motiv) => ({ verdict, motiv });
const green = () => answer('verde', 'ok');
const failed = reason => answer('picat', reason);
const unreadable = reason => answer('NECITIT', reason);
const commandEnvironment = env => ({ PATH: env.PATH || '', LANG: 'C', LC_ALL: 'C', TZ: 'UTC' });

async function filesystem(operation, timeout) {
  let timer;
  try {
    return await Promise.race([operation(), new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('filesystem-timeout')), timeout);
    })]);
  } finally { clearTimeout(timer); }
}

// Never return exception messages, command output, URLs or response bodies.
export function command(argv, timeout = 10000, environment = commandEnvironment(process.env)) {
  return new Promise(resolve => {
    const child = execFile(argv[0], argv.slice(1), {
      timeout, killSignal: 'SIGKILL', maxBuffer: LIMIT, encoding: 'utf8',
      windowsHide: true, env: environment,
    }, (error, stdout) => {
      if (error) {
        const missing = ['ENOENT', 'EACCES', 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER'].includes(error.code)
          || error.code === null || error.code === 127 || Boolean(error.signal);
        resolve({ verdict: missing ? 'NECITIT' : 'picat', output: '' });
      } else resolve({ verdict: 'verde', output: stdout });
    });
    child.stdin.end();
  });
}

export function request(url, { headers = {}, timeout = 10000, readBody = true, method = 'GET', body, maxBytes = LIMIT } = {}) {
  return new Promise((resolve, reject) => {
    const client = url.protocol === 'https:' ? https : http;
    let size = 0;
    let timedOut = false;
    const chunks = [];
    // The message stays 'request-failed' on timeout: tcp/http read it as network-unreachable.
    const fail = message => { clearTimeout(timer); reject(Object.assign(new Error(message), { timedOut })); };
    const req = client.request(url, { method, headers }, response => {
      if (!readBody) {
        clearTimeout(timer);
        resolve({ status: response.statusCode, body: '' });
        response.destroy();
        return;
      }
      response.on('data', chunk => {
        size += chunk.length;
        if (size > maxBytes) req.destroy(new Error('response-limit'));
        else chunks.push(chunk);
      });
      response.on('error', () => fail('response-unreadable'));
      response.on('end', () => {
        clearTimeout(timer);
        resolve({ status: response.statusCode, body: Buffer.concat(chunks).toString('utf8') });
      });
    });
    const timer = setTimeout(() => { timedOut = true; req.destroy(new Error('request-timeout')); }, timeout);
    req.on('error', error => fail(error.message === 'response-limit' ? 'response-limit' : 'request-failed'));
    req.end(body);
  });
}

function tcp(target) {
  return new Promise(resolve => {
    const socket = net.createConnection(tcpTarget(target));
    const finish = result => { clearTimeout(timer); socket.destroy(); resolve(result); };
    const timer = setTimeout(() => finish(failed('tcp-timeout')), 5000);
    socket.once('connect', () => finish(green()));
    socket.once('error', () => finish(failed('tcp-unreachable')));
  });
}

// A hostile expression cannot stall the main process or its request deadline.
export function matches(pattern, body) {
  return new Promise(resolve => {
    const worker = new Worker(`const {parentPort,workerData}=require('node:worker_threads'); parentPort.postMessage(new RegExp(workerData.pattern).test(workerData.body));`, {
      eval: true, workerData: { pattern, body }, resourceLimits: { maxOldGenerationSizeMb: 16 },
    });
    let settled = false;
    const finish = result => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      void worker.terminate();
      resolve(result);
    };
    // The 500ms budget measures the expression, not worker startup: a loaded host
    // can take longer than that just to boot a worker, which read as NECITIT.
    let timer = setTimeout(() => finish(null), 5000);
    worker.once('online', () => { clearTimeout(timer); timer = setTimeout(() => finish(null), 500); });
    worker.once('message', finish);
    worker.once('error', () => finish(null));
    worker.once('exit', () => finish(null));
  });
}

export function mounted(source, target) {
  const lines = source.trim().split('\n');
  if (!source.trim() || lines.some(line => !/^\d+ \d+ \d+:\d+ \S+ \S+ .* - \S+ /.test(line))) return unreadable('mount-unreadable');
  const decode = value => value.replace(/\\(040|011|012|134)/g, (_, code) => String.fromCharCode(parseInt(code, 8)));
  return lines.some(line => decode(line.split(' ')[4]) === target) ? green() : failed('mount-absent');
}

function age(timestamp, limit, now) {
  if (!Number.isFinite(timestamp) || timestamp <= 0 || timestamp > now) return unreadable('age-unreadable');
  return now - timestamp < limit ? green() : failed('age-stale');
}

// `cscli machines add -f` writes flat YAML. Its url key is deliberately not read:
// the password only ever goes to the contract's tinta, which the schema pins to loopback.
function crowdsecCredentials(source) {
  const fields = {};
  for (const line of source.split(/\r?\n/)) {
    const match = /^(login|password):[ \t]*(.*?)[ \t]*$/.exec(line);
    if (match) fields[match[1]] = match[2].replace(/^(["'])(.*)\1$/, '$2');
  }
  return fields;
}

// Behaviour checked against crowdsec v1.7.2 pkg/database/{alerts,alertfilter}.go and
// pkg/apiserver/controllers/v1/alerts.go:
// - no alerts is the JSON body `null` (a nil Go slice), not [];
// - alerts carry their events and metas, so the body outgrows LIMIT during the very
//   attack being counted; limit=prag is enough to decide and keeps it bounded;
// - scenario also matches an alert's decisions, so a community blocklist pull would
//   match without include_capi=false.
async function crowdsecAlerts(c, { env, io, read, get, started }) {
  if (!env.VIGIL_CROWDSEC_CREDENTIALS) return unreadable('crowdsec-config');
  let source;
  try { source = await read(() => io.readFile(env.VIGIL_CROWDSEC_CREDENTIALS, 'utf8')); } catch { return unreadable('crowdsec-config'); }
  const { login, password } = crowdsecCredentials(source);
  if (!login || !password) return unreadable('crowdsec-config');
  const send = (target, config) => {
    const timeout = 10000 - (performance.now() - started);
    if (timeout <= 0) throw Object.assign(new Error('request-failed'), { timedOut: true });
    return get(new URL(target, c.tinta), { ...config, timeout });
  };
  try {
    const session = await send('/v1/watchers/login', { method: 'POST',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ machine_id: login, password }) });
    if (session.status !== 200) return unreadable('crowdsec-auth');
    let token;
    try { token = JSON.parse(session.body)?.token; } catch { return unreadable('crowdsec-auth'); }
    if (typeof token !== 'string' || !token || /[\r\n]/.test(token)) return unreadable('crowdsec-auth');
    const query = new URLSearchParams({ scenario: c.astept.scenariu, since: `${c.astept.fereastra_min}m`,
      limit: String(c.prag), include_capi: 'false' });
    const response = await send(`/v1/alerts?${query}`, { headers: { Authorization: `Bearer ${token}` }, maxBytes: CROWDSEC_LIMIT });
    if (response.status === 401 || response.status === 403) return unreadable('crowdsec-auth');
    if (response.status !== 200) return unreadable('crowdsec-response');
    let alerts;
    try { alerts = JSON.parse(response.body); } catch { return unreadable('crowdsec-response'); }
    if (alerts !== null && !Array.isArray(alerts)) return unreadable('crowdsec-response');
    return (alerts?.length ?? 0) >= c.prag ? failed('crowdsec-alerts') : green();
  } catch (error) {
    if (error.timedOut) return unreadable('crowdsec-timeout');
    return unreadable(error.message.startsWith('response-') ? 'crowdsec-response' : 'crowdsec-unreachable');
  }
}

// Reads at most `limit` bytes from the end, dropping the first line the cut landed inside.
async function fileTail(io, file, limit) {
  const handle = await io.open(file, 'r');
  try {
    const { size } = await handle.stat();
    const length = Math.min(size, limit);
    const position = size - length;
    const buffer = Buffer.alloc(length);
    let filled = 0;
    while (filled < length) {
      const { bytesRead } = await handle.read(buffer, filled, length - filled, position + filled);
      if (!bytesRead) break;
      filled += bytesRead;
    }
    const tail = buffer.subarray(0, filled);
    if (!position) return tail.toString('utf8');
    const newline = tail.indexOf(10);
    return newline < 0 ? '' : tail.subarray(newline + 1).toString('utf8');
  } finally { await handle.close(); }
}

// Walks newest to oldest and stops at the first match, so an old corrupt line cannot wedge
// the contract. A corrupt line newer than the match means the newest record is unknown.
function newestRecord(text, name) {
  const lines = text.split('\n');
  for (let index = lines.length - 1; index >= 0; index--) {
    if (!lines[index].trim()) continue;
    const record = JSON.parse(lines[index]);
    if (!record || typeof record !== 'object' || Array.isArray(record)) throw new Error('osquery-record');
    if (record.name === name) return record;
  }
  return null;
}

// Shaped from osquery 5.21.0 (osquery/core/query.cpp, dispatcher/scheduler.cpp,
// logger/logger.cpp, plugins/logger/filesystem_logger.cpp):
// - a snapshot query is logged on every run, also with no rows, so silence is a dead sensor;
// - the filesystem logger writes snapshots to osqueryd.snapshots.log, not osqueryd.results.log;
// - one line per run: { snapshot: [rows], action: 'snapshot', name, unixTime: <seconds> };
// - row values are strings unless --logger_numerics is set;
// - with --logger_snapshot_event_type a line per row replaces this shape: never set it.
async function osqueryRows(c, { env, io, read, now }) {
  const query = OSQUERY_QUERIES.get(c.tinta);
  if (!query) return unreadable('osquery-query');
  const interval = Number(env.VIGIL_OSQUERY_INTERVAL);
  if (!env.VIGIL_OSQUERY_RESULTS || !Number.isInteger(interval) || interval <= 0) return unreadable('osquery-config');
  const text = await read(() => fileTail(io, env.VIGIL_OSQUERY_RESULTS, OSQUERY_TAIL));
  const record = newestRecord(text, `pack_vigil_${c.tinta}`);
  if (!record) return unreadable('osquery-absent');
  if (record.action !== 'snapshot' || !Array.isArray(record.snapshot)) return unreadable('osquery-unreadable');
  const taken = record.unixTime * 1000;
  if (!Number.isFinite(taken) || taken <= 0 || taken > now) return unreadable('osquery-unreadable');
  if (now - taken > 2 * interval * 1000) return unreadable('osquery-stale');
  if (!record.snapshot.length && !query.vacant) return unreadable('osquery-empty');
  const allowed = new Set(c.astept.permis);
  const unexpected = new Set();
  for (const row of record.snapshot) {
    const parts = query.columns.map(column => row?.[column]);
    if (parts.some(part => !['string', 'number'].includes(typeof part))) return unreadable('osquery-unreadable');
    const key = parts.join('/');
    if (!allowed.has(key)) unexpected.add(key);
  }
  if (!unexpected.size) return green();
  // Sorted because row order is not stable between runs. Keys are host data: capped, and
  // kept out of motiv, whose fixed vocabulary is what the public dashboard may serialize.
  return { ...failed('osquery-unexpected'),
    detaliu: [...unexpected].sort().slice(0, OSQUERY_DETAIL).map(key => key.slice(0, OSQUERY_DETAIL_LENGTH)) };
}

// Netdata's data API returns one row per points=1 query, or 404 with a plain-text body when
// nothing matches. Each row is { labels, row }; row is absent when the window held no data.
function netdataRow(body) {
  let parsed;
  try { parsed = JSON.parse(body); } catch { throw new Error('response-json'); }
  const { labels, data } = parsed ?? {};
  if (!Array.isArray(labels) || labels[0] !== 'time' || !Array.isArray(data)) throw new Error('response-shape');
  const row = data[0];
  if (row !== undefined && (!Array.isArray(row) || row.length !== labels.length || !Number.isFinite(row[0]))) throw new Error('response-shape');
  return { labels, row };
}

// Verified against Netdata v2.8.4 source (web/api/v1/api_v1_data.c,
// web/api/maps/rrdr_options.c, web/api/queries/query.c,
// ml/ml.cc, ml/ml_public.cc, ml/ad_charts.cc) and a live 2.8.4 daemon:
//   /api/v1/data?chart=<id>&after=-<s>&points=1&group=average&format=json
//     &options=anomaly-bit,unaligned,all-dimensions
// - anomaly-bit swaps each value for its anomaly rate, 0-100;
// - without unaligned the window snaps to a multiple of itself and ends up to <s> in the past;
// - an untrained dimension has no models, so it reports rate 0, exactly like a calm trained
//   one. 0 alone is not evidence, and only a rate below prag can need the gate below;
// - no API exposes training per chart, only per host. /api/v1/ml_info cannot be the gate: its
//   trained-dimensions counts constant metrics, so it read 2150 of 2150 with no model built.
//   netdata.ml_training_status counts constant metrics as trained too, but its untrained
//   count covers variable ones only: untrained equalled netdata.ml_metric_types variable
//   until the 15-minute minimum window passed. Models are then built about one per second,
//   so during the ramp a chart can still be unmodelled with the host gate open. Requiring most
//   variable metrics to be modelled is the closest proxy the API allows.
async function anomalyRate(c, { env, get, now, started }) {
  const interval = Number(env.VIGIL_ANOMALY_INTERVAL);
  if (!env.VIGIL_NETDATA_URL || !Number.isInteger(interval) || interval <= 0) return unreadable('anomaly-config');
  let base;
  try { base = new URL(env.VIGIL_NETDATA_URL); } catch { return unreadable('anomaly-config'); }
  if (base.protocol !== 'http:' || base.username || base.password) return unreadable('anomaly-config');
  const query = async params => {
    const timeout = 10000 - (performance.now() - started);
    if (timeout <= 0) throw Object.assign(new Error('request-failed'), { timedOut: true });
    const search = new URLSearchParams({ points: '1', format: 'json', ...params });
    const response = await get(new URL(`/api/v1/data?${search}`, base), { timeout });
    if (response.status === 404) return null;
    if (response.status !== 200) throw new Error('response-status');
    return netdataRow(response.body);
  };
  const fresh = ({ row }) => Math.abs(now - row[0] * 1000) <= NETDATA_FRESH;
  const counters = context => query({ context, after: '-10', group: 'max' });
  try {
    const rates = await query({ chart: c.tinta, after: `-${interval}`, group: 'average',
      options: 'anomaly-bit,unaligned,all-dimensions' });
    if (!rates) return unreadable('anomaly-chart');
    if (!rates.row) return unreadable('anomaly-nodata');
    if (!fresh(rates)) return unreadable('anomaly-stale');
    const values = rates.row.slice(1).filter(Number.isFinite);
    if (!values.length) return unreadable('anomaly-nodata');
    // A rate this high can only come from a trained dimension, so it needs no gate.
    if (Math.max(...values) >= c.prag) return failed('anomaly-rate');
    const [training, metrics] = [await counters('netdata.ml_training_status'), await counters('netdata.ml_metric_types')];
    if (!training?.row || !metrics?.row) return unreadable('anomaly-untrained');
    if (!fresh(training) || !fresh(metrics)) return unreadable('anomaly-stale');
    const pick = ({ labels, row }, label) => row[labels.indexOf(label)];
    const counts = [pick(training, 'untrained'), pick(training, 'pending-without-model'), pick(metrics, 'variable')];
    if (!counts.every(Number.isFinite)) return unreadable('anomaly-response');
    const [untrained, pending, variable] = counts;
    return (untrained + pending) * 2 >= variable ? unreadable('anomaly-untrained') : green();
  } catch (error) {
    if (error.timedOut) return unreadable('anomaly-timeout');
    return unreadable(error.message.startsWith('response-') ? 'anomaly-response' : 'anomaly-unreachable');
  }
}

export async function check(c, options = {}) {
  const started = performance.now();
  const env = options.env || process.env;
  const now = options.now ?? Date.now();
  const run = options.command || command;
  const get = options.request || request;
  const io = options.fs || fs;
  const read = operation => filesystem(operation, options.fsTimeout ?? 10000);
  try {
    switch (c.verifica) {
      case 'tcp': return await tcp(c.tinta);
      case 'http': {
        const response = await get(new URL(c.tinta), { timeout: c.astept.body ? 9400 : 10000,
          readBody: c.astept.body !== undefined || c.astept.prospetime !== undefined });
        if (response.status !== c.astept.status) return failed('http-status');
        if (c.astept.body !== undefined) {
          const match = await matches(c.astept.body, response.body);
          if (match === null) return unreadable('http-pattern');
          if (!match) return failed('http-body');
        }
        if (c.astept.prospetime !== undefined) {
          let body;
          try { body = JSON.parse(response.body); } catch { return unreadable('http-freshness'); }
          if (!body || !validTime(body.la) || Date.parse(body.la) > now) return unreadable('http-freshness');
          if (now - Date.parse(body.la) >= duration(c.astept.prospetime)) return failed('http-stale');
        }
        return green();
      }
      case 'unit':
      case 'age': {
        if (c.verifica === 'age' && !c.tinta.startsWith('unit:')) {
          const stat = await read(() => io.stat(c.tinta));
          return age(stat.mtimeMs, duration(c.prag), now);
        }
        const unit = c.verifica === 'unit' ? c.tinta : c.tinta.slice(5);
        const result = await run([env.VIGIL_SYSTEMCTL || 'systemctl', 'show', unit,
          '--property=LoadState,ActiveState,Result,ExecMainExitTimestamp', '--no-pager'],
        10000, commandEnvironment(env));
        if (result.verdict !== 'verde') return unreadable('unit-unreadable');
        const properties = Object.fromEntries(result.output.trim().split('\n').map(line => {
          const index = line.indexOf('=');
          return [line.slice(0, index), line.slice(index + 1)];
        }));
        if (properties.LoadState !== 'loaded') return unreadable('unit-unknown');
        if (c.verifica === 'unit') {
          if (!['active', 'inactive', 'failed', 'activating', 'deactivating', 'reloading', 'refreshing'].includes(properties.ActiveState)) return unreadable('unit-unreadable');
          return properties.ActiveState === 'active' ? green() : failed('unit-inactive');
        }
        if (properties.Result !== 'success') return unreadable('unit-result');
        return age(Date.parse(properties.ExecMainExitTimestamp), duration(c.prag), now);
      }
      case 'disk': {
        const stat = await read(() => io.statfs(c.tinta));
        if (![stat.blocks, stat.bfree, stat.bavail].every(Number.isFinite) || stat.blocks <= 0
          || stat.bfree < 0 || stat.bfree > stat.blocks || stat.bavail < 0 || stat.bavail > stat.bfree) return unreadable('disk-unreadable');
        const used = stat.blocks - stat.bfree;
        const availableTotal = used + stat.bavail;
        if (availableTotal <= 0) return unreadable('disk-unreadable');
        return used * 100 / availableTotal >= c.prag ? failed('disk-full') : green();
      }
      case 'mount': return mounted(await read(() => io.readFile('/proc/self/mountinfo', 'utf8')), c.tinta);
      case 'cmd': {
        let allow;
        try { allow = JSON.parse(env.VIGIL_CMD_ALLOW || '[]'); } catch { return unreadable('cmd-allow'); }
        if (!Array.isArray(allow) || !allow.includes(c.tinta[0])) return unreadable('cmd-denied');
        const result = await run(c.tinta, 10000, commandEnvironment(env));
        if (result.verdict !== 'verde') return answer(result.verdict, 'cmd-execution');
        return result.output.trim() === c.astept.valoare ? green() : failed('cmd-value');
      }
      case 'hass-state': {
        if (!env.HASS_URL || !env.VIGIL_HASS_TOKEN_FILE) return unreadable('hass-config');
        const token = (await read(() => io.readFile(env.VIGIL_HASS_TOKEN_FILE, 'utf8'))).trim();
        if (!token || /[\r\n]/.test(token)) return unreadable('hass-token');
        const base = new URL(env.HASS_URL);
        if (!['http:', 'https:'].includes(base.protocol) || base.username || base.password) return unreadable('hass-config');
        const remaining = 10000 - (performance.now() - started);
        if (remaining <= 0) return unreadable('hass-timeout');
        const response = await get(new URL(`/api/states/${encodeURIComponent(c.tinta)}`, base), {
          headers: { Authorization: `Bearer ${token}` }, timeout: remaining,
        });
        if (response.status !== 200) return unreadable('hass-response');
        let body;
        try { body = JSON.parse(response.body); } catch { return unreadable('hass-response'); }
        if (!body || typeof body.state !== 'string' || !body.state) return unreadable('hass-state');
        if (['unknown', 'unavailable'].includes(body.state)) return failed('hass-unavailable');
        if (c.astept.disponibil === true) return green();
        return body.state === c.astept.valoare ? green() : failed('hass-value');
      }
      case 'crowdsec': return await crowdsecAlerts(c, { env, io, read, get, started });
      case 'osquery': return await osqueryRows(c, { env, io, read, now });
      case 'anomaly': return await anomalyRate(c, { env, get, now, started });
      default: return unreadable('contract-invalid');
    }
  } catch (error) {
    if (['tcp', 'http'].includes(c.verifica) && error.message === 'request-failed') return failed('network-unreachable');
    return unreadable(`${c.verifica === 'hass-state' ? 'hass' : c.verifica}-unreadable`);
  }
}
