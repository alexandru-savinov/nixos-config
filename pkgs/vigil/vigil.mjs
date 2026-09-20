#!/usr/bin/env node
import os from 'node:os';
import { randomUUID } from 'node:crypto';
import { pathToFileURL } from 'node:url';
import { iso, namedPath, readJson, stateRoot } from './lib/common.mjs';

export async function failed(options = {}) {
  const env = options.env || process.env;
  const marker = readJson(namedPath(stateRoot(env), 'nota-sent', 'vigil'));
  return (await import('./vigil-say.mjs')).say({
    gazda: options.gazda || os.hostname(), nume: 'vigil', verdict: 'failed', tranzitie: 'open', nivel: 'nota',
    event_id: randomUUID(), incident_id: marker?.incident_id || iso(), occurred_at: iso(),
  }, { ...options, env });
}

export async function main(args = process.argv.slice(2)) {
  const [command, ...rest] = args;
  if (command === 'autoproba' || rest.includes('--autoproba') || command === '--autoproba') {
    return (await import('./autoproba.mjs')).autoproba(rest.filter(arg => arg !== '--autoproba'));
  }
  if (command === 'check') return (await import('./vigil-check.mjs')).main(rest);
  if (command === 'say') return (await import('./vigil-say.mjs')).main(rest);
  if (command === 'tick') return (await import('./vigil-tick.mjs')).main(rest);
  if (command === 'validate-public') return (await import('./lib/public-contracts.mjs')).validatePublic(rest);
  if (command === 'failed' && !rest.length) {
    try {
      return await failed();
    } catch { process.stderr.write('vigil: failure-event-invalid\n'); return 2; }
  }
  process.stderr.write('usage: vigil check|say|tick|failed|validate-public|autoproba\n');
  return 2;
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) process.exitCode = await main();
