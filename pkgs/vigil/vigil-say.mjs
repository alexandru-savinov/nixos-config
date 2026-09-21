#!/usr/bin/env node
import https from 'node:https';
import { pathToFileURL } from 'node:url';
import { NAME, atomicWrite, readJson, namedPath, statePath, stateRoot, validTime, iso } from './lib/common.mjs';

const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/;
export function validateEvent(event) {
  const keys = ['gazda', 'nume', 'verdict', 'tranzitie', 'nivel', 'event_id', 'incident_id', 'occurred_at'];
  if (!event || typeof event !== 'object' || Array.isArray(event)
    || Object.keys(event).length !== keys.length
    || !keys.every(key => Object.hasOwn(event, key) && typeof event[key] === 'string' && event[key].length <= 500)
    || !/^[a-zA-Z0-9][a-zA-Z0-9.-]{0,252}$/.test(event.gazda) || !NAME.test(event.nume)
    || !['verde', 'picat', 'NECITIT', 'failed'].includes(event.verdict)
    || !['open', 'close', 'nota'].includes(event.tranzitie) || !['nota', 'incident'].includes(event.nivel)
    || !UUID.test(event.event_id) || !(UUID.test(event.incident_id) || validTime(event.incident_id))
    || !validTime(event.occurred_at)) throw new Error('event-invalid');
  if (event.tranzitie === 'close' && event.verdict !== 'verde'
    || event.tranzitie === 'nota' && (event.verdict !== 'NECITIT' || event.nivel !== 'nota')
    || event.tranzitie === 'open' && !['picat', 'failed'].includes(event.verdict)
    || event.verdict === 'failed' && (event.nume !== 'vigil' || event.nivel !== 'nota')) throw new Error('event-invalid');
  return event;
}

export function telegram(method, data, env = process.env, timeout = 10000, client = https) {
  return new Promise(resolve => {
    if (!/^[0-9]+:[a-zA-Z0-9_-]+$/.test(env.TELEGRAM_BOT_TOKEN || '') || !env.TELEGRAM_CHAT_ID) { resolve(false); return; }
    const body = JSON.stringify({ ...data, chat_id: env.TELEGRAM_CHAT_ID });
    const req = client.request({ hostname: 'api.telegram.org', path: `/bot${env.TELEGRAM_BOT_TOKEN}/${method}`, method: 'POST',
      headers: { 'Content-Type': 'application/json', 'Content-Length': Buffer.byteLength(body) },
    }, response => {
      let source = '';
      response.on('data', chunk => {
        source += chunk.toString('utf8');
        if (Buffer.byteLength(source) > 65536) req.destroy();
      });
      response.on('error', () => finish(false));
      response.on('end', () => {
        let parsed;
        try { parsed = JSON.parse(source); } catch { finish(false); return; }
        finish(response.statusCode === 200 && parsed?.ok === true);
      });
    });
    let settled = false;
    const finish = success => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      resolve(success);
    };
    const timer = setTimeout(() => { req.destroy(); finish(false); }, Math.min(timeout, 10000));
    req.on('error', () => finish(false));
    req.end(body);
  });
}

export async function say(event, { env = process.env, send = telegram, now = Date.now(), timeout = 10000 } = {}) {
  validateEvent(event);
  const root = stateRoot(env);
  const rowPath = namedPath(root, 'rows', `${event.nume}`) + '.json';
  const previous = readJson(rowPath);
  if (!previous || !validTime(previous.la) || Date.parse(previous.la) <= Date.parse(event.occurred_at)) {
    atomicWrite(rowPath, { gazda: event.gazda, nume: event.nume, stare: event.verdict, la: event.occurred_at, event_id: event.event_id });
  }
  if (env.VIGIL_SAY === '0') return 0;
  const marker = namedPath(root, 'nota-sent', event.nume);
  const sent = event.nivel === 'nota' ? readJson(marker) : null;
  if (sent?.verdict === event.verdict && sent?.incident_id === event.incident_id) return 0;
  const text = `${event.occurred_at} ${event.gazda} / ${event.nume}: ${event.verdict} (${event.tranzitie})`;
  if (!await send('sendMessage', { text }, env, timeout)) return 1;
  atomicWrite(statePath(root, 'last-say-ok'), iso(now));
  atomicWrite(statePath(root, 'last-channel-ok'), iso(now));
  if (event.nivel === 'nota') atomicWrite(marker, { verdict: event.verdict, incident_id: event.incident_id });
  return 0;
}

export async function chatAction({ env = process.env, send = telegram, now = Date.now(), timeout = 10000 } = {}) {
  if (env.VIGIL_SAY === '0') return 0;
  if (!await send('sendChatAction', { action: 'typing' }, env, timeout)) return 1;
  const root = stateRoot(env);
  atomicWrite(statePath(root, 'last-channel-ok'), iso(now));
  atomicWrite(statePath(root, 'last-chataction'), iso(now));
  return 0;
}

export async function main(args = process.argv.slice(2)) {
  if (args.length === 1 && args[0] === '--autoproba') return (await import('./autoproba.mjs')).autoproba();
  try {
    if (args.length === 1 && args[0] === '--chataction') return await chatAction();
    if (args.length) throw new Error('say-usage');
    let input = '';
    for await (const chunk of process.stdin) {
      input += chunk;
      if (Buffer.byteLength(input) > 8192) throw new Error('event-invalid');
    }
    return await say(JSON.parse(input));
  } catch {
    process.stderr.write('vigil-say: event-or-state-invalid\n');
    return 2;
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) process.exitCode = await main();
