import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import { contract } from './lib/schema.mjs';

const fixtures = JSON.parse(fs.readFileSync(new URL('./schema-fixtures.json', import.meta.url), 'utf8'));
for (const fixture of fixtures) test(`shared schema: ${fixture.name}`, () => {
  if (fixture.accept) assert.doesNotThrow(() => contract(fixture.source));
  else assert.throws(() => contract(fixture.source));
});

test('the soc-audit tile never implies health on a quiet window', () => {
  const file = new URL('../../hosts/sancta-choir/vigil-contracts/soc-audit.toml', import.meta.url);
  const c = contract(fs.readFileSync(file, 'utf8'));
  assert.equal(c.page, false);
  assert.match(c.label, /coverage: partial/);
  assert.match(c.label, /quiet = unverified/);
  assert.ok(c.label.length <= 80);
});
