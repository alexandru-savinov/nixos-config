import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import http from 'node:http';
import { run } from './vigil-check.mjs';
import { say, telegram } from './vigil-say.mjs';

test('isolated real age check consumes an ack and sends exactly one replacement nota', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vigil-ack-'));
  const messages = [];
  const server = http.createServer(async (req, res) => {
    let body = '';
    for await (const chunk of req) body += chunk;
    messages.push(JSON.parse(body));
    res.end('{"ok":true}');
  });
  try {
    await new Promise((resolve, reject) => { server.once('error', reject); server.listen(0, '127.0.0.1', resolve); });
    const port = server.address().port;
    const client = { request: (options, callback) => http.request({ ...options, hostname: '127.0.0.1', port }, callback) };
    const target = path.join(root, 'missing-fixture');
    const env = { STATE_DIRECTORY: root, VIGIL_SAY: '1', INVOCATION_ID: 'ack-fixture', TELEGRAM_BOT_TOKEN: '123:fixture', TELEGRAM_CHAT_ID: 'fixture' };
    const entries = [{ contract: { nume: 'fixture', ce: 'Fixture', verifica: 'age', tinta: target, prag: '1h', picat_dupa: 2, nivel: 'incident' } }];
    const lines = [];
    const tick = () => run(entries, { env, gazda: 'fixture-host', probe: async () => 0,
      output: text => lines.push(text), summary: () => {},
      deliver: (event, timeout) => say(event, { env, timeout,
        send: (method, data, environment, deadline) => telegram(method, data, environment, deadline, client),
      }),
    });
    assert.equal(await tick(), 2);
    assert.equal(await tick(), 2);
    assert.equal(await tick(), 2);
    assert.equal(messages.length, 1);
    assert.match(lines.at(-1), /"verdict":"NECITIT"/);
    assert.match(messages[0].text, /fixture: NECITIT \(nota\)/);
    fs.mkdirSync(path.join(root, 'ack'));
    fs.writeFileSync(path.join(root, 'ack', 'fixture'), '');
    assert.equal(await tick(), 2);
    assert.equal(fs.existsSync(path.join(root, 'ack', 'fixture')), false);
    assert.equal(messages.length, 1);
    assert.equal(await tick(), 2);
    assert.equal(messages.length, 2);
    fs.writeFileSync(target, 'fixture');
    assert.equal(await tick(), 0);
    assert.match(lines.at(-1), /"verdict":"verde"/);
    assert.equal(fs.existsSync(path.join(root, 'nota-sent', 'fixture')), false);
    assert.equal(messages.length, 2);
    for (const message of messages) assert.equal(message.text.includes(target), false);
    assert.doesNotMatch(JSON.stringify(messages), /missing-fixture/);
  } finally {
    server.closeAllConnections();
    if (server.listening) await new Promise(resolve => server.close(resolve));
    fs.rmSync(root, { recursive: true, force: true });
  }
});
