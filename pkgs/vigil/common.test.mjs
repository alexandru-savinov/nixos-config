import assert from 'node:assert/strict';
import { test } from 'node:test';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { atomicWrite, statePath, namedPath } from './lib/common.mjs';

for (const operation of ['writeFileSync', 'fsyncSync', 'renameSync']) {
  test(`atomic write cleans its temporary after ${operation} failure and preserves previous state`, t => {
    const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vigil-atomic-'));
    const file = path.join(root, 'state.json');
    const fault = Object.assign(new Error('fixture-write-failure'), { code: 'ENOSPC' });
    try {
      fs.writeFileSync(file, 'previous');
      const write = fs.writeFileSync.bind(fs);
      const mocked = t.mock.method(fs, operation, (...args) => {
        if (operation === 'writeFileSync') write(args[0], 'partial');
        throw fault;
      });
      assert.throws(() => atomicWrite(file, { next: true }), error => error === fault);
      mocked.mock.restore();
      assert.equal(fs.readFileSync(file, 'utf8'), 'previous');
      assert.deepEqual(fs.readdirSync(root), ['state.json']);
      atomicWrite(file, { next: true });
      assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')), { next: true });
    } finally { t.mock.restoreAll(); fs.rmSync(root, { recursive: true, force: true }); }
  });
}

test('derived paths reject traversal independently of contract name validation', () => {
  const root = '/tmp/vigil-path-fixture';
  assert.equal(statePath(root, 'ack', 'fixture'), root + '/ack/fixture');
  assert.equal(namedPath(root, 'ack', 'fixture'), root + '/ack/fixture');
  for (const suffix of ['../escape', '../vigil-path-fixture-sibling/entry', '/tmp/outside-fixture', '.']) {
    assert.throws(() => statePath(root, suffix), /state-path/);
  }
  // The valid name bypasses no regex: the directory itself must stay contained.
  assert.throws(() => namedPath(root, '../outside-fixture', 'fixture'), /state-path/);
  assert.throws(() => namedPath(root, 'ack', '../escape'), /state-name/);
});
