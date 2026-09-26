// Exercise evaluated production assertions with the installed Gatus binary.
// Usage: GATUS_BIN=/path/to/gatus node tests/gatus-native.test.mjs evaluated-gatus.json
// Only loopback fixtures are contacted. No production credentials are loaded.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { spawn } from 'node:child_process';
import { once } from 'node:events';

const config = JSON.parse(fs.readFileSync(process.argv[2], 'utf8'));
const sentinel = 'PRIVATE_FIXTURE_MUST_NOT_APPEAR';
const profiles = {
  'n8n': { good: '{"status":"ok"}', bad: `{"status":"${sentinel}"}` },
  'n8n readiness': { good: '{"status":"ok"}', bad: `{"status":"${sentinel}"}` },
  'Home Assistant': { good: '{"message":"API running."}', bad: `{"message":"${sentinel}"}` },
  'Home Assistant HTTPS': { good: '{"name":"Home Assistant"}', bad: `{"name":"${sentinel}"}` },
  'Anki Workflow': { good: '<html><title>Image to Anki Deck</title><input type="file" id="fileInput"></html>', bad: `<html>${sentinel}<title>Login</title></html>` },
  'NixFrame Upload': { good: '<html><title>NixFrame Upload</title><input type="file" id="fileInput"></html>', bad: `<html>${sentinel}<title>Login</title></html>` },
  'OpenRouter API': { good: '{"data":[{"id":"fixture-model"}]}', bad: `{"error":"${sentinel}"}` },
};
const cases = [];
for (const [name, profile] of Object.entries(profiles)) {
  const endpoint = config.endpoints.find(e => e.name === name);
  assert.ok(endpoint, `missing endpoint: ${name}`);
  assert.equal(endpoint.ui?.['dont-resolve-failed-conditions'], true);
  assert.equal(endpoint.alerts, undefined, 'native coverage must not add alerts');
  for (const variant of ['good', 'bad', 'missing', 'malformed', 'http-error', 'timeout']) {
    cases.push({ endpoint, name: `fixture-${cases.length}`, variant,
      status: variant === 'http-error' ? 503 : 200,
      body: variant === 'missing' ? '{}' : variant === 'malformed' ? `not-json-${sentinel}` : variant === 'bad' ? profile.bad : profile.good,
      expected: variant === 'good' });
  }
}
const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'gatus-native-test-'));
const server = http.createServer((req, res) => {
  const item = cases[Number(req.url.slice(1))];
  if (!item) { res.writeHead(404); res.end(); return; }
  const reply = () => { res.writeHead(item.status, { 'content-type': 'text/plain' }); res.end(item.body); };
  if (item.variant === 'timeout') setTimeout(reply, 400); else reply();
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const reservation = http.createServer();
await new Promise(resolve => reservation.listen(0, '127.0.0.1', resolve));
const port = reservation.address().port;
await new Promise(resolve => reservation.close(resolve));
const endpoints = cases.map((item, i) => ({ ...item.endpoint, name: item.name, group: 'fixture',
  url: `http://127.0.0.1:${server.address().port}/${i}`, interval: '1h',
  headers: { Authorization: `Bearer ${sentinel}` }, client: { timeout: '100ms' },
}));
fs.writeFileSync(path.join(directory, 'config.json'), JSON.stringify({
  web: { address: '127.0.0.1', port }, storage: { type: 'memory' }, endpoints,
}));
let output = '';
let child;
try {
  child = spawn(process.env.GATUS_BIN || 'gatus', [], {
    cwd: directory, env: { PATH: process.env.PATH,
      GATUS_CONFIG_PATH: path.join(directory, 'config.json'), GATUS_LOG_LEVEL: 'WARN' },
    stdio: ['ignore', 'pipe', 'pipe'],
  });
  let spawnError;
  child.on('error', error => { spawnError = error; });
  child.stdout.on('data', data => { output += data; });
  child.stderr.on('data', data => { output += data; });
  let statuses;
  const deadline = Date.now() + 45000;
  while (Date.now() < deadline) {
    assert.ifError(spawnError);
    assert.equal(child.exitCode, null, 'isolated Gatus exited unexpectedly');
    try {
      const response = await fetch(`http://127.0.0.1:${port}/api/v1/endpoints/statuses`);
      statuses = await response.json();
      if (statuses.length === cases.length && statuses.every(s => s.results?.length)) break;
    } catch { /* Wait for the isolated listener and first evaluation. */ }
    await new Promise(resolve => setTimeout(resolve, 100));
  }
  assert.equal(statuses?.length, cases.length, 'all fixture endpoints must appear');
  for (const item of cases) {
    const result = statuses.find(s => s.name === item.name)?.results?.at(-1);
    assert.ok(result, `no result for ${item.endpoint.name}/${item.variant}`);
    assert.equal(result.success, item.expected, `${item.endpoint.name}/${item.variant}`);
  }
  assert.equal(JSON.stringify(statuses).includes(sentinel), false, 'response or credential leaked into API/history');
  assert.equal(output.includes(sentinel), false, 'response or credential leaked into logs');
  console.log(`PASS: ${cases.length} installed-Gatus cases; healthy, misleading 200, missing field, malformed body, HTTP failure, timeout, and diagnostic privacy`);
} finally {
  if (child?.pid && child.exitCode === null) { child.kill('SIGTERM'); await once(child, 'exit'); }
  server.closeAllConnections();
  await new Promise(resolve => server.close(resolve));
  fs.rmSync(directory, { recursive: true, force: true });
}
