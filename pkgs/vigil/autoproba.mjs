import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { spawnSync } from 'node:child_process';

export function autoproba(args = []) {
  if (args.some(arg => arg !== '--ack-only') || args.length > 1) {
    process.stderr.write('EȘEC: autoproba-usage\n');
    return 2;
  }
  const directory = path.dirname(fileURLToPath(import.meta.url));
  const files = args.includes('--ack-only') ? ['ack.test.mjs']
    : fs.readdirSync(directory).filter(name => name.endsWith('.test.mjs')).sort();
  if (!files.length) { process.stderr.write('EȘEC: no-tests\n'); return 2; }
  const result = spawnSync(process.execPath, ['--test', ...files.map(name => path.join(directory, name))], {
    encoding: 'utf8', maxBuffer: 4 * 1024 * 1024, timeout: 120000,
    env: { ...process.env, NODE_OPTIONS: '', FORCE_COLOR: '0' },
  });
  const report = `${result.stdout || ''}\n${result.stderr || ''}`;
  const count = /^# tests ([1-9][0-9]*)$/m.exec(report);
  if (result.status !== 0 || !count || !/^# fail 0$/m.test(report) || !/^# skipped 0$/m.test(report)) {
    // Name what failed on stdout (the build log shows it); stderr stays the one-word verdict
    // that mutations.mjs matches exactly.
    // …plus the failure's own detail (error, expected, actual, location), so a flaky run in CI
    // tells us WHICH assertion broke, not just which test.
    const lines = report.split('\n');
    lines.forEach((l, i) => {
      if (!/^\s*not ok \d+ - /.test(l)) return;
      process.stdout.write(`PICAT: ${l.trim()}\n`);
      for (const d of lines.slice(i + 1, i + 30)) {
        if (/^\s*(ok|not ok) \d+ - |^\s*\.\.\.\s*$/.test(d)) break;
        if (/^\s*(error|expected|actual|operator|location|failureType|code):|^\s{4,}\S/.test(d)) process.stdout.write(`PICAT:   ${d.trim().slice(0, 200)}\n`);
      }
    });
    process.stderr.write(`EȘEC: ${report.includes('ERR_ASSERTION') ? 'assertion' : 'test-runtime'}\n`);
    return 2;
  }
  process.stdout.write(`AUTOPROBA: ${count[1]} assertions suites passed${args.length ? ' (isolated ack)' : ''}\n`);
  return 0;
}
