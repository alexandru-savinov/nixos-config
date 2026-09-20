import fs from 'node:fs/promises';
import net from 'node:net';
import http from 'node:http';
import https from 'node:https';
import { execFile } from 'node:child_process';
import { Worker } from 'node:worker_threads';
import { duration, validTime } from './common.mjs';
import { tcpTarget } from './schema.mjs';

const LIMIT = 65536;
const answer = (verdict, motiv) => ({ verdict, motiv });
const green = () => answer('verde', 'ok');
const failed = reason => answer('picat', reason);
const unreadable = reason => answer('NECITIT', reason);
const commandEnvironment = env => ({ PATH: env.PATH || '', LANG: 'C', LC_ALL: 'C', TZ: 'UTC' });

async function filesystem(operation, timeout) {
  let timer;
  try {
    return await Promise.race([operation(), new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error('filesystem-timeout')), timeout);
    })]);
  } finally { clearTimeout(timer); }
}

// Never return exception messages, command output, URLs or response bodies.
export function command(argv, timeout = 10000, environment = commandEnvironment(process.env)) {
  return new Promise(resolve => {
    const child = execFile(argv[0], argv.slice(1), {
      timeout, killSignal: 'SIGKILL', maxBuffer: LIMIT, encoding: 'utf8',
      windowsHide: true, env: environment,
    }, (error, stdout) => {
      if (error) {
        const missing = ['ENOENT', 'EACCES', 'ERR_CHILD_PROCESS_STDIO_MAXBUFFER'].includes(error.code)
          || error.code === null || error.code === 127 || Boolean(error.signal);
        resolve({ verdict: missing ? 'NECITIT' : 'picat', output: '' });
      } else resolve({ verdict: 'verde', output: stdout });
    });
    child.stdin.end();
  });
}

export function request(url, { headers = {}, timeout = 10000 } = {}) {
  return new Promise((resolve, reject) => {
    const client = url.protocol === 'https:' ? https : http;
    let size = 0;
    const chunks = [];
    const req = client.get(url, { headers }, response => {
      response.on('data', chunk => {
        size += chunk.length;
        if (size > LIMIT) req.destroy(new Error('response-limit'));
        else chunks.push(chunk);
      });
      response.on('error', () => { clearTimeout(timer); reject(new Error('response-unreadable')); });
      response.on('end', () => {
        clearTimeout(timer);
        resolve({ status: response.statusCode, body: Buffer.concat(chunks).toString('utf8') });
      });
    });
    const timer = setTimeout(() => req.destroy(new Error('request-timeout')), timeout);
    req.on('error', error => { clearTimeout(timer); reject(new Error(error.message === 'response-limit' ? 'response-limit' : 'request-failed')); });
  });
}

function tcp(target) {
  return new Promise(resolve => {
    const socket = net.createConnection(tcpTarget(target));
    const finish = result => { clearTimeout(timer); socket.destroy(); resolve(result); };
    const timer = setTimeout(() => finish(failed('tcp-timeout')), 5000);
    socket.once('connect', () => finish(green()));
    socket.once('error', () => finish(failed('tcp-unreachable')));
  });
}

// A hostile expression cannot stall the main process or its request deadline.
export function matches(pattern, body) {
  return new Promise(resolve => {
    const worker = new Worker(`const {parentPort,workerData}=require('node:worker_threads'); parentPort.postMessage(new RegExp(workerData.pattern).test(workerData.body));`, {
      eval: true, workerData: { pattern, body }, resourceLimits: { maxOldGenerationSizeMb: 16 },
    });
    let settled = false;
    const finish = result => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      void worker.terminate();
      resolve(result);
    };
    const timer = setTimeout(() => finish(null), 500);
    worker.once('message', finish);
    worker.once('error', () => finish(null));
    worker.once('exit', () => finish(null));
  });
}

export function mounted(source, target) {
  const lines = source.trim().split('\n');
  if (!source.trim() || lines.some(line => !/^\d+ \d+ \d+:\d+ \S+ \S+ .* - \S+ /.test(line))) return unreadable('mount-unreadable');
  const decode = value => value.replace(/\\(040|011|012|134)/g, (_, code) => String.fromCharCode(parseInt(code, 8)));
  return lines.some(line => decode(line.split(' ')[4]) === target) ? green() : failed('mount-absent');
}

function age(timestamp, limit, now) {
  if (!Number.isFinite(timestamp) || timestamp <= 0 || timestamp > now) return unreadable('age-unreadable');
  return now - timestamp < limit ? green() : failed('age-stale');
}

export async function check(c, options = {}) {
  const started = performance.now();
  const env = options.env || process.env;
  const now = options.now ?? Date.now();
  const run = options.command || command;
  const get = options.request || request;
  const io = options.fs || fs;
  const read = operation => filesystem(operation, options.fsTimeout ?? 10000);
  try {
    switch (c.verifica) {
      case 'tcp': return await tcp(c.tinta);
      case 'http': {
        const response = await get(new URL(c.tinta), { timeout: c.astept.body ? 9400 : 10000 });
        if (response.status !== c.astept.status) return failed('http-status');
        if (c.astept.body !== undefined) {
          const match = await matches(c.astept.body, response.body);
          if (match === null) return unreadable('http-pattern');
          if (!match) return failed('http-body');
        }
        if (c.astept.prospetime !== undefined) {
          let body;
          try { body = JSON.parse(response.body); } catch { return unreadable('http-freshness'); }
          if (!body || !validTime(body.la) || Date.parse(body.la) > now) return unreadable('http-freshness');
          if (now - Date.parse(body.la) >= duration(c.astept.prospetime)) return failed('http-stale');
        }
        return green();
      }
      case 'unit':
      case 'age': {
        if (c.verifica === 'age' && !c.tinta.startsWith('unit:')) {
          const stat = await read(() => io.stat(c.tinta));
          return age(stat.mtimeMs, duration(c.prag), now);
        }
        const unit = c.verifica === 'unit' ? c.tinta : c.tinta.slice(5);
        const result = await run([env.VIGIL_SYSTEMCTL || 'systemctl', 'show', unit,
          '--property=LoadState,ActiveState,Result,ExecMainExitTimestamp', '--no-pager'],
        10000, commandEnvironment(env));
        if (result.verdict !== 'verde') return unreadable('unit-unreadable');
        const properties = Object.fromEntries(result.output.trim().split('\n').map(line => {
          const index = line.indexOf('=');
          return [line.slice(0, index), line.slice(index + 1)];
        }));
        if (properties.LoadState !== 'loaded') return unreadable('unit-unknown');
        if (c.verifica === 'unit') {
          if (!['active', 'inactive', 'failed', 'activating', 'deactivating', 'reloading', 'refreshing'].includes(properties.ActiveState)) return unreadable('unit-unreadable');
          return properties.ActiveState === 'active' ? green() : failed('unit-inactive');
        }
        if (properties.Result !== 'success') return unreadable('unit-result');
        return age(Date.parse(properties.ExecMainExitTimestamp), duration(c.prag), now);
      }
      case 'disk': {
        const stat = await read(() => io.statfs(c.tinta));
        if (![stat.blocks, stat.bfree, stat.bavail].every(Number.isFinite) || stat.blocks <= 0
          || stat.bfree < 0 || stat.bfree > stat.blocks || stat.bavail < 0 || stat.bavail > stat.bfree) return unreadable('disk-unreadable');
        const used = stat.blocks - stat.bfree;
        const availableTotal = used + stat.bavail;
        if (availableTotal <= 0) return unreadable('disk-unreadable');
        return used * 100 / availableTotal >= c.prag ? failed('disk-full') : green();
      }
      case 'mount': return mounted(await read(() => io.readFile('/proc/self/mountinfo', 'utf8')), c.tinta);
      case 'cmd': {
        let allow;
        try { allow = JSON.parse(env.VIGIL_CMD_ALLOW || '[]'); } catch { return unreadable('cmd-allow'); }
        if (!Array.isArray(allow) || !allow.includes(c.tinta[0])) return unreadable('cmd-denied');
        const result = await run(c.tinta, 10000, commandEnvironment(env));
        if (result.verdict !== 'verde') return answer(result.verdict, 'cmd-execution');
        return result.output.trim() === c.astept.valoare ? green() : failed('cmd-value');
      }
      case 'hass-state': {
        if (!env.HASS_URL || !env.VIGIL_HASS_TOKEN_FILE) return unreadable('hass-config');
        const token = (await read(() => io.readFile(env.VIGIL_HASS_TOKEN_FILE, 'utf8'))).trim();
        if (!token || /[\r\n]/.test(token)) return unreadable('hass-token');
        const base = new URL(env.HASS_URL);
        if (!['http:', 'https:'].includes(base.protocol) || base.username || base.password) return unreadable('hass-config');
        const remaining = 10000 - (performance.now() - started);
        if (remaining <= 0) return unreadable('hass-timeout');
        const response = await get(new URL(`/api/states/${encodeURIComponent(c.tinta)}`, base), {
          headers: { Authorization: `Bearer ${token}` }, timeout: remaining,
        });
        if (response.status !== 200) return unreadable('hass-response');
        let body;
        try { body = JSON.parse(response.body); } catch { return unreadable('hass-response'); }
        if (!body || typeof body.state !== 'string' || !body.state) return unreadable('hass-state');
        if (['unknown', 'unavailable'].includes(body.state)) return failed('hass-unavailable');
        return body.state === c.astept.valoare ? green() : failed('hass-value');
      }
      default: return unreadable('contract-invalid');
    }
  } catch (error) {
    if (['tcp', 'http'].includes(c.verifica) && error.message === 'request-failed') return failed('network-unreachable');
    return unreadable(`${c.verifica === 'hass-state' ? 'hass' : c.verifica}-unreadable`);
  }
}
