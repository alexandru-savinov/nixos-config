import fs from 'node:fs';
import path from 'node:path';
import { contract } from './schema.mjs';

// Build-time only: callers pass public Nix-store directories, never secrets.
// The same parser and engine-level schema validation run here and at runtime.
export function validatePublic(directories, report = line => process.stderr.write(`${line}\n`)) {
  const names = new Set();
  let count = 0;
  try {
    for (const directory of directories) {
      for (const name of fs.readdirSync(directory).filter(name => name.endsWith('.toml')).sort()) {
        const file = path.join(directory, name);
        let parsed;
        try {
          const stat = fs.statSync(file);
          if (!stat.isFile() || stat.size > 65536) throw new Error('contract-invalid');
          parsed = contract(fs.readFileSync(file, 'utf8'));
        } catch {
          report(`vigil: invalid public contract ${file}`);
          return 2;
        }
        if (names.has(parsed.nume)) {
          report(`vigil: duplicate public contract ${file}`);
          return 2;
        }
        names.add(parsed.nume);
        count++;
      }
    }
  } catch {
    report('vigil: public-contracts-unreadable');
    return 2;
  }
  report(`vigil: validated ${count} public contracts`);
  return 0;
}
