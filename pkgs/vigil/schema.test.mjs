import assert from 'node:assert/strict';
import fs from 'node:fs';
import { test } from 'node:test';
import { contract } from './lib/schema.mjs';

const fixtures = JSON.parse(fs.readFileSync(new URL('./schema-fixtures.json', import.meta.url), 'utf8'));
for (const fixture of fixtures) test(`shared schema: ${fixture.name}`, () => {
  if (fixture.accept) assert.doesNotThrow(() => contract(fixture.source));
  else assert.throws(() => contract(fixture.source));
});

// The host contract is not part of the vigil package source, so inside the
// package build this test is skipped; checks.vigil-soc-audit-label runs it
// with VIGIL_SOC_AUDIT_CONTRACT set and fails unless it ran and passed.
const socAudit = process.env.VIGIL_SOC_AUDIT_CONTRACT;
test('the soc-audit tile never implies health on a quiet window',
  { skip: socAudit ? false : 'host contract not in this build; see checks.vigil-soc-audit-label' }, () => {
  const c = contract(fs.readFileSync(socAudit, 'utf8'));
  assert.equal(c.page, false);
  assert.match(c.label, /coverage: partial/);
  assert.match(c.label, /quiet = unverified/);
  assert.ok(c.label.length <= 80);
});
