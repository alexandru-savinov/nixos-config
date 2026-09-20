import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import { randomUUID } from 'node:crypto';
import { say, chatAction, telegram, validateEvent } from './vigil-say.mjs';

const event = () => ({ gazda: 'fixture-host', nume: 'fixture', verdict: 'NECITIT', tranzitie: 'nota', nivel: 'nota', event_id: randomUUID(), incident_id: '2026-09-20T12:00:00.000Z', occurred_at: '2026-09-20T12:00:00.000Z' });

test('event schema rejects extra fields, unsafe names and oversized values', () => {
  assert.deepEqual(validateEvent(event()).verdict, 'NECITIT');
  for (const patch of [{ tinta: 'private' }, { jurnal: 'private' }, { nume: '../escape' }, { gazda: 'x'.repeat(501) }, { occurred_at: 'bad' }, { event_id: 'not-a-uuid' }, { tranzitie: 'close' }]) {
    assert.throws(() => validateEvent({ ...event(), ...patch }), /event-invalid/);
  }
  const incomplete = event();
  delete incomplete.incident_id;
  assert.throws(() => validateEvent(incomplete), /event-invalid/);
});

test('row-only mode writes a row without sends, outbox or success markers', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vigil-say-'));
  try {
    let calls = 0;
    const options = { env: { STATE_DIRECTORY: root, VIGIL_SAY: '0' }, send: async () => { calls++; return true; } };
    const first = event();
    assert.equal(await say(first, options), 0);
    assert.equal(await chatAction(options), 0);
    assert.equal(calls, 0);
    assert.deepEqual(fs.readdirSync(root), ['rows']);
    assert.deepEqual(JSON.parse(fs.readFileSync(path.join(root, 'rows', 'fixture.json'))), {
      gazda: first.gazda, nume: first.nume, stare: 'NECITIT', la: first.occurred_at, event_id: first.event_id,
    });
    const newer = { ...event(), occurred_at: '2026-09-20T12:05:00.000Z' };
    await say(newer, options);
    await say(first, options);
    assert.equal(JSON.parse(fs.readFileSync(path.join(root, 'rows', 'fixture.json'))).event_id, newer.event_id);
    assert.equal(fs.existsSync(path.join(root, 'row.json')), false);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test('fake Telegram proves confirmed-only markers, suppression, retries and deadlines', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vigil-telegram-'));
  let mode = 'ok';
  const calls = [];
  const server = http.createServer(async (req, res) => {
    let source = '';
    for await (const chunk of req) source += chunk;
    calls.push({ route: req.url, data: JSON.parse(source) });
    if (mode === 'hang') return;
    if (mode === '429') res.statusCode = 429;
    res.end(JSON.stringify({ ok: mode === 'ok' }));
  });
  await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
  const port = server.address().port;
  const client = { request: (options, callback) => http.request({ ...options, hostname: '127.0.0.1', port }, callback) };
  const env = { STATE_DIRECTORY: root, TELEGRAM_BOT_TOKEN: '123:fixture-token', TELEGRAM_CHAT_ID: 'fixture-chat' };
  const send = (method, data, environment, timeout) => telegram(method, data, environment, timeout, client);
  try {
    const first = event();
    assert.equal(await say(first, { env, send }), 0);
    assert.equal(calls.length, 1);
    assert.equal(calls[0].data.chat_id, env.TELEGRAM_CHAT_ID);
    assert.match(calls[0].data.text, /2026-09-20T12:00:00.000Z fixture-host \/ fixture: NECITIT \(nota\)/);
    assert.equal(fs.existsSync(path.join(root, 'last-channel-ok')), true);
    assert.equal(fs.existsSync(path.join(root, 'last-say-ok')), true);
    assert.equal(await say(first, { env, send }), 0);
    assert.equal(calls.length, 1);
    fs.unlinkSync(path.join(root, 'nota-sent', 'fixture'));
    assert.equal(await say(first, { env, send }), 0);
    assert.equal(calls.length, 2);
    const next = { ...event(), incident_id: '2026-09-20T12:10:00.000Z' };
    assert.equal(await say(next, { env, send }), 0);
    assert.equal(calls.length, 3);
    assert.equal(await chatAction({ env, send }), 0);
    assert.match(calls.at(-1).route, /sendChatAction$/);
    assert.equal(calls.at(-1).data.action, 'typing');
    assert.equal(calls.at(-1).data.chat_id, env.TELEGRAM_CHAT_ID);
    assert.equal(fs.existsSync(path.join(root, 'last-chataction')), true);

    for (const failure of ['false', '429', 'hang']) {
      mode = failure;
      const previous = fs.statSync(path.join(root, 'last-channel-ok')).mtimeMs;
      const pending = { ...event(), nume: `fixture-${failure}` };
      assert.equal(await say(pending, { env, send, timeout: 30 }), 1);
      assert.equal(fs.existsSync(path.join(root, 'rows', `${pending.nume}.json`)), true);
      assert.equal(fs.existsSync(path.join(root, 'nota-sent', pending.nume)), false);
      assert.equal(fs.statSync(path.join(root, 'last-channel-ok')).mtimeMs, previous);
    }
  } finally {
    server.closeAllConnections();
    await new Promise(resolve => server.close(resolve));
    fs.rmSync(root, { recursive: true, force: true });
  }
  assert.equal(await telegram('sendMessage', { text: 'fixture' }, env, 100, client), false);
});
