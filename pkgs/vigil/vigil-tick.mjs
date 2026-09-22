#!/usr/bin/env node
import fs from 'node:fs';
import { dashboardCheck } from './lib/dashboard.mjs';
import { pathToFileURL } from 'node:url';
import { atomicWrite, stateRoot, statePath, validTime } from './lib/common.mjs';

export function validCounts(value) {
  const keys = ['run_id', 'la', 'verde', 'picat', 'necitit'];
  return value && typeof value === 'object' && !Array.isArray(value)
    && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key))
    && typeof value.run_id === 'string' && /^[a-zA-Z0-9-]{1,128}$/.test(value.run_id)
    && validTime(value.la)
    && ['verde', 'picat', 'necitit'].every(key => Number.isSafeInteger(value[key]) && value[key] >= 0);
}

function readCounts(file) {
  let source;
  try { source = fs.readFileSync(file, 'utf8'); }
  catch (error) {
    if (error.code === 'ENOENT') return null;
    throw new Error('tick-unreadable');
  }
  if (source.length > 4096) throw new Error('tick-unreadable');
  let value;
  try { value = JSON.parse(source); } catch { throw new Error('tick-unreadable'); }
  if (!validCounts(value)) throw new Error('tick-unreadable');
  return value;
}

export function publish(env = process.env) {
  if (env.SERVICE_RESULT !== 'success' || !['0', '1', '2'].includes(env.EXIT_STATUS)) return false;
  const root = stateRoot(env);
  const counts = readCounts(statePath(root, 'tick.counts.json'));
  if (!counts || counts.run_id !== env.INVOCATION_ID) return false;
  const previous = readCounts(statePath(root, 'tick'));
  if (previous?.run_id === counts.run_id) return false;
  atomicWrite(statePath(root, 'tick'), counts, 0o644);
  return true;
}

export function response(root, method = 'GET', target = '/', now = Date.now(), env = process.env) {
  let status;
  let body;
  const checkName = /^\/checks\/([a-z0-9][a-z0-9-]{0,63})$/.exec(target)?.[1];
  if (!['GET', 'HEAD'].includes(method)) { status = '405 Method Not Allowed'; body = 'method-not-allowed\n'; }
  else if (!['/', '/status'].includes(target) && !checkName) { status = '404 Not Found'; body = 'not-found\n'; }
  else {
    try {
      const counts = readCounts(statePath(root, 'tick'));
      if (!counts) { status = '404 Not Found'; body = 'tick-absent\n'; }
      else {
        status = '200 OK';
        if (target === '/status') {
          const row = JSON.parse(fs.readFileSync(statePath(root, 'row.json'), 'utf8'));
          const age = now - Date.parse(counts.la);
          // Gatus presents the existing verdict; it does not drive incident state.
          counts.stare = age >= 0 && age < 900000 && row.la === counts.la
            && ['verde', 'picat', 'NECITIT'].includes(row.stare) ? row.stare : 'NECITIT';
        }
        if (checkName) {
          const check = dashboardCheck(root, checkName, counts, now, env);
          if (!check) { status = '404 Not Found'; body = 'check-absent\n'; }
          else body = `${JSON.stringify(check)}\n`;
        } else body = `${JSON.stringify(counts)}\n`;
      }
    } catch {
      status = '503 Service Unavailable';
      body = 'tick-unreadable\n';
    }
  }
  const type = status === '200 OK' ? 'application/json' : 'text/plain';
  return `HTTP/1.1 ${status}\r\nContent-Type: ${type}\r\nContent-Length: ${Buffer.byteLength(body)}\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n${method === 'HEAD' ? '' : body}`;
}

export function serve({ input = process.stdin, output = process.stdout, env = process.env, timeout = 2000 } = {}) {
  const root = stateRoot(env);
  return new Promise(resolve => {
    let header = '';
    let finished = false;
    const finish = text => {
      if (finished) return;
      finished = true;
      clearTimeout(timer);
      input.removeListener('data', data);
      input.removeListener('end', ended);
      input.pause();
      output.end(text, resolve);
    };
    const bad = () => finish('HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\nConnection: close\r\n\r\n');
    const timer = setTimeout(bad, timeout);
    const ended = () => { if (!finished) bad(); };
    const data = chunk => {
      header += chunk.toString('latin1');
      if (header.length > 8192) { bad(); return; }
      const end = header.indexOf('\r\n\r\n');
      if (end === -1) return;
      const firstLine = /^([A-Z]+) (\S+) HTTP\/1\.[01]\r\n/.exec(header);
      if (!firstLine) { bad(); return; }
      finish(response(root, firstLine[1], firstLine[2], Date.now(), env));
    };
    input.on('data', data);
    input.once('end', ended);
    input.once('error', bad);
    output.once('error', () => { clearTimeout(timer); finished = true; input.pause(); resolve(); });
  });
}

export async function main(args = process.argv.slice(2)) {
  if (args.length === 1 && args[0] === '--autoproba') return (await import('./autoproba.mjs')).autoproba();
  try {
    if (args.length !== 1 || !['write', 'serve'].includes(args[0])) throw new Error('tick-usage');
    if (args[0] === 'write') publish();
    else await serve();
    return 0;
  } catch {
    process.stderr.write('vigil-tick: tick-unreadable\n');
    return 3;
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) process.exitCode = await main();
