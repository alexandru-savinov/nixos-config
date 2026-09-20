import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs/promises';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { check, command, matches, mounted, request } from './lib/checks.mjs';

const now = Date.parse('2026-09-20T12:00:00Z');
const verdict = async (c, options) => (await check(c, options)).verdict;
const response = (status, body) => async () => ({ status, body });

test('file age distinguishes missing, fresh, stale and future timestamps', async () => {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'vigil-check-'));
  try {
    const target = path.join(root, 'fixture');
    const c = { verifica: 'age', tinta: target, prag: '15m' };
    assert.equal(await verdict(c, { now }), 'NECITIT');
    await fs.writeFile(target, 'fixture');
    await fs.utimes(target, new Date(now), new Date(now - 60000));
    assert.equal(await verdict(c, { now }), 'verde');
    assert.equal(await verdict(c, { now: now + 900000 }), 'picat');
    assert.equal(await verdict(c, { now: now - 120000 }), 'NECITIT');
  } finally { await fs.rm(root, { recursive: true, force: true }); }
});

test('HTTP requires exact status, body and valid freshness independently', async () => {
  const c = { verifica: 'http', tinta: 'http://127.0.0.1/', astept: { status: 200, body: '"la"', prospetime: '15m' } };
  const inspect = body => verdict(c, { now, request: response(200, body) });
  assert.equal(await inspect(JSON.stringify({ la: new Date(now - 1000).toISOString() })), 'verde');
  assert.equal(await verdict(c, { now, request: response(301, '{}') }), 'picat');
  assert.equal(await inspect('{}'), 'picat');
  assert.equal(await inspect('{"la":"bad"}'), 'NECITIT');
  assert.equal(await inspect('{"la":"2026-09-20T11:45:00Z"}'), 'picat');
  assert.equal(await inspect('{"la":"2026-09-20T12:01:00Z"}'), 'NECITIT');
});

test('regular expression backtracking has a bounded worker lifetime', async () => {
  assert.equal(await matches('ready', 'ready'), true);
  assert.equal(await matches('ready', 'absent'), false);
  assert.equal(await matches('(a+)+$', 'a'.repeat(10000) + '!'), null);
});

test('systemd unknown unit and unsuccessful last run are unreadable', async () => {
  const unit = { verifica: 'unit', tinta: 'fixture.service' };
  const run = output => async () => ({ verdict: 'verde', output });
  assert.equal(await verdict(unit, { command: run('LoadState=not-found\nActiveState=inactive') }), 'NECITIT');
  assert.equal(await verdict(unit, { command: run('LoadState=loaded\nActiveState=inactive') }), 'picat');
  assert.equal(await verdict(unit, { command: run('LoadState=loaded\nActiveState=active') }), 'verde');
  assert.equal(await verdict(unit, { command: run('LoadState=loaded\nActiveState=garbage') }), 'NECITIT');
  const c = { verifica: 'age', tinta: 'unit:fixture.service', prag: '8d' };
  assert.equal(await verdict(c, { now, command: run('LoadState=loaded\nResult=exit-code\nExecMainExitTimestamp=Sun 2026-09-20 11:00:00 UTC') }), 'NECITIT');
  assert.equal(await verdict(c, { now, command: run('LoadState=loaded\nResult=success\nExecMainExitTimestamp=Sun 2026-09-20 11:00:00 UTC') }), 'verde');
  assert.equal(await verdict(c, { now, command: run('LoadState=loaded\nResult=success\nExecMainExitTimestamp=') }), 'NECITIT');
});

test('mount matching uses a complete decoded mountpoint, never a substring', () => {
  const source = '40 25 0:20 / /dev/shm rw,nosuid - tmpfs tmpfs rw\n41 25 0:21 / /mnt/with\\040space rw - tmpfs tmpfs rw\n';
  assert.equal(mounted(source, '/dev/sh').verdict, 'picat');
  assert.equal(mounted(source, '/dev/shm').verdict, 'verde');
  assert.equal(mounted(source, '/mnt/with space').verdict, 'verde');
  assert.equal(mounted('', '/dev/shm').verdict, 'NECITIT');
});

test('unit timestamps are requested in UTC with a stable locale', async () => {
  const result = await check({ verifica: 'age', tinta: 'unit:fixture.service', prag: '8d' }, {
    now, env: { VIGIL_SYSTEMCTL: '/fixture/systemctl' },
    command: async (argv, timeout, environment) => {
      assert.equal(environment?.TZ, 'UTC');
      assert.equal(environment?.LC_ALL, 'C');
      assert.equal(argv[0], '/fixture/systemctl');
      return { verdict: 'verde', output: 'LoadState=loaded\nResult=success\nExecMainExitTimestamp=Sun 2026-09-20 11:00:00 UTC' };
    },
  });
  assert.equal(result.verdict, 'verde');
});

test('disk threshold includes reserved blocks and rejects invalid counters', async () => {
  const c = { verifica: 'disk', tinta: '/', prag: 85 };
  const inspect = counters => verdict(c, { fs: { statfs: async () => counters } });
  assert.equal(await inspect({ blocks: 100, bfree: 20, bavail: 10 }), 'picat');
  assert.equal(await inspect({ blocks: 100, bfree: 20, bavail: 20 }), 'verde');
  assert.equal(await inspect({ blocks: 0, bfree: 0, bavail: 0 }), 'NECITIT');
  assert.equal(await inspect({ blocks: 100, bfree: 101, bavail: 20 }), 'NECITIT');
});

test('commands require exact allowlist and compare trimmed stdout without a shell', async () => {
  const c = { verifica: 'cmd', tinta: [process.execPath, '-e', 'process.stdout.write("ready\\n")'], astept: { valoare: 'ready' } };
  assert.equal(await verdict(c, { env: {} }), 'NECITIT');
  assert.equal(await verdict(c, { env: { VIGIL_CMD_ALLOW: JSON.stringify([process.execPath]) } }), 'verde');
  assert.equal(await verdict({ ...c, astept: { valoare: 'different' } }, { env: { VIGIL_CMD_ALLOW: JSON.stringify([process.execPath]) } }), 'picat');
  assert.equal((await command(['/nonexistent-vigil-fixture'])).verdict, 'NECITIT');
  assert.equal((await command([process.execPath, '-e', 'process.exit(127)'])).verdict, 'NECITIT');
  assert.equal((await command([process.execPath, '-e', 'process.exit(1)'])).verdict, 'picat');
  assert.equal((await command([process.execPath, '-e', 'setInterval(()=>{},1000)'], 50)).verdict, 'picat');
  assert.equal((await command([process.execPath, '-e', 'process.stdout.write("x".repeat(100000))'])).verdict, 'NECITIT');
});

test('Home Assistant authentication and malformed states never expose private data', async () => {
  const c = { verifica: 'hass-state', tinta: 'sensor.fixture', astept: { valoare: 'ready' } };
  const options = { env: { HASS_URL: 'http://127.0.0.1:8123', VIGIL_HASS_TOKEN_FILE: '/fixture/token' }, fs: { readFile: async () => 'fixture-token\n' } };
  assert.equal(await verdict(c, { env: {} }), 'NECITIT');
  for (const [body, expected] of [['{"state":"ready"}', 'verde'], ['{"state":"unknown"}', 'picat'], ['{"state":"unavailable"}', 'picat'], ['{"state":2}', 'NECITIT'], ['{}', 'NECITIT'], ['invalid', 'NECITIT']]) {
    const result = await check(c, { ...options, request: async (url, config) => {
      assert.equal(url.pathname, '/api/states/sensor.fixture');
      assert.equal(config.headers.Authorization, 'Bearer fixture-token');
      return { status: 200, body };
    } });
    assert.equal(result.verdict, expected);
    assert.doesNotMatch(JSON.stringify(result), /fixture|token|8123/);
  }
  assert.equal(await verdict(c, { ...options, request: response(401, 'private body') }), 'NECITIT');
});

test('command deadline does not wait for inherited descendant output pipes', async () => {
  const script = 'require("node:child_process").spawn(process.execPath,["-e","setTimeout(()=>{},1500)"],{stdio:"inherit"}); setInterval(()=>{},1000);';
  const started = Date.now();
  const result = await command([process.execPath, '-e', script], 80);
  assert.equal(result.verdict, 'picat');
  assert.ok(Date.now() - started < 800, 'the subprocess deadline must not wait for a descendant pipe');
});

test('real TCP/HTTP probes use bounded responses, no redirects, and refused connections fail', async () => {
  let redirected = false;
  const server = http.createServer((req, res) => {
    if (req.url === '/redirect') { res.writeHead(302, { Location: '/destination' }); res.end(); }
    else if (req.url === '/destination') { redirected = true; res.end('redirected'); }
    else if (req.url === '/large') res.end('x'.repeat(70000));
    else if (req.url === '/hang') { /* The client must enforce the deadline. */ }
    else res.end('ready');
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const port = server.address().port;
  const base = `http://127.0.0.1:${port}`;
  try {
    assert.equal(await verdict({ verifica: 'tcp', tinta: `127.0.0.1:${port}` }), 'verde');
    assert.equal((await request(new URL(base))).body, 'ready');
    assert.equal((await request(new URL(`${base}/redirect`))).status, 302);
    assert.equal(redirected, false);
    await assert.rejects(request(new URL(`${base}/large`)), /response/);
    await assert.rejects(request(new URL(`${base}/hang`), { timeout: 25 }), /request-failed/);
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
  assert.equal(await verdict({ verifica: 'tcp', tinta: `127.0.0.1:${port}` }), 'picat');
});
