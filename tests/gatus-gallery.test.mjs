// Isolated installed-binary acceptance for the evaluated gallery suite.
// Usage: GATUS_BIN=/path/to/gatus node tests/gatus-gallery.test.mjs evaluated-gatus.json
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { once } from 'node:events';
const source = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const suite = source.suites.find(s => s.name === 'Gallery publication');
assert.equal(suite.endpoints.length, 2);
assert.equal(suite.interval, '5m');
assert.equal(suite.timeout, '30s');
for (const e of suite.endpoints) {
  assert.equal(e.client.timeout, '10s');
  assert.equal(e.ui['dont-resolve-failed-conditions'], true);
  assert.equal(e.store, undefined, 'no artifact identifiers in context');
  assert.equal(e.alerts, undefined, 'pilot has no notifications');
}
const sentinel = 'PRIVATE_FIXTURE_ARTIFACT';
const variants = ['healthy', 'empty', 'empty-string', 'missing-file', 'gate-off', 'malformed', 'broken-api', 'broken-page', 'timeout'];
const counts = Object.fromEntries(variants.map(v => [v, [0, 0]]));
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'gatus-gallery-test-'));
const fixture = http.createServer((req, res) => {
  const [, variant, step] = req.url.split('/');
  if (!counts[variant]) { res.writeHead(404); res.end(); return; }
  const i = Number(step); counts[variant][i]++;
  let body = i === 0 ? '<html><img src="placeholder"><script>fetch("/api/latest")</script></html>'
    : JSON.stringify({ file: `${sentinel}.png`, mtime: '2026-09-22T00:00:00Z', server_ts: '2026-09-22T00:00:00Z', gate: true });
  let status = 200;
  if (i === 0 && variant === 'broken-page') body = `<html>${sentinel} Login</html>`;
  if (i === 1) {
    if (variant === 'empty') body = JSON.stringify({ file: null, mtime: null, server_ts: '2026-09-22T00:00:00Z', gate: true });
    if (variant === 'empty-string') body = JSON.stringify({ file: '', mtime: '', server_ts: '2026-09-22T00:00:00Z', gate: true });
    if (variant === 'missing-file') body = JSON.stringify({ mtime: '2026-09-22T00:00:00Z', server_ts: '2026-09-22T00:00:00Z', gate: true });
    if (variant === 'gate-off') body = JSON.stringify({ file: `${sentinel}.png`, mtime: '2026-09-22T00:00:00Z', server_ts: '2026-09-22T00:00:00Z', gate: false });
    if (variant === 'malformed') body = `not-json-${sentinel}`;
    if (variant === 'broken-api') status = 503;
  }
  const reply = () => { res.writeHead(status, { 'content-type': i === 0 ? 'text/html' : 'application/json' }); res.end(body); };
  if (variant === 'timeout' && i === 1) setTimeout(reply, 400); else reply();
});
await new Promise(r => fixture.listen(0, '127.0.0.1', r));
const reserve = http.createServer();
await new Promise(r => reserve.listen(0, '127.0.0.1', r));
const port = reserve.address().port;
await new Promise(r => reserve.close(r));
const config = { web: { address: '127.0.0.1', port },
  storage: { type: 'sqlite', path: path.join(directory, 'history.db'), caching: false },
  suites: variants.map(variant => ({ ...suite, name: variant, group: `fixture-${variant}`, interval: '1h',
    endpoints: suite.endpoints.map((e, i) => ({ ...e,
      url: `http://127.0.0.1:${fixture.address().port}/${variant}/${i}`,
      client: { timeout: '100ms' },
    })),
  })),
};
const file = path.join(directory, 'config.json');
fs.writeFileSync(file, JSON.stringify(config));
let output = '', child, spawnError;
const start = () => {
  spawnError = undefined;
  child = spawn(process.env.GATUS_BIN || 'gatus', [], { cwd: directory,
    env: { PATH: process.env.PATH, GATUS_CONFIG_PATH: file, GATUS_LOG_LEVEL: 'WARN' },
    stdio: ['ignore', 'pipe', 'pipe'] });
  child.on('error', e => { spawnError = e; });
  child.stdout.on('data', d => { output += d; }); child.stderr.on('data', d => { output += d; });
};
const stop = async () => { if (child?.pid && child.exitCode === null) { child.kill('SIGTERM'); await once(child, 'exit'); } };
const wait = async predicate => {
  const deadline = Date.now() + 45000;
  while (Date.now() < deadline) {
    assert.ifError(spawnError);
    assert.equal(child.exitCode, null, `isolated Gatus exited: ${output.replaceAll(sentinel, '[redacted fixture]')}`);
    try {
      const r = await fetch(`http://127.0.0.1:${port}/api/v1/suites/statuses`);
      const values = await r.json();
      assert.equal(JSON.stringify(values).includes(sentinel), false, 'artifact identifier leaked');
      if (predicate(values)) return values;
    } catch (e) { if (e.code === 'ERR_ASSERTION') throw e; }
    await new Promise(r => setTimeout(r, 100));
  }
  throw new Error('isolated suite observation timed out');
};
const latest = s => [...s.results].sort((a, b) => Date.parse(b.timestamp) - Date.parse(a.timestamp))[0];
try {
  start();
  const values = await wait(v => v.length === variants.length && v.every(s => s.results?.length));
  for (const s of values) assert.equal(latest(s).success, s.name === 'healthy', `${s.name} verdict`);
  assert.equal(counts['broken-page'][1], 0, 'failed page must skip API step');
  for (const v of variants.filter(v => v !== 'broken-page')) assert.ok(counts[v][1] > 0);
  assert.equal(latest(values.find(s => s.name === 'broken-api')).endpointResults[1].success, false);
  // A config reload must replace conditions and publish the new failed result.
  config.suites[0].interval = '200ms';
  config.suites[0].endpoints[0].conditions = ['[STATUS] == 201'];
  fs.writeFileSync(file, JSON.stringify(config));
  const reloaded = await wait(v => v.find(s => s.name === 'healthy')?.results?.length && latest(v.find(s => s.name === 'healthy')).success === false);
  const prior = reloaded.find(s => s.name === 'healthy').results.map(r => r.timestamp);
  await stop(); start();
  await wait(v => prior.some(t => v.find(s => s.name === 'healthy')?.results?.some(r => r.timestamp === t)));
  assert.equal(output.includes(sentinel), false, 'artifact identifier leaked into logs');
  console.log('PASS: 9 gallery scenarios; empty gallery rejected, failed-step skipping, timeout, artifact privacy, config reload, SQLite history across restart');
} finally {
  await stop(); fixture.closeAllConnections(); await new Promise(r => fixture.close(r));
  fs.rmSync(directory, { recursive: true, force: true });
}
