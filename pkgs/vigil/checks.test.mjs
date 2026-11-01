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

test('stalled filesystem probes release check slots with unreadable verdicts', async () => {
  const stalled = () => new Promise(() => {});
  const io = { stat: stalled, statfs: stalled, readFile: stalled, open: stalled };
  const contracts = [
    { verifica: 'age', tinta: '/fixture', prag: '1h' },
    { verifica: 'disk', tinta: '/', prag: 85 },
    { verifica: 'mount', tinta: '/fixture' },
    { verifica: 'hass-state', tinta: 'sensor.fixture', astept: { valoare: 'ready' } },
    { verifica: 'crowdsec', tinta: 'http://127.0.0.1:1', prag: 1, astept: { scenariu: 'fixture/ssh-bf', fereastra_min: 15 } },
    { verifica: 'osquery', tinta: 'local_users', astept: { permis: [] } },
  ];
  let timer;
  try {
    const results = await Promise.race([
      Promise.all(contracts.map(c => check(c, { fs: io, fsTimeout: 10,
        env: { HASS_URL: 'http://127.0.0.1:8123', VIGIL_HASS_TOKEN_FILE: '/fixture/token', VIGIL_CROWDSEC_CREDENTIALS: '/fixture/crowdsec',
          VIGIL_OSQUERY_RESULTS: '/fixture/snapshots', VIGIL_OSQUERY_INTERVAL: '300' } }))),
      new Promise(resolve => { timer = setTimeout(() => resolve(null), 100); }),
    ]);
    assert.notEqual(results, null, 'filesystem probes must release their slots');
    assert.ok(results.every(result => result.verdict === 'NECITIT'));
  } finally { clearTimeout(timer); }
});

test('aborted HTTP responses release their request deadline', async t => {
  const schedule = globalThis.setTimeout;
  const cancel = globalThis.clearTimeout;
  let deadline;
  let cleared = false;
  t.mock.method(globalThis, 'setTimeout', (fn, ms, ...args) => {
    const timer = schedule(fn, ms, ...args);
    if (ms === 4000) deadline = timer;
    return timer;
  });
  t.mock.method(globalThis, 'clearTimeout', timer => {
    if (timer === deadline) cleared = true;
    return cancel(timer);
  });
  const server = http.createServer((_req, res) => {
    res.writeHead(200);
    res.flushHeaders();
    schedule(() => res.destroy(), 20);
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  try {
    await assert.rejects(request(new URL(`http://127.0.0.1:${server.address().port}`), { timeout: 4000 }), /response-unreadable/);
    assert.ok(deadline);
    assert.equal(cleared, true);
  } finally {
    cancel(deadline);
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
});

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

test('systemd checks use a minimal environment with UTC and a stable locale', async () => {
  for (const c of [{ verifica: 'age', tinta: 'unit:fixture.service', prag: '8d' }, { verifica: 'unit', tinta: 'fixture.service' }]) {
    let inherited;
    const result = await check(c, {
      now, env: { VIGIL_SYSTEMCTL: '/fixture/systemctl', PATH: '/fixture/bin', TELEGRAM_BOT_TOKEN: 'fixture-token' },
      command: async (argv, timeout, environment) => {
        inherited = environment;
        assert.equal(argv[0], '/fixture/systemctl');
        return { verdict: 'verde', output: 'LoadState=loaded\nActiveState=active\nResult=success\nExecMainExitTimestamp=Sun 2026-09-20 11:00:00 UTC' };
      },
    });
    assert.equal(result.verdict, 'verde');
    assert.deepEqual(Object.keys(inherited).sort(), ['LANG', 'LC_ALL', 'PATH', 'TZ']);
    assert.equal(inherited.TZ, 'UTC');
    assert.equal(inherited.LC_ALL, 'C');
  }
});

test('command helper defaults to the same minimal environment', async () => {
  const result = await command([process.execPath, '-e', 'process.stdout.write(Object.keys(process.env).sort().join(","))']);
  assert.equal(result.verdict, 'verde');
  assert.equal(result.output, 'LANG,LC_ALL,PATH,TZ');
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
  assert.equal((await command([process.execPath, '-e', 'setInterval(()=>{},1000)'], 50)).verdict, 'NECITIT');
  assert.equal((await command([process.execPath, '-e', 'process.stdout.write("x".repeat(100000))'])).verdict, 'NECITIT');
});

test('allow-listed commands receive only a minimal environment', async () => {
  const c = { verifica: 'cmd', tinta: ['/fixture/check'], astept: { valoare: 'ready' } };
  let inherited;
  assert.equal(await verdict(c, {
    env: { PATH: '/fixture/bin', VIGIL_CMD_ALLOW: '["/fixture/check"]', TELEGRAM_BOT_TOKEN: 'fixture-token',
      TELEGRAM_CHAT_ID: 'fixture-chat', VIGIL_HASS_TOKEN_FILE: '/fixture/token', OTHER_SECRET: 'fixture-secret' },
    command: async (_argv, _timeout, environment) => { inherited = environment; return { verdict: 'verde', output: 'ready' }; },
  }), 'verde');
  assert.deepEqual(inherited, { PATH: '/fixture/bin', LANG: 'C', LC_ALL: 'C', TZ: 'UTC' });
});

test('Home Assistant token reads share the network check deadline', async t => {
  let clock = 1000;
  t.mock.method(performance, 'now', () => clock);
  let budget;
  const result = await check({ verifica: 'hass-state', tinta: 'sensor.fixture', astept: { valoare: 'ready' } }, {
    env: { HASS_URL: 'http://127.0.0.1:8123', VIGIL_HASS_TOKEN_FILE: '/fixture/token' },
    fs: { readFile: async () => { clock += 4000; return 'fixture-token'; } },
    request: async (_url, options) => { budget = options.timeout; return { status: 200, body: '{"state":"ready"}' }; },
  });
  assert.equal(result.verdict, 'verde');
  assert.equal(budget, 6000);
});

test('Home Assistant disponibil: any real state is verde, unavailable/unknown is picat, never a usage log', async () => {
  const c = { verifica: 'hass-state', tinta: 'sensor.fixture', astept: { disponibil: true } };
  const options = { env: { HASS_URL: 'http://127.0.0.1:8123', VIGIL_HASS_TOKEN_FILE: '/fixture/token' }, fs: { readFile: async () => 'fixture-token\n' } };
  for (const [body, expected, reason] of [
    ['{"state":"docked"}', 'verde', 'ok'], ['{"state":"cleaning"}', 'verde', 'ok'], ['{"state":"returning"}', 'verde', 'ok'],
    ['{"state":"unavailable"}', 'picat', 'hass-unavailable'], ['{"state":"unknown"}', 'picat', 'hass-unavailable'],
    ['{"state":""}', 'NECITIT', 'hass-state'], ['{"state":3}', 'NECITIT', 'hass-state'], ['{}', 'NECITIT', 'hass-state'],
  ]) {
    const result = await check(c, { ...options, request: async () => ({ status: 200, body }) });
    assert.equal(result.verdict, expected, body);
    assert.equal(result.motiv, reason, body);
    assert.doesNotMatch(JSON.stringify(result), /docked|cleaning|returning|fixture|token/);
  }
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
  // The grandchild holds the inherited stdout pipe open for 10s, far longer than the
  // 80ms command() deadline. A correct implementation resolves shortly after the
  // deadline regardless; a broken one (waiting for the pipe to close) would take
  // ~10s. The 5s bound is a wide margin below that 10s ceiling, not a tight
  // wall-clock estimate of the fast path, so it stays stable on loaded CI runners.
  const script = 'require("node:child_process").spawn(process.execPath,["-e","setTimeout(()=>{},10000)"],{stdio:"inherit"}); setInterval(()=>{},1000);';
  const started = Date.now();
  const result = await command([process.execPath, '-e', script], 80);
  const elapsed = Date.now() - started;
  assert.equal(result.verdict, 'NECITIT');
  assert.ok(elapsed < 5000, `the subprocess deadline must not wait for a descendant pipe (took ${elapsed}ms)`);
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
    assert.equal(await verdict({ verifica: 'http', tinta: `${base}/large`, astept: { status: 200 } }), 'verde');
    assert.equal(await verdict({ verifica: 'http', tinta: `${base}/large`, astept: { status: 503 } }), 'picat');
    assert.equal(await verdict({ verifica: 'http', tinta: `${base}/large`, astept: { status: 200, body: 'x' } }), 'NECITIT');
    await assert.rejects(request(new URL(`${base}/hang`), { timeout: 25 }), /request-failed/);
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
  assert.equal(await verdict({ verifica: 'tcp', tinta: `127.0.0.1:${port}` }), 'picat');
});

// A LAPI stand-in over real HTTP, shaped from crowdsec v1.7.2: no alerts is `null`.
async function withCrowdsec(t, handlers) {
  const seen = [];
  const server = http.createServer((req, res) => {
    let body = '';
    req.on('data', chunk => { body += chunk; });
    req.on('end', () => {
      const url = new URL(req.url, 'http://fixture');
      seen.push({ method: req.method, url, headers: req.headers, body });
      if (url.pathname === '/v1/watchers/login') return (handlers.login || login)(req, res, body);
      if (url.pathname === '/v1/alerts') return handlers.alerts(req, res, url);
      res.writeHead(404); res.end();
    });
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  const contract = { verifica: 'crowdsec', tinta: `http://127.0.0.1:${server.address().port}`, prag: 2,
    astept: { scenariu: 'crowdsecurity/ssh-bf', fereastra_min: 15 } };
  return { contract, seen };
}
// v1.7.2 refuses a login whose User-Agent does not split into exactly name/version.
const login = (req, res) => {
  if ((req.headers['user-agent'] || '').split('/').length !== 2) { res.writeHead(401); res.end('{"code":401,"message":"incorrect Username or Password"}'); return; }
  res.writeHead(200); res.end('{"code":200,"expire":"2026-10-31T22:00:00Z","token":"fixture-jwt"}');
};
const send = (status, body) => (_req, res) => { res.writeHead(status); res.end(body); };
const credentials = 'url: http://10.0.0.5:8080/\nlogin: fixture-machine\npassword: fixture-password\nignored: key\n';
const crowdsec = { env: { VIGIL_CROWDSEC_CREDENTIALS: '/fixture/crowdsec' }, fs: { readFile: async () => credentials } };

test('crowdsec counts alerts against prag, and the empty null body is verde', async t => {
  for (const [body, expected, reason] of [
    ['null', 'verde', 'ok'], ['[]', 'verde', 'ok'], ['[{"id":1}]', 'verde', 'ok'],
    ['[{"id":1},{"id":2}]', 'picat', 'crowdsec-alerts'], ['[{"id":1},{"id":2},{"id":3}]', 'picat', 'crowdsec-alerts'],
  ]) {
    const { contract } = await withCrowdsec(t, { alerts: send(200, body) });
    const result = await check(contract, crowdsec);
    assert.deepEqual(result, { verdict: expected, motiv: reason }, body);
  }
});

test('crowdsec logs in with the credential and asks for local alerts in the window', async t => {
  const { contract, seen } = await withCrowdsec(t, { alerts: send(200, 'null') });
  assert.equal(await verdict(contract, crowdsec), 'verde');
  assert.equal(seen.length, 2);
  assert.equal(seen[0].method, 'POST');
  assert.deepEqual(JSON.parse(seen[0].body), { machine_id: 'fixture-machine', password: 'fixture-password' });
  assert.equal(seen[1].method, 'GET');
  assert.equal(seen[1].headers.authorization, 'Bearer fixture-jwt');
  assert.deepEqual(Object.fromEntries(seen[1].url.searchParams), {
    scenario: 'crowdsecurity/ssh-bf', since: '15m', limit: '2', include_capi: 'false' });
});

test('crowdsec reads quoted YAML values as cscli may write them', async t => {
  const { contract, seen } = await withCrowdsec(t, { alerts: send(200, 'null') });
  const fs = { readFile: async () => 'login: "fixture-machine"\r\npassword: \'fixture-password\'\r\n' };
  assert.equal(await verdict(contract, { ...crowdsec, fs }), 'verde');
  assert.deepEqual(JSON.parse(seen[0].body), { machine_id: 'fixture-machine', password: 'fixture-password' });
});

test('crowdsec still decides picat when an attack makes the alert body large', async t => {
  const { contract } = await withCrowdsec(t, { alerts: send(200, JSON.stringify([{ events: 'x'.repeat(70000) }, { id: 2 }])) });
  assert.deepEqual(await check(contract, crowdsec), { verdict: 'picat', motiv: 'crowdsec-alerts' });
});

test('every crowdsec sensor fault is NECITIT with a distinct reason and no private data', async t => {
  const cases = [
    ['login 401', { login: send(401, 'private body'), alerts: send(200, 'null') }, crowdsec, 'crowdsec-auth'],
    ['login garbage', { login: send(200, 'not json'), alerts: send(200, 'null') }, crowdsec, 'crowdsec-auth'],
    ['login tokenless', { login: send(200, '{"code":200}'), alerts: send(200, 'null') }, crowdsec, 'crowdsec-auth'],
    ['alerts 401', { alerts: send(401, 'private body') }, crowdsec, 'crowdsec-auth'],
    ['alerts 500', { alerts: send(500, 'private body') }, crowdsec, 'crowdsec-response'],
    ['garbage body', { alerts: send(200, '<html>') }, crowdsec, 'crowdsec-response'],
    ['empty body', { alerts: send(200, '') }, crowdsec, 'crowdsec-response'],
    ['object body', { alerts: send(200, '{"message":"x"}') }, crowdsec, 'crowdsec-response'],
    ['oversized body', { alerts: send(200, JSON.stringify(['x'.repeat(5 * 1024 * 1024)])) }, crowdsec, 'crowdsec-response'],
    ['no env', { alerts: send(200, 'null') }, { ...crowdsec, env: {} }, 'crowdsec-config'],
    ['no file', { alerts: send(200, 'null') }, { ...crowdsec, fs: { readFile: async () => { throw new Error('/fixture/crowdsec'); } } }, 'crowdsec-config'],
    ['no password', { alerts: send(200, 'null') }, { ...crowdsec, fs: { readFile: async () => 'login: fixture-machine\n' } }, 'crowdsec-config'],
  ];
  for (const [name, handlers, options, reason] of cases) {
    const { contract } = await withCrowdsec(t, handlers);
    const result = await check(contract, options);
    assert.deepEqual(result, { verdict: 'NECITIT', motiv: reason }, name);
    assert.doesNotMatch(JSON.stringify(result), /fixture|private|127\.0\.0\.1/, name);
  }
});

test('a stopped crowdsec is NECITIT, never verde', async t => {
  const { contract } = await withCrowdsec(t, { alerts: send(200, 'null') });
  const dead = await new Promise((resolve, reject) => {
    const probe = http.createServer();
    probe.once('error', reject);
    probe.listen(0, '127.0.0.1', () => { const { port } = probe.address(); probe.close(() => resolve(port)); });
  });
  const result = await check({ ...contract, tinta: `http://127.0.0.1:${dead}` }, crowdsec);
  assert.deepEqual(result, { verdict: 'NECITIT', motiv: 'crowdsec-unreachable' });
});

test('crowdsec shares one 10s budget across credential, login and alerts', async t => {
  let clock = 1000;
  t.mock.method(performance, 'now', () => clock);
  const budgets = [];
  const c = { verifica: 'crowdsec', tinta: 'http://127.0.0.1:8080', prag: 1, astept: { scenariu: 'fixture/ssh-bf', fereastra_min: 15 } };
  const fs = { readFile: async () => { clock += 4000; return credentials; } };
  const result = await check(c, { ...crowdsec, fs, request: async (url, config) => {
    budgets.push(config.timeout);
    clock += 3000;
    return url.pathname === '/v1/watchers/login' ? { status: 200, body: '{"token":"fixture-jwt"}' } : { status: 200, body: 'null' };
  } });
  assert.equal(result.verdict, 'verde');
  assert.deepEqual(budgets, [6000, 3000]);
  clock = 1000;
  const late = await check(c, { ...crowdsec, fs, request: async () => { clock += 7000; return { status: 200, body: '{"token":"fixture-jwt"}' }; } });
  assert.deepEqual(late, { verdict: 'NECITIT', motiv: 'crowdsec-timeout' });
});

test('a hung crowdsec times out as NECITIT while http keeps reading it as a network failure', async t => {
  const { contract } = await withCrowdsec(t, { login: () => {}, alerts: () => {} });
  const short = (url, config) => request(url, { ...config, timeout: 25 });
  assert.deepEqual(await check(contract, { ...crowdsec, request: short }), { verdict: 'NECITIT', motiv: 'crowdsec-timeout' });
  const http = { verifica: 'http', tinta: `${contract.tinta}/v1/alerts`, astept: { status: 200 } };
  assert.deepEqual(await check(http, { request: short }), { verdict: 'picat', motiv: 'network-unreachable' });
});

test('a timeout during a streaming crowdsec body is still a timeout', async t => {
  const { contract } = await withCrowdsec(t, { login: (_req, res) => { res.writeHead(200); res.write('{'); } });
  const short = (url, config) => request(url, { ...config, timeout: 25 });
  assert.deepEqual(await check(contract, { ...crowdsec, request: short }), { verdict: 'NECITIT', motiv: 'crowdsec-timeout' });
});

// Real snapshot log files, shaped from osquery 5.21.0: unixTime is a number of seconds and
// row values are strings; the interval is 300 s, so snapshots go stale past 600 s.
const unix = Math.floor(now / 1000);
const snapshotLine = (query, rows, age = 60) => JSON.stringify({ snapshot: rows, action: 'snapshot',
  name: `pack_vigil_${query}`, hostIdentifier: 'fixture', calendarTime: 'Sun Sep 20 11:59:00 2026 UTC',
  unixTime: unix - age, epoch: 0, counter: 0, numerics: false });
const ports = [{ port: '22', protocol: '6', name: 'sshd' }, { port: '8747', protocol: '6', name: 'systemd' }];
const portContract = { verifica: 'osquery', tinta: 'listening_ports', astept: { permis: ['22/6/sshd', '8747/6/systemd'] } };

async function withSnapshots(t, content) {
  const root = await fs.mkdtemp(path.join(os.tmpdir(), 'vigil-osquery-'));
  t.after(() => fs.rm(root, { recursive: true, force: true }));
  const file = path.join(root, 'osqueryd.snapshots.log');
  if (content !== undefined) await fs.writeFile(file, content);
  return { now, env: { VIGIL_OSQUERY_RESULTS: file, VIGIL_OSQUERY_INTERVAL: '300' } };
}

test('osquery reads verde for allowed rows, for reordered rows and for a quiet event table', async t => {
  const options = await withSnapshots(t, [
    snapshotLine('listening_ports', [...ports].reverse()), snapshotLine('etc_fim', []),
    snapshotLine('local_users', [{ username: 'root' }]), snapshotLine('suid_bins', [{ path: '/run/wrappers/bin/sudo' }]),
  ].join('\n') + '\n');
  assert.deepEqual(await check(portContract, options), { verdict: 'verde', motiv: 'ok' });
  for (const [tinta, permis] of [['etc_fim', []], ['local_users', ['root']], ['suid_bins', ['/run/wrappers/bin/sudo']]]) {
    assert.deepEqual(await check({ verifica: 'osquery', tinta, astept: { permis } }, options), { verdict: 'verde', motiv: 'ok' }, tinta);
  }
});

test('osquery names an unexpected row, keyed per query', async t => {
  const options = await withSnapshots(t, [
    snapshotLine('listening_ports', [...ports, { port: '4444', protocol: '6', name: 'nc' }]),
    snapshotLine('local_users', [{ username: 'mallory' }]), snapshotLine('suid_bins', [{ path: '/tmp/sh' }]),
    snapshotLine('etc_fim', [{ target_path: '/etc/passwd', action: 'UPDATED' }]),
  ].join('\n') + '\n');
  for (const [tinta, permis, detaliu] of [
    ['listening_ports', portContract.astept.permis, ['4444/6/nc']], ['local_users', ['root'], ['mallory']],
    ['suid_bins', [], ['/tmp/sh']], ['etc_fim', [], ['/etc/passwd']],
  ]) {
    assert.deepEqual(await check({ verifica: 'osquery', tinta, astept: { permis } }, options),
      { verdict: 'picat', motiv: 'osquery-unexpected', detaliu }, tinta);
  }
});

test('osquery port wildcards accept any process on that port and nothing else', async t => {
  const c = { verifica: 'osquery', tinta: 'listening_ports', astept: { permis: ['22/6/*', '8747/6/systemd'] } };
  const options = await withSnapshots(t, snapshotLine('listening_ports', [
    { port: '22', protocol: '6', name: '.sshd-wrapped' }, { port: '8747', protocol: '6', name: 'systemd' },
  ]));
  assert.deepEqual(await check(c, options), { verdict: 'verde', motiv: 'ok' });
  for (const [port, protocol] of [['4444', '6'], ['22', '17']]) {
    const other = await withSnapshots(t, snapshotLine('listening_ports', [{ port, protocol, name: 'nc' }]));
    assert.deepEqual(await check(c, other),
      { verdict: 'picat', motiv: 'osquery-unexpected', detaliu: [`${port}/${protocol}/nc`] });
  }
  const users = { verifica: 'osquery', tinta: 'local_users', astept: { permis: ['*'] } };
  const people = await withSnapshots(t, snapshotLine('local_users', [{ username: 'mallory' }]));
  assert.equal((await check(users, people)).verdict, 'picat');
});

test('osquery detail is at most three sorted, deduplicated, capped keys', async t => {
  const rows = ['d', 'b', 'a', 'c', 'a', 'x'.repeat(500)].map(username => ({ username }));
  const options = await withSnapshots(t, `${snapshotLine('local_users', rows)}\n`);
  const c = { verifica: 'osquery', tinta: 'local_users', astept: { permis: ['b'] } };
  assert.deepEqual((await check(c, options)).detaliu, ['a', 'c', 'd']);
  const long = await withSnapshots(t, `${snapshotLine('local_users', [{ username: 'x'.repeat(500) }])}\n`);
  assert.equal((await check(c, long)).detaliu[0].length, 128);
});

test('osquery decides on the newest snapshot of its own query only', async t => {
  const intruded = snapshotLine('listening_ports', [...ports, { port: '4444', protocol: '6', name: 'nc' }], 120);
  const clean = snapshotLine('listening_ports', ports);
  const other = snapshotLine('local_users', [{ username: 'root' }]);
  assert.equal(await verdict(portContract, await withSnapshots(t, `${intruded}\n${clean}\n${other}\n`)), 'verde');
  assert.equal(await verdict(portContract, await withSnapshots(t, `${clean}\n${intruded}\n${other}\n`)), 'picat');
});

test('every osquery sensor fault is NECITIT and never verde', async t => {
  const fresh = snapshotLine('listening_ports', ports);
  const cases = [
    ['stale snapshot', snapshotLine('listening_ports', ports, 601), 'osquery-stale'],
    ['truncated newest line', `${fresh}\n${fresh.slice(0, 40)}`, 'osquery-unreadable'],
    ['garbage line', 'not json\n', 'osquery-unreadable'],
    ['null line', 'null\n', 'osquery-unreadable'],
    ['empty file', '', 'osquery-absent'],
    ['other query only', `${snapshotLine('local_users', [{ username: 'root' }])}\n`, 'osquery-absent'],
    ['differential record', `${JSON.stringify({ name: 'pack_vigil_listening_ports', action: 'added', columns: {}, unixTime: unix - 60 })}\n`, 'osquery-unreadable'],
    ['snapshot not a list', `${JSON.stringify({ name: 'pack_vigil_listening_ports', action: 'snapshot', snapshot: {}, unixTime: unix - 60 })}\n`, 'osquery-unreadable'],
    ['no timestamp', `${JSON.stringify({ name: 'pack_vigil_listening_ports', action: 'snapshot', snapshot: ports })}\n`, 'osquery-unreadable'],
    ['string timestamp', `${snapshotLine('listening_ports', ports).replace(/"unixTime":\d+/, '"unixTime":"never"')}\n`, 'osquery-unreadable'],
    ['future timestamp', `${snapshotLine('listening_ports', ports, -60)}\n`, 'osquery-unreadable'],
    ['row without a key column', `${snapshotLine('listening_ports', [{ port: '22', protocol: '6' }])}\n`, 'osquery-unreadable'],
    ['row that is not an object', `${snapshotLine('listening_ports', [null])}\n`, 'osquery-unreadable'],
    ['blind empty snapshot', `${snapshotLine('listening_ports', [])}\n`, 'osquery-empty'],
  ];
  for (const [name, content, reason] of cases) {
    assert.deepEqual(await check(portContract, await withSnapshots(t, content)), { verdict: 'NECITIT', motiv: reason }, name);
  }
});

test('osquery configuration faults are NECITIT, including a missing file', async t => {
  const options = await withSnapshots(t);
  assert.deepEqual(await check(portContract, options), { verdict: 'NECITIT', motiv: 'osquery-unreadable' });
  const good = await withSnapshots(t, `${snapshotLine('listening_ports', ports)}\n`);
  assert.equal(await verdict(portContract, good), 'verde');
  for (const env of [{}, { VIGIL_OSQUERY_INTERVAL: '300' }, { ...good.env, VIGIL_OSQUERY_INTERVAL: '' }, { ...good.env, VIGIL_OSQUERY_INTERVAL: '0' },
    { ...good.env, VIGIL_OSQUERY_INTERVAL: 'soon' }, { VIGIL_OSQUERY_RESULTS: good.env.VIGIL_OSQUERY_RESULTS }]) {
    assert.deepEqual(await check(portContract, { now, env }), { verdict: 'NECITIT', motiv: 'osquery-config' });
  }
  for (const tinta of ['open_sockets', 'constructor']) {
    assert.deepEqual(await check({ ...portContract, tinta }, good), { verdict: 'NECITIT', motiv: 'osquery-query' }, tinta);
  }
});

test('a corrupt line behind the newest snapshot does not wedge the contract', async t => {
  assert.equal(await verdict(portContract, await withSnapshots(t, `not json\n${snapshotLine('listening_ports', ports)}\n`)), 'verde');
});

test('osquery reads only the bounded file tail and drops the line it cut', async t => {
  const pad = JSON.stringify({ name: 'pack_vigil_local_users', action: 'snapshot', snapshot: [{ username: 'é'.repeat(1024 * 1024) }], unixTime: unix });
  const old = snapshotLine('listening_ports', [...ports, { port: '4444', protocol: '6', name: 'nc' }]);
  const big = await withSnapshots(t, `${old}\n${pad}\n${pad}\n${snapshotLine('listening_ports', ports)}\n`);
  assert.ok((await fs.stat(big.env.VIGIL_OSQUERY_RESULTS)).size > 4 * 1024 * 1024);
  assert.equal(await verdict(portContract, big), 'verde');
  // The cut lands inside the only record: its tail must not be parsed as one.
  const cut = await withSnapshots(t, `${'x'.repeat(5 * 1024 * 1024)}${snapshotLine('listening_ports', ports)}\n`);
  assert.deepEqual(await check(portContract, cut), { verdict: 'NECITIT', motiv: 'osquery-absent' });
  const reads = [];
  const real = await fs.open(big.env.VIGIL_OSQUERY_RESULTS, 'r');
  let closed = false;
  const io = { open: async () => ({ stat: () => real.stat(),
    read: async (...args) => { reads.push(args[2]); return real.read(...args); },
    close: async () => { closed = true; await real.close(); } }) };
  assert.equal(await verdict(portContract, { ...big, fs: io }), 'verde');
  assert.equal(reads.reduce((sum, length) => sum + length, 0), 4 * 1024 * 1024);
  assert.equal(closed, true);
});

// Bodies recorded from a live Netdata 2.8.4 daemon; only the row timestamps are substituted.
const anomalyNow = 1793479454000;
const anomalyStamp = Math.floor(anomalyNow / 1000) - 1;
const cpuRates = (user = 0, system = 0, stamp = anomalyStamp) =>
  `{\n "labels": ["time", "user", "nice", "system"],\n "data": [[${stamp}, ${user}, 0, ${system}]]\n}\n`;
const trainingStatus = (untrained, stamp = anomalyStamp) =>
  `{"labels":["time","untrained","pending-without-model","trained","pending-with-model","silenced"],"data":[[${stamp},${untrained},0,2663,0,0]]}`;
const metricTypes = (variable, stamp = anomalyStamp) =>
  `{"labels":["time","constant","variable"],"data":[[${stamp},1430,${variable}]]}`;
const noMetrics = 'No metrics where matched to query.';

async function withNetdata(t, handlers = {}) {
  const seen = [];
  const replies = {
    chart: send(200, cpuRates()),
    'netdata.ml_training_status': send(200, trainingStatus(10)),
    'netdata.ml_metric_types': send(200, metricTypes(1773)),
    ...handlers,
  };
  const server = http.createServer((req, res) => {
    const url = new URL(req.url, 'http://fixture');
    seen.push(url);
    if (url.pathname !== '/api/v1/data') { res.writeHead(404); return res.end(); }
    return replies[url.searchParams.get('context') ?? 'chart'](req, res);
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  t.after(async () => { server.closeAllConnections(); await new Promise(resolve => server.close(resolve)); });
  const options = { now: anomalyNow, env: { VIGIL_NETDATA_URL: `http://127.0.0.1:${server.address().port}`, VIGIL_ANOMALY_INTERVAL: '300' } };
  return { options, seen };
}
const anomalyContract = { verifica: 'anomaly', tinta: 'system.cpu', prag: 20 };

test('anomaly compares the highest dimension rate against prag', async t => {
  for (const [body, expected, motiv] of [
    [cpuRates(0, 0), 'verde', 'ok'], [cpuRates(19.9, 3), 'verde', 'ok'],
    [cpuRates(20, 0), 'picat', 'anomaly-rate'], [cpuRates(0, 30.7692308), 'picat', 'anomaly-rate'],
  ]) {
    const { options } = await withNetdata(t, { chart: send(200, body) });
    assert.deepEqual(await check(anomalyContract, options), { verdict: expected, motiv });
  }
});

test('anomaly asks for the chart anomaly rate over the tick interval, unaligned', async t => {
  const { options, seen } = await withNetdata(t);
  assert.equal(await verdict(anomalyContract, options), 'verde');
  assert.deepEqual(Object.fromEntries(seen[0].searchParams), { points: '1', format: 'json', chart: 'system.cpu',
    after: '-300', group: 'average', options: 'anomaly-bit,unaligned,all-dimensions' });
});

test('a zero rate is verde only once most variable metrics have a model', async t => {
  for (const [untrained, variable, expected] of [
    [1773, 1773, 'NECITIT'], [887, 1773, 'NECITIT'], [886, 1773, 'verde'], [0, 1773, 'verde'], [0, 0, 'NECITIT'],
  ]) {
    const { options } = await withNetdata(t, { 'netdata.ml_training_status': send(200, trainingStatus(untrained)),
      'netdata.ml_metric_types': send(200, metricTypes(variable)) });
    const result = await check(anomalyContract, options);
    assert.equal(result.verdict, expected, `${untrained}/${variable}`);
    if (expected === 'NECITIT') assert.equal(result.motiv, 'anomaly-untrained');
  }
});

test('pending metrics without a model count as untrained', async t => {
  const pending = '{"labels":["time","untrained","pending-without-model","trained","pending-with-model","silenced"],'
    + `"data":[[${anomalyStamp},0,1000,2663,0,0]]}`;
  const { options } = await withNetdata(t, { 'netdata.ml_training_status': send(200, pending) });
  assert.deepEqual(await check(anomalyContract, options), { verdict: 'NECITIT', motiv: 'anomaly-untrained' });
});

test('a rate above prag is picat even while the host is still training', async t => {
  const { options } = await withNetdata(t, { chart: send(200, cpuRates(55)), 'netdata.ml_training_status': send(200, trainingStatus(1773)) });
  assert.deepEqual(await check(anomalyContract, options), { verdict: 'picat', motiv: 'anomaly-rate' });
});

test('every anomaly sensor fault is NECITIT with a distinct reason', async t => {
  const stale = anomalyStamp - 120;
  for (const [name, handlers, motiv] of [
    ['unknown chart', { chart: send(404, noMetrics) }, 'anomaly-chart'],
    ['chart 500', { chart: send(500, 'private body') }, 'anomaly-response'],
    ['garbage chart', { chart: send(200, '<html>') }, 'anomaly-response'],
    ['no labels', { chart: send(200, '{"data":[]}') }, 'anomaly-response'],
    ['json null', { chart: send(200, 'null') }, 'anomaly-response'],
    ['short row', { chart: send(200, `{"labels":["time","user"],"data":[[${anomalyStamp}]]}`) }, 'anomaly-response'],
    ['bad time', { chart: send(200, '{"labels":["time","user"],"data":[["x",0]]}') }, 'anomaly-response'],
    ['empty window', { chart: send(200, '{"labels":["time","user"],"data":[]}') }, 'anomaly-nodata'],
    ['all null', { chart: send(200, `{"labels":["time","user"],"data":[[${anomalyStamp},null]]}`) }, 'anomaly-nodata'],
    ['stale chart', { chart: send(200, cpuRates(0, 0, stale)) }, 'anomaly-stale'],
    ['stale picat', { chart: send(200, cpuRates(99, 0, stale)) }, 'anomaly-stale'],
    ['ml off', { 'netdata.ml_training_status': send(404, noMetrics) }, 'anomaly-untrained'],
    ['metric types off', { 'netdata.ml_metric_types': send(404, noMetrics) }, 'anomaly-untrained'],
    ['empty status', { 'netdata.ml_training_status': send(200, '{"labels":["time"],"data":[]}') }, 'anomaly-untrained'],
    ['stale status', { 'netdata.ml_training_status': send(200, trainingStatus(0, stale)) }, 'anomaly-stale'],
    ['stale metrics', { 'netdata.ml_metric_types': send(200, metricTypes(1773, stale)) }, 'anomaly-stale'],
    ['renamed counter', { 'netdata.ml_metric_types': send(200, `{"labels":["time","other"],"data":[[${anomalyStamp},1]]}`) }, 'anomaly-response'],
    ['null counter', { 'netdata.ml_training_status': send(200, trainingStatus('null')) }, 'anomaly-response'],
  ]) {
    const { options } = await withNetdata(t, handlers);
    assert.deepEqual(await check(anomalyContract, options), { verdict: 'NECITIT', motiv }, name);
  }
});

test('anomaly configuration and transport faults are NECITIT', async t => {
  const { options } = await withNetdata(t);
  for (const env of [{}, { ...options.env, VIGIL_NETDATA_URL: '' }, { ...options.env, VIGIL_NETDATA_URL: 'not a url' },
    { ...options.env, VIGIL_NETDATA_URL: 'https://127.0.0.1:19999' }, { ...options.env, VIGIL_NETDATA_URL: 'http://user:x@127.0.0.1:19999' },
    { ...options.env, VIGIL_ANOMALY_INTERVAL: '0' }, { ...options.env, VIGIL_ANOMALY_INTERVAL: 'x' }, { VIGIL_NETDATA_URL: options.env.VIGIL_NETDATA_URL }]) {
    assert.deepEqual(await check(anomalyContract, { ...options, env }), { verdict: 'NECITIT', motiv: 'anomaly-config' });
  }
  const down = { ...options, env: { ...options.env, VIGIL_NETDATA_URL: 'http://127.0.0.1:1' } };
  assert.deepEqual(await check(anomalyContract, down), { verdict: 'NECITIT', motiv: 'anomaly-unreachable' });
  const hung = { ...options, request: async () => { throw Object.assign(new Error('request-failed'), { timedOut: true }); } };
  assert.deepEqual(await check(anomalyContract, hung), { verdict: 'NECITIT', motiv: 'anomaly-timeout' });
});

test('anomaly requests share one 10 second budget', async t => {
  const budgets = [];
  const clock = performance.now;
  t.after(() => { performance.now = clock; });
  const { options } = await withNetdata(t);
  let elapsed = 0;
  performance.now = () => elapsed;
  const replies = [cpuRates(), trainingStatus(10), metricTypes(1773)];
  const slow = async (_url, { timeout }) => { budgets.push(timeout); elapsed += 6000; return { status: 200, body: replies[budgets.length - 1] }; };
  assert.deepEqual(await check(anomalyContract, { ...options, request: slow }), { verdict: 'NECITIT', motiv: 'anomaly-timeout' });
  assert.deepEqual(budgets, [10000, 4000]);
});
