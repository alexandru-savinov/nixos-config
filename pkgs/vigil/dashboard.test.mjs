import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { run } from './vigil-check.mjs';
import { publish, response } from './vigil-tick.mjs';
import { publicNames } from './lib/dashboard.mjs';
import { HOLD_DOWN } from './lib/incident.mjs';

async function fixture(fn) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vigil-dashboard-'));
  let now = Date.parse('2026-09-22T06:00:00.000Z');
  let serial = 0;
  const env = { STATE_DIRECTORY: root, VIGIL_SAY: '1', VIGIL_PUBLIC_NAMES: '["galeria"]' };
  const entries = ['galeria', 'private-1'].map(nume => ({ contract: {
    nume, ce: 'SECRET_DESCRIPTION', verifica: 'age', tinta: '/SECRET_TARGET', prag: '1h', picat_dupa: 2, nivel: 'incident',
  } }));
  const tick = async (verdict, reason = verdict === 'verde' ? 'ok' : 'network-unreachable', commit = true) => {
    env.INVOCATION_ID = `fixture-${++serial}`;
    const code = await run(entries, { env, gazda: 'fixture', clock: () => now, probe: async () => 0,
      inspect: async c => c.nume === 'galeria' ? { verdict, motiv: reason } : { verdict: 'verde', motiv: 'ok' },
      deliver: async () => 0, output: () => {}, summary: () => {},
    });
    if (commit) assert.equal(publish({ ...env, SERVICE_RESULT: 'success', EXIT_STATUS: String(code) }), true);
    return code;
  };
  const http = (target = '/checks/galeria', at = now) => response(root, 'GET', target, at, env);
  const body = (at = now) => JSON.parse(http('/checks/galeria', at).split('\r\n\r\n')[1]);
  try { await fn({ root, env, tick, http, body, advance: ms => { now += ms; }, time: () => now }); }
  finally { fs.rmSync(root, { recursive: true, force: true }); }
}

test('dashboard explains failure thresholds, confirmed delivery and unchanged continuous recovery', async () => fixture(async f => {
  assert.equal(await f.tick('picat'), 1);
  assert.equal(f.body().stare, 'picat');
  assert.equal(f.body().incident, 'none');
  assert.match(f.body().detail, /samples 1\/2; incident none; delivery none/);
  f.advance(300000);
  await f.tick('picat');
  assert.equal(f.body().incident, 'open');
  assert.equal(f.body().delivery, 'confirmed');
  f.advance(300000);
  await f.tick('verde');
  assert.equal(f.body().verdict, 'verde');
  assert.equal(f.body().stare, 'picat');
  assert.equal(f.body().incident, 'recovering');
  assert.equal(Date.parse(f.body().close_not_before), f.time() + HOLD_DOWN);
  assert.match(f.body().detail, /close no earlier than/);
  f.advance(HOLD_DOWN - 1);
  await f.tick('verde');
  assert.equal(f.body().incident, 'recovering');
  f.advance(1);
  await f.tick('verde');
  assert.equal(f.body().stare, 'verde');
  assert.equal(f.body().detail, 'ok');
  const before = fs.readFileSync(path.join(f.root, 'incidents.json'), 'utf8');
  for (let i = 0; i < 10; i++) f.http();
  assert.equal(fs.readFileSync(path.join(f.root, 'incidents.json'), 'utf8'), before);
}));

test('dashboard excludes private contracts, targets and free-form diagnostics', async () => fixture(async f => {
  await f.tick('NECITIT', 'SECRET_EXCEPTION');
  const snapshot = fs.readFileSync(path.join(f.root, 'dashboard.json'), 'utf8');
  assert.doesNotMatch(snapshot, /SECRET_|private-1/);
  assert.equal(f.body().reason, 'check-unreadable');
  assert.match(f.http('/checks/private-1'), /^HTTP\/1.1 404/);
  assert.match(f.http('/checks/..'), /^HTTP\/1.1 404/);
  const file = path.join(f.root, 'dashboard.json');
  const original = JSON.parse(snapshot);
  for (const mutate of [
    x => { x.checks.galeria.target = 'SECRET_TARGET'; },
    x => { x.checks.galeria.reason = 'SECRET_EXCEPTION'; },
    x => { x.checks.galeria.pending = ['SECRET_EVENT']; },
    x => { x.extra = 'SECRET_EXTRA'; },
  ]) {
    const value = structuredClone(original); mutate(value);
    fs.writeFileSync(file, JSON.stringify(value));
    assert.match(f.http(), /^HTTP\/1.1 503/);
    assert.doesNotMatch(f.http(), /SECRET_/);
  }
}));

test('dashboard rejects stale, future, interrupted and same-time mismatched evidence', async () => fixture(async f => {
  await f.tick('verde');
  assert.equal(f.body(f.time() + 900000).stare, 'NECITIT');
  assert.equal(f.body(f.time() - 1).fresh, false);
  // A distinct run at the same timestamp is still uncommitted.
  await f.tick('verde', 'ok', false);
  assert.equal(f.body().stare, 'NECITIT');
  assert.equal(f.body().fresh, false);
  assert.equal(f.body().verdict, undefined);
  fs.unlinkSync(path.join(f.root, 'dashboard.json'));
  assert.match(f.http(), /^HTTP\/1.1 503/);
}));

test('optional dashboard persistence failure does not change monitoring results', async () => fixture(async f => {
  fs.mkdirSync(path.join(f.root, 'dashboard.json'));
  assert.equal(await f.tick('verde'), 0);
  const counts = JSON.parse(fs.readFileSync(path.join(f.root, 'tick'), 'utf8'));
  assert.equal(counts.verde, 2);
  assert.equal(counts.necitit, 0);
  assert.match(f.http(), /^HTTP\/1.1 503/);
}));

test('dashboard public-name allowlist is explicit and bounded', () => {
  assert.deepEqual(publicNames({}), []);
  for (const input of ['{}', '["../secret"]', '["one","one"]', '[1]', JSON.stringify(Array.from({ length: 257 }, (_, i) => `a-${i}`))]) {
    assert.throws(() => publicNames({ VIGIL_PUBLIC_NAMES: input }), /dashboard-invalid/);
  }
});

test('dashboard shows a contract label and marks suppressed delivery', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vigil-dashboard-label-'));
  let now = Date.parse('2026-09-22T06:00:00.000Z');
  const env = { STATE_DIRECTORY: root, VIGIL_SAY: '1', VIGIL_PUBLIC_NAMES: '["quiet","plain"]', INVOCATION_ID: 'fixture-label' };
  const mk = (nume, extra) => ({ contract: { nume, ce: 'x', verifica: 'age', tinta: '/x', prag: '1h', picat_dupa: 2, nivel: 'incident', ...extra } });
  const entries = [mk('quiet', { page: false, label: 'coverage: partial' }), mk('plain', {})];
  const tick = async verdict => {
    env.INVOCATION_ID = `fixture-label-${now}`;
    const code = await run(entries, { env, gazda: 'fixture', clock: () => now, probe: async () => 0,
      inspect: async () => ({ verdict, motiv: verdict === 'verde' ? 'ok' : 'age-stale' }),
      deliver: async () => 0, output: () => {}, summary: () => {} });
    publish({ ...env, SERVICE_RESULT: 'success', EXIT_STATUS: String(code) });
  };
  const body = name => JSON.parse(response(root, 'GET', `/checks/${name}`, now, env).split('\r\n\r\n')[1]);
  try {
    await tick('verde');
    // Green stays green, with the label beside it; a plain contract has none.
    assert.equal(body('quiet').stare, 'verde');
    assert.equal(body('quiet').detail, 'ok');
    assert.equal(body('quiet').label, 'coverage: partial');
    assert.equal(body('quiet').delivery, 'suppressed');
    assert.equal(Object.hasOwn(body('plain'), 'label'), false);
    assert.equal(body('plain').delivery, 'none');
    now += 300000; await tick('picat');
    now += 300000; await tick('picat');
    const red = body('quiet');
    assert.equal(red.stare, 'picat');
    assert.equal(red.incident, 'open');
    assert.equal(red.delivery, 'suppressed');
    assert.equal(red.label, 'coverage: partial');
    assert.equal(body('plain').delivery, 'confirmed');
    // A tampered label is rejected like any other unexpected field.
    const file = path.join(root, 'dashboard.json');
    const value = JSON.parse(fs.readFileSync(file, 'utf8'));
    value.checks.quiet.label = 'x'.repeat(81);
    fs.writeFileSync(file, JSON.stringify(value));
    assert.match(response(root, 'GET', '/checks/quiet', now, env), /^HTTP\/1.1 503/);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
