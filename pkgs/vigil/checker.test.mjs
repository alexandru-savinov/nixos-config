import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import os from 'node:os';
import { spawnSync } from 'node:child_process';
import http from 'node:http';
import { run, loadContracts } from './vigil-check.mjs';
import { contract as contractFromToml } from './lib/schema.mjs';
import { say } from './vigil-say.mjs';
import { loadStore } from './lib/store.mjs';
import { failed } from './vigil.mjs';

const base = { nume: 'fixture', verifica: 'age', tinta: '/fixture', prag: '1h', picat_dupa: 2, nivel: 'incident' };

test('CLI inventory and usage faults exit 3 without advancing evidence', () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vigil-cli-'));
  try {
    const directory = path.join(root, 'contracts');
    fs.mkdirSync(directory);
    const fixture = '[contract]\nnume="fixture"\nce="fixture"\nverifica="unit"\ntinta="fixture.service"\npicat_dupa=2\n[spune]\nnivel="nota"\n';
    fs.writeFileSync(path.join(directory, 'one.toml'), fixture);
    fs.writeFileSync(path.join(directory, 'two.toml'), fixture);
    const state = path.join(root, 'state');
    fs.mkdirSync(state);
    fs.writeFileSync(path.join(state, 'tick'), 'previous evidence');
    for (const args of [
      [directory, '--expect', 'invalid'],
      [directory, '--expect', '2'], // Duplicate names.
      [directory, path.join(root, 'missing'), '--expect', '3'],
      [path.join(directory, 'one.toml'), '--expect', '1'], // Not a directory.
    ]) {
      const result = spawnSync(process.execPath, [new URL('./vigil-check.mjs', import.meta.url).pathname, ...args], {
        env: { ...process.env, STATE_DIRECTORY: state, VIGIL_SAY: '0' }, encoding: 'utf8', timeout: 5000,
      });
      assert.equal(result.status, 3);
      assert.equal(result.stdout, '');
      assert.equal(result.stderr, 'vigil-check: internal-fault\n');
      assert.deepEqual(fs.readdirSync(state), ['tick']);
      assert.equal(fs.readFileSync(path.join(state, 'tick'), 'utf8'), 'previous evidence');
    }
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
async function harness(fn) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vigil-run-'));
  let now = Date.parse('2026-09-20T12:00:00Z');
  let available = true;
  const sent = [];
  const lines = [];
  const env = { STATE_DIRECTORY: root, INVOCATION_ID: 'fixture-run', VIGIL_SAY: '1' };
  const options = { env, gazda: 'fixture-host', clock: () => now, probe: async () => 0,
    output: line => lines.push(JSON.parse(line)), summary: () => {},
    deliver: async event => say(event, { env, now, send: async () => {
      if (!available) return false;
      sent.push(event);
      return true;
    } }),
  };
  const tick = (verdicts, overrides = {}) => run(Object.keys(verdicts).map(nume => ({ contract: { ...base, nume } })), {
    ...options, inspect: async c => ({ verdict: verdicts[c.nume], motiv: 'fixture' }), ...overrides,
  });
  try { await fn({ root, env, options, sent, lines, tick,
    time: milliseconds => { now += milliseconds; }, network: value => { available = value; },
    state: () => loadStore(root),
  }); } finally { fs.rmSync(root, { recursive: true, force: true }); }
}

test('the runner hands checks a live clock: a peer tick written mid-fetch is fresh, one that ages past the limit mid-fetch is stale', async () => harness(async h => {
  let la;
  let delay;
  const server = http.createServer((_req, res) => {
    h.time(delay);
    res.writeHead(200, { 'content-type': 'application/json' });
    res.end(JSON.stringify({ la }));
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  try {
    const start = h.options.clock();
    const contract = { ...base, nume: 'peer-tick', verifica: 'http', tinta: `http://127.0.0.1:${server.address().port}/`,
      astept: { status: 200, prospetime: '15m' } };
    la = new Date(start + 400).toISOString(); delay = 800;
    await run([{ contract }], h.options);
    const second = h.options.clock();
    la = new Date(second - 900000 + 500).toISOString(); delay = 1000;
    await run([{ contract }], h.options);
    assert.deepEqual(h.lines.map(line => [line.verdict, line.motiv]), [['verde', 'ok'], ['picat', 'http-stale']]);
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
  }
}));

test('borrowed vocabulary labels reach the run line only when declared', async () => harness(async h => {
  await run([
    { contract: { ...base, nume: 'labelled', dimension: 'availability', driver: 'family' } },
    { contract: { ...base, nume: 'plain' } },
  ], { ...h.options, inspect: async () => ({ verdict: 'picat', motiv: 'fixture' }) });
  assert.equal(h.lines.length, 2);
  assert.equal(h.lines[0].dimension, 'availability');
  assert.equal(h.lines[0].driver, 'family');
  assert.equal(Object.hasOwn(h.lines[1], 'dimension'), false);
  assert.equal(Object.hasOwn(h.lines[1], 'driver'), false);
}));

test('runtime accounts for symlinks and invalid files without exposing input', async () => harness(async h => {
  const directory = path.join(h.root, 'contracts');
  fs.mkdirSync(directory);
  fs.writeFileSync(path.join(h.root, 'target'), '[contract]\nnume="fixture"\nce="fixture"\nverifica="age"\ntinta="/fixture"\nprag="1h"\npicat_dupa=2\n[spune]\nnivel="incident"\n');
  fs.symlinkSync(path.join(h.root, 'target'), path.join(directory, 'valid.toml'));
  fs.writeFileSync(path.join(directory, 'broken.toml'), 'private invalid content');
  const entries = loadContracts([directory]);
  assert.equal(entries.length, 2);
  assert.match(entries[0].contract.nume, /^invalid-[0-9a-f]{16}$/);
  assert.equal(await run(entries, { ...h.options, expect: 2, inspect: async () => ({ verdict: 'verde', motiv: 'ok' }) }), 2);
  assert.equal(h.lines.length, 2);
  assert.equal(h.lines[0].motiv, 'contract-invalid');
  assert.doesNotMatch(JSON.stringify(h.lines), /private|broken|target/);
  await assert.rejects(run(entries, { ...h.options, expect: 1 }), /contract-count/);
  await assert.rejects(run([entries[1], entries[1]], h.options), /duplicate-name/);
}));

test('zero contracts and corrupt global state cannot report success', async () => harness(async h => {
  assert.equal(await run([], h.options), 2);
  const file = path.join(h.root, 'incidents.json');
  fs.writeFileSync(file, 'broken-state');
  await assert.rejects(h.tick({ fixture: 'verde' }), /state-unreadable/);
  assert.equal(fs.readFileSync(file, 'utf8'), 'broken-state');
}));

test('non-regular acknowledgements cannot stop monitoring or follow symlinks', async () => harness(async h => {
  fs.mkdirSync(path.join(h.root, 'ack', 'fixture'), { recursive: true });
  assert.equal(await h.tick({ fixture: 'verde', other: 'verde' }), 0);
  fs.rmdirSync(path.join(h.root, 'ack', 'fixture'));
  const target = path.join(h.root, 'untouched');
  fs.writeFileSync(target, 'keep');
  fs.symlinkSync(target, path.join(h.root, 'ack', 'fixture'));
  assert.equal(await h.tick({ fixture: 'verde', other: 'verde' }), 0);
  assert.equal(fs.readFileSync(target, 'utf8'), 'keep');
  assert.equal(fs.lstatSync(path.join(h.root, 'ack', 'fixture')).isSymbolicLink(), true);
}));

test('recovery contract reports the plan-2 diagnostic while other checks continue', async () => harness(async h => {
  const directory = path.join(h.root, 'contracts');
  fs.mkdirSync(directory);
  fs.writeFileSync(path.join(directory, 'recovery.toml'), '[contract]\nnume="fixture"\nce="fixture"\nverifica="age"\ntinta="/fixture"\nprag="1h"\npicat_dupa=2\n[spune]\nnivel="incident"\n[recuperare]\n');
  const entries = [...loadContracts([directory]), { contract: { ...base, nume: 'other' } }];
  assert.equal(await run(entries, { ...h.options, inspect: async () => ({ verdict: 'verde', motiv: 'ok' }) }), 2);
  assert.equal(h.lines[0].verdict, 'NECITIT');
  assert.equal(h.lines[0].motiv, 'recuperare: plan 2');
  assert.equal(h.lines[1].verdict, 'verde');
}));

test('failed FIFO head prevents close overtaking open across a 30-hour outage', async () => harness(async h => {
  h.network(false);
  assert.equal(await h.tick({ fixture: 'picat' }), 1);
  await h.tick({ fixture: 'picat' });
  assert.equal(h.state().queue[0].tranzitie, 'open');
  h.time(30 * 3600000);
  await h.tick({ fixture: 'picat' });
  assert.equal(h.state().queue.length, 1);
  await h.tick({ fixture: 'verde' });
  h.time(30 * 60000);
  await h.tick({ fixture: 'verde' });
  assert.deepEqual(h.state().queue.map(event => event.tranzitie), ['open', 'close']);
  h.network(true);
  await h.tick({ fixture: 'verde' });
  assert.deepEqual(h.sent.map(event => event.tranzitie), ['open', 'close']);
  assert.equal(h.state().queue.length, 0);
  assert.deepEqual(fs.readdirSync(path.join(h.root, 'outbox')), []);
}));

test('ended undelivered episodes expire together without an orphan close', async () => harness(async h => {
  h.network(false);
  await h.tick({ fixture: 'picat' });
  await h.tick({ fixture: 'picat' });
  await h.tick({ fixture: 'verde' });
  h.time(30 * 60000);
  await h.tick({ fixture: 'verde' });
  h.time(25 * 3600000);
  h.network(true);
  await h.tick({ fixture: 'verde' });
  assert.equal(h.state().queue.length, 0);
  assert.equal(h.sent.length, 0);
}));

test('ack re-arms exactly one nota, clears marker, and retired nota never replays', async () => harness(async h => {
  await h.tick({ fixture: 'NECITIT' });
  await h.tick({ fixture: 'NECITIT' });
  await h.tick({ fixture: 'NECITIT' });
  assert.equal(h.sent.length, 1);
  fs.mkdirSync(path.join(h.root, 'ack'));
  fs.writeFileSync(path.join(h.root, 'ack', 'fixture'), '');
  await h.tick({ fixture: 'NECITIT' });
  assert.equal(fs.existsSync(path.join(h.root, 'ack', 'fixture')), false);
  assert.equal(fs.existsSync(path.join(h.root, 'nota-sent', 'fixture')), false);
  h.time(1000);
  await h.tick({ fixture: 'NECITIT' });
  assert.equal(h.sent.length, 2);
  await h.tick({ fixture: 'verde' });
  assert.equal(fs.existsSync(path.join(h.root, 'nota-sent', 'fixture')), false);
  h.network(false);
  await h.tick({ fixture: 'NECITIT' });
  await h.tick({ fixture: 'NECITIT' });
  assert.equal(h.state().queue.length, 1);
  await h.tick({ fixture: 'verde' });
  h.network(true);
  await h.tick({ fixture: 'verde' });
  assert.equal(h.sent.length, 2);
}));

test('aggregate remains failing while another incident is open', async () => harness(async h => {
  await h.tick({ first: 'picat', second: 'picat' });
  await h.tick({ first: 'picat', second: 'picat' });
  await h.tick({ first: 'verde', second: 'picat' });
  h.time(30 * 60000);
  await h.tick({ first: 'verde', second: 'picat' });
  assert.equal(JSON.parse(fs.readFileSync(path.join(h.root, 'row.json'))).stare, 'picat');
  assert.equal(h.state().contracts.first.open, null);
  assert.notEqual(h.state().contracts.second.open, null);
}));

test('disabled delivery warns for incident or channel contracts while preserving row-only checks', async () => harness(async h => {
  const messages = [];
  for (const [nume, nivel, warning] of [['fixture', 'incident', true], ['channel', 'nota', true], ['fixture', 'nota', false]]) {
    messages.length = 0;
    assert.equal(await run([{ contract: { ...base, nume, nivel } }], {
      ...h.options, env: { ...h.env, VIGIL_SAY: '0' }, summary: line => messages.push(line),
      inspect: async () => ({ verdict: 'picat', motiv: 'fixture' }),
    }), 1);
    assert.equal(messages.includes('vigil-check: WARNING delivery-disabled for incident/channel contracts'), warning);
    assert.equal(h.sent.length, 0);
    assert.equal(h.state().queue.length, 0);
  }
}));

test('enabling delivery as row-only incident closes still delivers open before close', async () => harness(async h => {
  h.env.VIGIL_SAY = '0';
  await h.tick({ fixture: 'picat' });
  await h.tick({ fixture: 'picat' });
  assert.equal(h.sent.length, 0);
  assert.equal(h.state().queue.length, 0);
  assert.equal(fs.existsSync(path.join(h.root, 'outbox')), false);
  await h.tick({ fixture: 'verde' });
  h.time(30 * 60000);
  h.env.VIGIL_SAY = '1';
  await h.tick({ fixture: 'verde' });
  assert.deepEqual(h.sent.map(event => event.tranzitie), ['open', 'close']);
}));

test('unreadable contract identities preserve incidents and interrupt recovery until repair', async () => harness(async h => {
  h.network(false);
  await h.tick({ fixture: 'picat' });
  await h.tick({ fixture: 'picat' });
  const episode = h.state().contracts.fixture.open;
  await h.tick({ fixture: 'verde' });
  h.time(30 * 60000);
  const directory = path.join(h.root, 'contracts');
  fs.mkdirSync(directory);
  fs.writeFileSync(path.join(directory, 'fixture.toml'), 'unreadable fixture');
  assert.equal(await run(loadContracts([directory]), h.options), 2);
  assert.equal(h.state().contracts.fixture?.open, episode);
  assert.equal(h.state().contracts.fixture.greenSince, null);
  h.network(true);
  await h.tick({ fixture: 'verde' });
  assert.deepEqual(h.sent.map(event => [event.tranzitie, event.incident_id]), [['open', episode]]);
  assert.equal(h.state().contracts.fixture.open, episode);
  h.time(30 * 60000);
  await h.tick({ fixture: 'verde' });
  assert.deepEqual(h.sent.map(event => [event.tranzitie, event.incident_id]), [['open', episode], ['close', episode]]);
}));

test('repairing one invalid file retires its nota while another identity remains unreadable', async () => harness(async h => {
  h.network(false);
  const directory = path.join(h.root, 'contracts');
  fs.mkdirSync(directory);
  fs.writeFileSync(path.join(directory, 'a.toml'), 'invalid fixture');
  fs.writeFileSync(path.join(directory, 'b.toml'), 'invalid fixture');
  const entries = loadContracts([directory]);
  const repaired = entries[0].contract.nume;
  await run(entries, h.options);
  await run(entries, h.options);
  assert.equal(h.state().queue.length, 2);
  fs.writeFileSync(path.join(directory, 'a.toml'), '[contract]\nnume="fixture"\nce="fixture"\nverifica="unit"\ntinta="fixture.service"\npicat_dupa=2\n[spune]\nnivel="nota"\n');
  await run(loadContracts([directory]), { ...h.options, inspect: async () => ({ verdict: 'verde', motiv: 'ok' }) });
  assert.equal(Object.hasOwn(h.state().contracts, repaired), false);
  assert.deepEqual(h.state().queue.map(event => event.nume), [entries[1].contract.nume]);
}));

test('row persistence faults retain committed alerts and stale evidence until repair', async () => harness(async h => {
  await h.tick({ fixture: 'picat', other: 'picat' });
  const counts = fs.readFileSync(path.join(h.root, 'tick.counts.json'), 'utf8');
  fs.mkdirSync(path.join(h.root, 'rows'), { recursive: true });
  const row = path.join(h.root, 'rows', 'fixture.json');
  fs.writeFileSync(row, 'corrupt-row');
  h.time(1000);
  await assert.rejects(h.tick({ fixture: 'picat', other: 'picat' }), /state-unreadable/);
  assert.equal(h.lines.length, 4); // Both contracts were inspected on both runs.
  assert.equal(fs.readFileSync(path.join(h.root, 'tick.counts.json'), 'utf8'), counts);
  assert.equal(fs.readFileSync(row, 'utf8'), 'corrupt-row');
  assert.deepEqual(h.state().queue.map(event => event.nume), ['fixture', 'other']);
  assert.equal(h.sent.length, 0);
  let selfAlerts = 0;
  assert.equal(await failed({ env: h.env, gazda: 'fixture-host', send: async () => { selfAlerts++; return true; } }), 0);
  assert.equal(selfAlerts, 1);
  fs.unlinkSync(row);
  await h.tick({ fixture: 'picat', other: 'picat' });
  assert.deepEqual(h.sent.map(event => event.nume), ['fixture', 'other']);
  assert.equal(h.state().queue.length, 0);
}));

test('restart after transition commit delivers its durable event', async () => harness(async h => {
  await h.tick({ fixture: 'picat' });
  await assert.rejects(h.tick({ fixture: 'picat' }, { boundary: stage => {
    if (stage === 'transitions-committed') throw new Error('simulated-kill');
  } }), /simulated-kill/);
  assert.equal(h.sent.length, 0);
  assert.equal(h.state().queue.length, 1);
  await h.tick({ fixture: 'picat' });
  assert.deepEqual(h.sent.map(event => event.tranzitie), ['open']);
}));

test('enabling delivery sends a still-active unreadable nota exactly once', async () => harness(async h => {
  h.env.VIGIL_SAY = '0';
  await h.tick({ fixture: 'NECITIT' });
  await h.tick({ fixture: 'NECITIT' });
  assert.equal(h.sent.length, 0);
  h.env.VIGIL_SAY = '1';
  await h.tick({ fixture: 'NECITIT' });
  await h.tick({ fixture: 'NECITIT' });
  assert.deepEqual(h.sent.map(event => event.tranzitie), ['nota']);
}));

test('valid contract names do not inherit JavaScript object properties', async () => harness(async h => {
  await h.tick({ constructor: 'verde' });
  await h.tick({ constructor: 'verde' });
  assert.equal(h.state().contracts.constructor.open, null);
}));

test('self failure suppresses repeats, survives corrupt global state and rearms after a completed run', async () => harness(async h => {
  let messages = 0;
  const options = { env: h.env, gazda: 'fixture-host', send: async () => { messages++; return true; } };
  fs.writeFileSync(path.join(h.root, 'incidents.json'), 'broken');
  assert.equal(await failed(options), 0);
  assert.equal(await failed(options), 0);
  assert.equal(messages, 1);
  assert.equal(fs.readFileSync(path.join(h.root, 'incidents.json'), 'utf8'), 'broken');
  fs.unlinkSync(path.join(h.root, 'incidents.json'));
  await h.tick({ fixture: 'verde' });
  assert.equal(fs.existsSync(path.join(h.root, 'nota-sent', 'vigil')), false);
  assert.equal(await failed(options), 0);
  assert.equal(messages, 2);
}));

test('a failed counts commit cannot rearm the self-failure notification', async () => harness(async h => {
  await failed({ env: h.env, gazda: 'fixture-host', send: async () => true });
  fs.mkdirSync(path.join(h.root, 'tick.counts.json'));
  await assert.rejects(h.tick({ fixture: 'verde' }));
  assert.equal(fs.existsSync(path.join(h.root, 'nota-sent', 'vigil')), true);
}));

test('checks finish before queued delivery and concurrency never exceeds four', async () => harness(async h => {
  let active = 0;
  let maximum = 0;
  let finished = 0;
  const entries = Array.from({ length: 9 }, (_, index) => ({ contract: { ...base, nume: `fixture-${index}`, picat_dupa: 1 } }));
  assert.equal(await run(entries, { ...h.options,
    inspect: async () => {
      active++;
      maximum = Math.max(maximum, active);
      await new Promise(resolve => setTimeout(resolve, 5));
      active--;
      finished++;
      return { verdict: 'picat', motiv: 'fixture' };
    },
    deliver: async () => { assert.equal(finished, entries.length); return 0; },
  }), 1);
  assert.equal(maximum, 4);
}));

test('ack cleanup survives restart after the state commit', async () => harness(async h => {
  await h.tick({ fixture: 'NECITIT' });
  await h.tick({ fixture: 'NECITIT' });
  fs.mkdirSync(path.join(h.root, 'ack'));
  fs.writeFileSync(path.join(h.root, 'ack', 'fixture'), '');
  await assert.rejects(h.tick({ fixture: 'NECITIT' }, { boundary: stage => {
    if (stage === 'transitions-committed') throw new Error('simulated-kill');
  } }), /simulated-kill/);
  assert.equal(h.state().cleanup.length, 1);
  h.time(1000);
  await h.tick({ fixture: 'NECITIT' });
  assert.equal(h.sent.length, 2);
  assert.equal(fs.existsSync(path.join(h.root, 'ack', 'fixture')), false);
  assert.equal(h.state().cleanup.length, 0);
}));

test('ambiguous send restarts are at-least-once and retain FIFO ordering', async () => harness(async h => {
  await h.tick({ fixture: 'picat' });
  await assert.rejects(h.tick({ fixture: 'picat' }, { boundary: stage => {
    if (stage === 'delivered') throw new Error('simulated-kill');
  } }), /simulated-kill/);
  assert.equal(h.sent.length, 1);
  assert.equal(h.state().queue.length, 1);
  await h.tick({ fixture: 'picat' });
  assert.equal(h.sent.length, 2);
  assert.equal(h.sent[0].event_id, h.sent[1].event_id);
  assert.equal(h.state().queue.length, 0);
}));

test('restart after delivery commit repairs stale outbox without replaying success', async () => harness(async h => {
  await h.tick({ fixture: 'picat' });
  await assert.rejects(h.tick({ fixture: 'picat' }, { boundary: stage => {
    if (stage === 'delivery-committed') throw new Error('simulated-kill');
  } }), /simulated-kill/);
  assert.equal(h.sent.length, 1);
  assert.equal(h.state().queue.length, 0);
  assert.equal(fs.readdirSync(path.join(h.root, 'outbox')).length, 1);
  await h.tick({ fixture: 'picat' });
  assert.equal(h.sent.length, 1);
  assert.equal(fs.readdirSync(path.join(h.root, 'outbox')).length, 0);
}));

test('unmatched preserved identities consume acknowledgements durably without losing open incidents', async () => harness(async h => {
  await h.tick({ fixture: 'picat' });
  await h.tick({ fixture: 'picat' });
  const incident = h.state().contracts.fixture.open;
  const offline = { deliver: async () => 1 };
  await h.tick({ fixture: 'NECITIT' }, offline);
  await h.tick({ fixture: 'NECITIT' }, offline);
  assert.equal(h.state().queue[0].tranzitie, 'nota');
  fs.mkdirSync(path.join(h.root, 'ack'));
  fs.writeFileSync(path.join(h.root, 'ack', 'fixture'), '');
  const invalid = [{ contract: { ...base, nume: 'invalid-fixture', nivel: 'nota' }, invalid: 'contract-invalid' }];
  await assert.rejects(run(invalid, { ...h.options, boundary: stage => {
    if (stage === 'transitions-committed') throw new Error('simulated-kill');
  } }), /simulated-kill/);
  assert.equal(h.state().contracts.fixture.nota, null);
  assert.equal(h.state().contracts.fixture.open, incident);
  assert.equal(h.state().queue.some(event => event.nume === 'fixture'), false);
  assert.equal(h.state().cleanup.some(item => item.name === 'fixture' && item.ack !== null), true);
  await run(invalid, h.options);
  assert.equal(fs.existsSync(path.join(h.root, 'ack', 'fixture')), false);
  assert.equal(fs.existsSync(path.join(h.root, 'nota-sent', 'fixture')), false);
  assert.equal(h.sent.some(event => event.nume === 'fixture' && event.tranzitie === 'nota'), false);
  assert.equal(h.state().contracts.fixture.open, incident);
}));

test('page = false records the incident and row but sends nothing; page default still sends', async () => harness(async h => {
  const entries = [
    { contract: { ...base, nume: 'quiet', page: false } },
    { contract: { ...base, nume: 'loud' } },
  ];
  const red = { ...h.options, inspect: async () => ({ verdict: 'picat', motiv: 'fixture' }) };
  await run(entries, red);
  h.time(300000);
  await run(entries, red);
  const state = h.state();
  assert.match(state.contracts.quiet.open, /^2026-/, 'incident is recorded');
  assert.equal(state.contracts.quiet.openDelivered, true);
  assert.deepEqual(state.queue, []);
  assert.deepEqual(h.sent.map(e => e.nume), ['loud'], 'only the default contract is paged');
  assert.equal(JSON.parse(fs.readFileSync(path.join(h.root, 'rows', 'quiet.json'), 'utf8')).stare, 'picat');
  // Further red ticks neither re-create nor send the event.
  h.time(300000);
  await run(entries, red);
  assert.deepEqual(h.sent.map(e => e.nume), ['loud']);
  // Recovery is silent too, and the incident still closes by itself.
  const green = { ...h.options, inspect: async () => ({ verdict: 'verde', motiv: 'ok' }) };
  await run(entries, green);
  h.time(300000);
  await run(entries, green);
  h.time(31 * 60000);
  await run(entries, green);
  assert.equal(h.state().contracts.quiet.open, null);
  assert.deepEqual(h.sent.filter(e => e.nume === 'quiet'), []);
  assert.deepEqual(h.sent.map(e => e.tranzitie), ['open', 'close']);
}));

test('page = true is the same as no page field', async () => harness(async h => {
  const entries = [{ contract: { ...base, nume: 'explicit', page: true } }];
  const red = { ...h.options, inspect: async () => ({ verdict: 'picat', motiv: 'fixture' }) };
  await run(entries, red);
  h.time(300000);
  await run(entries, red);
  assert.deepEqual(h.sent.map(e => e.nume), ['explicit']);
}));

const redRun = (h, entries) => run(entries, { ...h.options, inspect: async () => ({ verdict: 'picat', motiv: 'fixture' }) });
const greenRun = (h, entries) => run(entries, { ...h.options, inspect: async () => ({ verdict: 'verde', motiv: 'ok' }) });

test('an open queued before the page switch never sends, and does not hold up other contracts', async () => harness(async h => {
  const both = page => [{ contract: { ...base, nume: 'quiet', ...(page === undefined ? {} : { page }) } }, { contract: { ...base, nume: 'loud' } }];
  h.network(false);
  await redRun(h, both());
  h.time(300000);
  await redRun(h, both());
  assert.deepEqual(h.state().queue.map(e => `${e.nume}/${e.tranzitie}`), ['quiet/open', 'loud/open']);
  assert.deepEqual(h.sent, []);
  h.network(true);
  h.time(300000);
  await redRun(h, both(false)); // the switch
  assert.deepEqual(h.sent.map(e => e.nume), ['loud'], 'only the paged contract sends');
  assert.deepEqual(h.state().queue, []);
  assert.equal(h.state().contracts.quiet.openSuppressed, true);
}));

test('re-enabling paging mid-incident sends no orphan close and a fresh open next time', async () => harness(async h => {
  const entries = page => [{ contract: { ...base, nume: 'flip', page } }];
  await redRun(h, entries(false));
  h.time(300000);
  await redRun(h, entries(false));
  assert.match(h.state().contracts.flip.open, /^2026-/);
  assert.deepEqual(h.sent, []);
  // Paging comes back while the incident is open; the incident then recovers.
  await greenRun(h, entries(true));
  h.time(300000);
  await greenRun(h, entries(true));
  h.time(31 * 60000);
  await greenRun(h, entries(true));
  assert.equal(h.state().contracts.flip.open, null);
  assert.deepEqual(h.sent, [], 'no close without a sent open');
  assert.deepEqual(h.state().queue, []);
  // The next incident is a normal one: its open is sent.
  await redRun(h, entries(true));
  h.time(300000);
  await redRun(h, entries(true));
  assert.deepEqual(h.sent.map(e => e.tranzitie), ['open']);
}));

test('a sent open still gets its close when paging stays on', async () => harness(async h => {
  const entries = [{ contract: { ...base, nume: 'normal' } }];
  await redRun(h, entries);
  h.time(300000);
  await redRun(h, entries);
  await greenRun(h, entries);
  h.time(300000);
  await greenRun(h, entries);
  h.time(31 * 60000);
  await greenRun(h, entries);
  assert.deepEqual(h.sent.map(e => e.tranzitie), ['open', 'close']);
}));

// The real SOC contracts, with their stamp path pointed at a temp file. The
// directory is handed in by pkgs/vigil.nix's checkPhase (hosts/ is not in the
// package source), else read relative to the repo checkout.
const socDir = process.env.VIGIL_SOC_CONTRACTS_DIR
  || fileURLToPath(new URL('../../hosts/sancta-choir/vigil-contracts/', import.meta.url));
const socContract = (file, tinta) => ({
  contract: contractFromToml(fs.readFileSync(path.join(socDir, file), 'utf8')),
  tinta,
});
const withStamp = ({ contract: c, tinta }) => ({ contract: { ...c, tinta } });

test('stale ban and evaluator health stamps page through separate contracts', async () => harness(async h => {
  const bansStamp = path.join(h.root, 'bans-clean');
  const healthStamp = path.join(h.root, 'bans-health-clean');
  for (const file of [bansStamp, healthStamp]) {
    fs.writeFileSync(file, '');
    // 30 minutes old: past the 20m threshold in both contracts.
    const old = new Date(Date.parse('2026-09-20T12:00:00Z') - 30 * 60000);
    fs.utimesSync(file, old, old);
  }
  const entries = [withStamp(socContract('soc-bans.toml', bansStamp)), withStamp(socContract('soc-bans-health.toml', healthStamp))];
  assert.equal(entries[0].contract.page, true);
  assert.equal(entries[1].contract.page, true);
  await run(entries, h.options);                 // real age check, no inspect override
  assert.equal(h.lines.find(l => l.nume === 'soc-bans').verdict, 'picat');
  assert.equal(h.lines.find(l => l.nume === 'soc-bans').motiv, 'age-stale');
  h.time(300000);
  await run(entries, h.options);
  assert.match(h.state().contracts['soc-bans'].open, /^2026-/, 'incident opens after picat_dupa = 2 stale samples');
  assert.deepEqual(h.sent.map(e => `${e.nume}/${e.tranzitie}`), ['soc-bans/open', 'soc-bans-health/open']);
  assert.match(h.state().contracts['soc-bans-health'].open, /^2026-/, 'health also opens an incident');
}));

test('a fresh soc-bans stamp is green and sends nothing', async () => harness(async h => {
  const stamp = path.join(h.root, 'bans-clean');
  fs.writeFileSync(stamp, '');
  const now = Date.parse('2026-09-20T12:00:00Z');
  fs.utimesSync(stamp, new Date(now - 60000), new Date(now - 60000));
  await run([withStamp(socContract('soc-bans.toml', stamp))], h.options);
  assert.equal(h.lines[0].verdict, 'verde');
  assert.deepEqual(h.sent, []);
}));

test('the audit watchdog pages while the audit hit contract stays report-only', async () => harness(async h => {
  const now = Date.parse('2026-09-20T12:00:00Z');
  const hits = path.join(h.root, 'audit-hits-clean');
  const deadman = path.join(h.root, 'audit-deadman-clean');
  for (const file of [hits, deadman]) fs.writeFileSync(file, '');
  fs.utimesSync(hits, 1, 1);
  fs.utimesSync(deadman, new Date(now), new Date(now));
  const entries = [withStamp(socContract('soc-audit.toml', hits)),
    withStamp(socContract('soc-audit-deadman.toml', deadman))];
  await run(entries, h.options);
  h.time(300000);
  await run(entries, h.options);
  assert.equal(h.state().contracts['soc-audit'].verdict, 'picat');
  assert.deepEqual(h.sent, []);

  fs.utimesSync(deadman, 1, 1);
  await run(entries, h.options);
  assert.deepEqual(h.sent.map(e => [e.nume, e.tranzitie]), [['soc-audit-deadman', 'open']]);
}));

test('watchdog refresh before the first Vigil tick clears stale boot stamps and keeps first-sample paging', async () => harness(async h => {
  const now = Date.parse('2026-09-20T12:00:00Z');
  const signals = [['deadman', 'deadman'], ['coverage-gap', 'gap'], ['retention', 'retention']];
  const stamps = signals.map(([, stamp]) => path.join(h.root, `audit-${stamp}-clean`));
  const entries = signals.map(([name], i) => withStamp(socContract(`soc-audit-${name}.toml`, stamps[i])));
  for (const stamp of stamps) {
    fs.writeFileSync(stamp, '');
    const beforeBoot = new Date(now - 20 * 60000);
    fs.utimesSync(stamp, beforeBoot, beforeBoot);
  }
  // The unit runs the watchdog before Vigil samples. The 20-minute-old
  // evaluator heartbeat still passes the watchdog's 30-minute test.
  for (const stamp of stamps) fs.utimesSync(stamp, new Date(now), new Date(now));
  await run(entries, h.options);
  assert.deepEqual(h.lines.map(row => row.verdict), ['verde', 'verde', 'verde']);
  assert.deepEqual(h.sent, []);

  h.time(11 * 60000);
  fs.utimesSync(stamps[0], 1, 1); // the watchdog now sees a 31-minute-old heartbeat
  await run(entries, h.options);
  assert.deepEqual(h.sent.map(e => [e.nume, e.tranzitie]), [['soc-audit-deadman', 'open']]);
}));

test('a latched audit coverage gap continues to page independently of later clean runs', async () => harness(async h => {
  const gap = path.join(h.root, 'audit-gap-clean');
  const health = path.join(h.root, 'audit-deadman-clean');
  fs.writeFileSync(gap, '');
  fs.writeFileSync(health, '');
  fs.utimesSync(gap, 1, 1);
  const entries = [withStamp(socContract('soc-audit-coverage-gap.toml', gap)),
    withStamp(socContract('soc-audit-deadman.toml', health))];
  const now = Date.parse('2026-09-20T12:00:00Z');
  for (let minute = 0; minute <= 40; minute += 5) {
    const healthyAt = new Date(now + minute * 60000);
    fs.utimesSync(health, healthyAt, healthyAt);
    await run(entries, h.options);
    h.time(300000);
  }
  assert.deepEqual(h.sent.map(e => [e.nume, e.tranzitie]), [['soc-audit-coverage-gap', 'open']]);
  assert.equal(h.state().contracts['soc-audit-coverage-gap'].verdict, 'picat');
}));
