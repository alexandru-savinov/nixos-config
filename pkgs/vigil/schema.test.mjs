import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import { contract } from './lib/schema.mjs';

const fixtures = JSON.parse(fs.readFileSync(new URL('./schema-fixtures.json', import.meta.url), 'utf8'));
for (const fixture of fixtures) test(`shared schema: ${fixture.name}`, () => {
  if (fixture.accept) assert.doesNotThrow(() => contract(fixture.source));
  else assert.throws(() => contract(fixture.source));
});
