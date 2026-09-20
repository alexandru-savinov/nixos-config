import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { run, loadContracts } from './vigil-check.mjs';
import { say } from './vigil-say.mjs';
import { loadStore } from './lib/store.mjs';
import { failed } from './vigil.mjs';

const base = { nume: 'fixture', verifica: 'age', tinta: '/fixture', prag: '1h', picat_dupa: 2, nivel: 'incident' };
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
