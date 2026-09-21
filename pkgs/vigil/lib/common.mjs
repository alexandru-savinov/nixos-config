import fs from 'node:fs';
import path from 'node:path';
import { randomUUID } from 'node:crypto';

export const NAME = /^[a-z0-9][a-z0-9-]{0,63}$/;
export const DAY = 86_400_000;
export function stateRoot(env = process.env) {
  const root = env.STATE_DIRECTORY || '/var/lib/vigil';
  if (!path.isAbsolute(root) || root.includes(':')) throw new Error('state-directory');
  return root;
}
export function statePath(root, ...parts) {
  const base = path.resolve(root);
  const result = path.resolve(base, ...parts);
  if (!result.startsWith(`${base}/`)) throw new Error('state-path');
  return result;
}
export function namedPath(root, directory, name) {
  if (!NAME.test(name)) throw new Error('state-name');
  return statePath(root, directory, name);
}
export function atomicWrite(file, value, mode = 0o600) {
  fs.mkdirSync(path.dirname(file), { recursive: true, mode: 0o750 });
  const temporary = `${file}.${randomUUID()}.tmp`;
  const fd = fs.openSync(temporary, 'wx', mode);
  try {
    try {
      fs.writeFileSync(fd, typeof value === 'string' ? value : `${JSON.stringify(value)}\n`);
      fs.fsyncSync(fd);
    } finally {
      fs.closeSync(fd);
    }
    fs.renameSync(temporary, file);
    const directory = fs.openSync(path.dirname(file), 'r');
    try { fs.fsyncSync(directory); } finally { fs.closeSync(directory); }
  } catch (error) {
    // Best effort: preserve the persistence error even if cleanup also fails.
    try { fs.unlinkSync(temporary); } catch { /* No successful state is claimed. */ }
    throw error;
  }
}
export function readJson(file, absent = null) {
  try { return JSON.parse(fs.readFileSync(file, 'utf8')); }
  catch (error) {
    if (error.code === 'ENOENT') return absent;
    throw new Error('state-unreadable');
  }
}
export function remove(file) {
  try { fs.unlinkSync(file); }
  catch (error) { if (error.code !== 'ENOENT') throw error; }
}
export function iso(now = Date.now()) { return new Date(now).toISOString(); }
export function validTime(value) {
  return typeof value === 'string' && /^\d{4}-\d\d-\d\dT/.test(value) && Number.isFinite(Date.parse(value));
}
export function duration(value) {
  const match = typeof value === 'string' && /^([1-9][0-9]*)([smhd])$/.exec(value);
  if (!match) throw new Error('duration');
  const result = Number(match[1]) * { s: 1000, m: 60_000, h: 3_600_000, d: DAY }[match[2]];
  if (!Number.isSafeInteger(result)) throw new Error('duration');
  return result;
}
