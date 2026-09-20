import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

const mutations = [
  ['stale-dashboard-green', 'vigil-tick.mjs', 'age >= 0 && age < 900000 && row.la === counts.la', 'row.la === counts.la'],
  ['premature-self-rearm', 'vigil-check.mjs', "  atomicWrite(statePath(root, 'tick.counts.json'),", "  remove(namedPath(root, 'nota-sent', 'vigil'));\n  atomicWrite(statePath(root, 'tick.counts.json'),"],
  ['public-gate-bypassed', 'lib/public-contracts.mjs', 'report(`vigil: invalid public contract ${file}`);\n          return 2;', 'report(`vigil: invalid public contract ${file}`);\n          return 0;'],
  ['missing-file-green', 'lib/checks.mjs', 'const stat = await read(() => io.stat(c.tinta));', 'const stat = await read(() => io.stat(c.tinta)).catch(() => ({ mtimeMs: now }));'],
  ['no-hold-down', 'lib/incident.mjs', 'HOLD_DOWN = 30 * 60 * 1000', 'HOLD_DOWN = 0'],
  ['unreadable-success', 'vigil-check.mjs', 'return counts.necitit || !entries.length ? 2 : counts.picat ? 1 : 0;', 'return counts.necitit || !entries.length ? 0 : counts.picat ? 1 : 0;'],
  ['missing-executable-failure', 'lib/checks.mjs', "['ENOENT', 'EACCES', 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER']", "['EACCES', 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER']"],
  ['mount-substring', 'lib/checks.mjs', "decode(line.split(' ')[4]) === target", "decode(line.split(' ')[4]).includes(target)"],
  ['nota-marker-retained', 'lib/store.mjs', "if (item.marker) remove(namedPath(root, 'nota-sent', item.name));", 'if (item.marker) void item.name;'],
  ['telegram-false-accepted', 'vigil-say.mjs', 'parsed?.ok === true', 'true'],
  ['private-field-accepted', 'vigil-say.mjs', 'Object.keys(event).length !== keys.length', 'false'],
  ['row-only-sends', 'vigil-say.mjs', "if (env.VIGIL_SAY === '0') return 0;\n  const marker", "if (false) return 0;\n  const marker"],
  ['absent-tick-success', 'vigil-tick.mjs', "status = '404 Not Found'; body = 'tick-absent\\n'", "status = '200 OK'; body = 'tick-absent\\n'"],
  ['failed-run-publishes', 'vigil-tick.mjs', "!['0', '1', '2'].includes(env.EXIT_STATUS)", 'false'],
];
const source = path.dirname(fileURLToPath(import.meta.url));
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'vigil-mutants-'));
let failures = 0;
try {
  for (const [name, file, original, replacement] of mutations) {
    const directory = path.join(root, name);
    fs.cpSync(source, directory, { recursive: true });
    const target = path.join(directory, file);
    const text = fs.readFileSync(target, 'utf8');
    if (text.split(original).length !== 2) throw new Error('mutation-anchor');
    fs.writeFileSync(target, text.replace(original, replacement));
    const result = spawnSync(process.execPath, [path.join(directory, 'vigil.mjs'), 'autoproba'], { encoding: 'utf8', timeout: 150000, maxBuffer: 1024 * 1024 });
    if (result.status === 2 && result.stderr.trim() === 'EȘEC: assertion') process.stdout.write(`MUTANT REJECTED: ${name}\n`);
    else { failures++; process.stderr.write(`EȘEC: mutation-${name}\n`); }
  }
} catch {
  failures++;
  process.stderr.write('EȘEC: mutation-runtime\n');
} finally { fs.rmSync(root, { recursive: true, force: true }); }
process.exitCode = failures ? 2 : 0;
