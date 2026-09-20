import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import { PassThrough } from 'node:stream';
import { publish, response, serve, validCounts } from './vigil-tick.mjs';

const counts = { run_id: 'fixture-1', la: '2026-09-20T12:00:00.000Z', verde: 4, picat: 1, necitit: 0 };
function fixture(fn) {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vigil-tick-'));
  try { return fn(root); } finally { fs.rmSync(root, { recursive: true, force: true }); }
}

test('tick publishes only matching completed runs with acceptable exit status', () => fixture(root => {
  const env = { STATE_DIRECTORY: root, SERVICE_RESULT: 'success', EXIT_STATUS: '1', INVOCATION_ID: counts.run_id };
  fs.writeFileSync(path.join(root, 'tick.counts.json'), JSON.stringify(counts));
  assert.equal(publish({ ...env, EXIT_STATUS: '3' }), false);
  assert.equal(publish({ ...env, SERVICE_RESULT: 'timeout' }), false);
  assert.equal(publish({ ...env, INVOCATION_ID: 'different' }), false);
  assert.equal(fs.existsSync(path.join(root, 'tick')), false);
  assert.equal(publish(env), true);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(root, 'tick'))), counts);
  const before = fs.statSync(path.join(root, 'tick')).mtimeMs;
  assert.equal(publish(env), false);
  assert.equal(fs.statSync(path.join(root, 'tick')).mtimeMs, before);
  const next = { ...counts, run_id: 'fixture-2', la: '2026-09-20T12:05:00.000Z', necitit: 1 };
  fs.writeFileSync(path.join(root, 'tick.counts.json'), JSON.stringify(next));
  assert.equal(publish({ ...env, INVOCATION_ID: next.run_id, EXIT_STATUS: '2' }), true);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(root, 'tick'))), next);
}));

test('corrupt or absent counts cannot replace the previous tick', () => fixture(root => {
  fs.writeFileSync(path.join(root, 'tick'), JSON.stringify(counts));
  const env = { STATE_DIRECTORY: root, SERVICE_RESULT: 'success', EXIT_STATUS: '0', INVOCATION_ID: 'fixture-2' };
  assert.equal(publish(env), false);
  fs.writeFileSync(path.join(root, 'tick.counts.json'), '{}');
  assert.throws(() => publish(env), /tick-unreadable/);
  assert.deepEqual(JSON.parse(fs.readFileSync(path.join(root, 'tick'))), counts);
  for (const invalid of [{ ...counts, picat: -1 }, { ...counts, verde: 1.5 }, { ...counts, la: 'yesterday' }, { ...counts, target: 'private' }]) assert.equal(validCounts(invalid), false);
}));

test('HTTP response distinguishes missing, corrupt and valid ticks; HEAD has correct length', () => fixture(root => {
  assert.match(response(root), /^HTTP\/1.1 404/);
  fs.writeFileSync(path.join(root, 'tick'), 'broken');
  assert.match(response(root), /^HTTP\/1.1 503/);
  fs.writeFileSync(path.join(root, 'tick'), JSON.stringify(counts));
  const get = response(root);
  assert.match(get, /^HTTP\/1.1 200/);
  assert.deepEqual(JSON.parse(get.split('\r\n\r\n')[1]), counts);
  const head = response(root, 'HEAD');
  assert.equal(head.split('\r\n\r\n')[1], '');
  assert.equal(head.split('\r\n\r\n')[0], get.split('\r\n\r\n')[0]);
  assert.match(response(root, 'POST'), /^HTTP\/1.1 405/);
  assert.match(response(root, 'GET', '/other'), /^HTTP\/1.1 404/);
}));

test('socket responder handles partial headers, oversized input and request deadlines', async () => {
  const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vigil-serve-'));
  try {
    async function exchange(chunks) {
      const input = new PassThrough();
      const output = new PassThrough();
      let text = '';
      output.on('data', chunk => { text += chunk; });
      const done = serve({ input, output, env: { STATE_DIRECTORY: root }, timeout: 20 });
      for (const chunk of chunks) input.write(chunk);
      await done;
      input.destroy();
      return text;
    }
    assert.match(await exchange(['GET / HTTP/1.1\r\n', 'Host: fixture\r\n\r\n']), /^HTTP\/1.1 404/);
    assert.match(await exchange(['GET / HTTP/1.1\r\n']), /^HTTP\/1.1 400/);
    assert.match(await exchange(['x'.repeat(8193)]), /^HTTP\/1.1 400/);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});
