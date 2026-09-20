import fs from 'node:fs';
import { DAY, NAME, atomicWrite, namedPath, readJson, remove, statePath, validTime } from './common.mjs';
import { validateEvent } from '../vigil-say.mjs';

const fail = () => { throw new Error('state-unreadable'); };
export function emptyStore() { return { version: 1, contracts: {}, queue: [], cleanup: [] }; }
export function loadStore(root) {
  const value = readJson(statePath(root, 'incidents.json'), emptyStore());
  if (!value || value.version !== 1 || !value.contracts || Array.isArray(value.contracts)
    || typeof value.contracts !== 'object' || !Array.isArray(value.queue) || !Array.isArray(value.cleanup)) fail();
  for (const [name, state] of Object.entries(value.contracts)) {
    if (!NAME.test(name) || !state || !['verde', 'picat', 'NECITIT'].includes(state.verdict)
      || !Number.isInteger(state.consecutive) || state.consecutive < 1 || state.consecutive > 12
      || !(state.greenSince === null || Number.isFinite(state.greenSince))
      || !(state.open === null || validTime(state.open)) || typeof state.openDelivered !== 'boolean'
      || !(state.nota === null || validTime(state.nota)) || typeof state.notaDelivered !== 'boolean'
      || !['nota', 'incident'].includes(state.nivel)) fail();
  }
  const ids = new Set();
  for (const event of value.queue) {
    validateEvent(event);
    if (ids.has(event.event_id)) fail();
    ids.add(event.event_id);
  }
  for (const item of value.cleanup) {
    if (!item || !NAME.test(item.name) || typeof item.marker !== 'boolean'
      || !(item.ack === null || typeof item.ack === 'string')) fail();
  }
  return value;
}

export function saveStore(root, value) { atomicWrite(statePath(root, 'incidents.json'), value); }

export function ackIdentity(root, name) {
  try {
    const stat = fs.lstatSync(namedPath(root, 'ack', name));
    if (!stat.isFile()) throw new Error('ack-invalid');
    return `${stat.dev}:${stat.ino}:${stat.mtimeMs}:${stat.ctimeMs}`;
  } catch (error) {
    if (error.code === 'ENOENT') return null;
    throw error;
  }
}

// Cleanup intent is persisted with state, so a crash cannot lose an ack rearm.
export function cleanup(root, store) {
  for (const item of store.cleanup) {
    if (item.marker) remove(namedPath(root, 'nota-sent', item.name));
    if (item.ack !== null && ackIdentity(root, item.name) === item.ack) remove(namedPath(root, 'ack', item.name));
  }
  if (store.cleanup.length) {
    store.cleanup = [];
    saveStore(root, store);
  }
}

export function projectOutbox(root, queue) {
  const directory = statePath(root, 'outbox');
  fs.mkdirSync(directory, { recursive: true, mode: 0o750 });
  const expected = new Set(queue.map(event => `${event.event_id}.json`));
  for (const entry of fs.readdirSync(directory)) {
    if (!expected.has(entry)) remove(statePath(root, 'outbox', entry));
  }
  for (const event of queue) atomicWrite(statePath(root, 'outbox', `${event.event_id}.json`), event);
}

export function expireHistory(store, now) {
  const episodes = new Map();
  for (const event of store.queue) {
    const key = `${event.nume}/${event.incident_id}`;
    episodes.set(key, Math.max(episodes.get(key) || 0, Date.parse(event.occurred_at)));
  }
  const before = store.queue.length;
  store.queue = store.queue.filter(event => {
    const state = store.contracts[event.nume];
    if (state?.open === event.incident_id || state?.nota === event.incident_id) return true;
    return now - episodes.get(`${event.nume}/${event.incident_id}`) < DAY;
  });
  return before - store.queue.length;
}

export async function drain(root, store, deliver, { now = () => Date.now(), budget = 60000, boundary = () => {} } = {}) {
  const deadline = now() + budget;
  while (store.queue.length && now() < deadline) {
    const event = store.queue[0];
    const result = await deliver(event, Math.min(10000, deadline - now()));
    if (result !== 0) break;
    boundary('delivered');
    store.queue.shift();
    const state = store.contracts[event.nume];
    if (event.tranzitie === 'open' && state?.open === event.incident_id) state.openDelivered = true;
    if (event.tranzitie === 'nota' && state?.nota === event.incident_id) state.notaDelivered = true;
    saveStore(root, store);
    boundary('delivery-committed');
    projectOutbox(root, store.queue);
  }
}
