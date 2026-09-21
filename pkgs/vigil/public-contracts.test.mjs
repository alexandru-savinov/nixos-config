import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { test } from 'node:test';
import { validatePublic } from './lib/public-contracts.mjs';

const fixtures = JSON.parse(fs.readFileSync(new URL('./schema-fixtures.json', import.meta.url), 'utf8'));
test('mandatory public-contract build gate agrees with every runtime fixture', () => {
  const directory = fs.mkdtempSync(path.join(os.tmpdir(), 'vigil-public-'));
  try {
    const file = path.join(directory, 'fixture.toml');
    for (const fixture of fixtures) {
      fs.writeFileSync(file, fixture.source);
      const messages = [];
      assert.equal(validatePublic([directory], message => messages.push(message)), fixture.accept ? 0 : 2, fixture.name);
      if (fixture.accept) assert.deepEqual(messages, ['vigil: validated 1 public contracts']);
      else assert.equal(messages[0], `vigil: invalid public contract ${file}`);
    }
    fs.writeFileSync(file, fixtures[0].source);
    fs.symlinkSync(file, path.join(directory, 'duplicate.toml'));
    const messages = [];
    assert.equal(validatePublic([directory], message => messages.push(message)), 2);
    assert.match(messages[0], /duplicate public contract/);
  } finally { fs.rmSync(directory, { recursive: true, force: true }); }
});
