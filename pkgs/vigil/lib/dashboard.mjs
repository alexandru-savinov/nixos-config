import fs from 'node:fs';
import { NAME, atomicWrite, statePath, validTime, iso } from './common.mjs';
import { HOLD_DOWN } from './incident.mjs';

const verdicts = ['verde', 'picat', 'NECITIT'];
const reasons = new Set(('ok check-unreadable contract-invalid tcp-timeout tcp-unreachable tcp-unreadable network-unreachable '
  + 'mount-unreadable mount-absent age-unreadable age-stale http-status http-pattern http-body http-freshness http-stale http-unreadable '
  + 'unit-unreadable unit-unknown unit-inactive unit-result disk-unreadable disk-full cmd-allow cmd-denied cmd-execution cmd-value cmd-unreadable '
  + 'hass-config hass-token hass-timeout hass-response hass-state hass-unavailable hass-value hass-unreadable').split(' '));
const descriptions = {
  'ok': 'check passed',
  'network-unreachable': 'network request failed',
  'tcp-unreachable': 'TCP listener unreachable',
  'tcp-timeout': 'TCP connection timed out',
  'http-status': 'unexpected HTTP status',
  'http-body': 'HTTP body did not match',
  'http-stale': 'peer timestamp is too old',
  'http-freshness': 'peer timestamp unavailable',
  'age-unreadable': 'success timestamp unavailable',
  'age-stale': 'last success is too old',
  'disk-full': 'disk usage reached the configured limit',
  'mount-absent': 'required mount is absent',
  'unit-inactive': 'service is not active',
  'unit-result': 'successful service completion unavailable',
  'check-unreadable': 'check result unavailable',
};
const exact = (value, keys) => value && typeof value === 'object' && !Array.isArray(value)
  && Object.keys(value).length === keys.length && keys.every(key => Object.hasOwn(value, key));
const nullableTime = value => value === null || validTime(value);

export function publicNames(env) {
  const names = JSON.parse(env.VIGIL_PUBLIC_NAMES || '[]');
  if (!Array.isArray(names) || names.length > 256 || new Set(names).size !== names.length
    || names.some(name => typeof name !== 'string' || !NAME.test(name))) throw new Error('dashboard-invalid');
  return names;
}

// Explicit public-name allowlist and fixed diagnostic vocabulary. Never serialize
// targets, descriptions, credentials, exception text or private runtime contracts.
export function writeDashboard(root, entries, results, store, counts, env) {
  const allowed = new Set(publicNames(env));
  if (!allowed.size) return;
  const checks = Object.create(null);
  entries.forEach(({ contract: c }, index) => {
    if (!allowed.has(c.nume)) return;
    const state = store.contracts[c.nume];
    const pending = store.queue.filter(event => event.nume === c.nume).map(event => event.tranzitie);
    checks[c.nume] = {
      verdict: results[index].verdict,
      reason: reasons.has(results[index].motiv) ? results[index].motiv : 'check-unreadable',
      consecutive: state.consecutive, threshold: c.picat_dupa,
      incident: state.open ? state.verdict === 'verde' ? 'recovering' : 'open' : 'none',
      delivery: env.VIGIL_SAY === '0' ? 'disabled' : pending.length ? 'pending'
        : state.openDelivered || state.notaDelivered ? 'confirmed' : 'none',
      pending,
      green_since: state.greenSince === null ? null : iso(state.greenSince),
      close_not_before: state.open && state.greenSince !== null ? iso(state.greenSince + HOLD_DOWN) : null,
    };
  });
  atomicWrite(statePath(root, 'dashboard.json'), { run_id: counts.run_id, la: counts.la, checks });
}

export function dashboardCheck(root, name, counts, now, env) {
  if (!publicNames(env).includes(name)) return null;
  const file = statePath(root, 'dashboard.json');
  const stat = fs.statSync(file);
  if (!stat.isFile() || stat.size > 262144) throw new Error('dashboard-invalid');
  const source = fs.readFileSync(file, 'utf8');
  if (Buffer.byteLength(source) > 262144) throw new Error('dashboard-invalid');
  const snapshot = JSON.parse(source);
  if (!exact(snapshot, ['run_id', 'la', 'checks']) || !snapshot.checks || typeof snapshot.checks !== 'object'
    || Array.isArray(snapshot.checks) || !Object.hasOwn(snapshot.checks, name)) throw new Error('dashboard-invalid');
  const c = snapshot.checks[name];
  if (!exact(c, ['verdict', 'reason', 'consecutive', 'threshold', 'incident', 'delivery', 'pending', 'green_since', 'close_not_before'])
    || !verdicts.includes(c.verdict) || !reasons.has(c.reason)
    || !Number.isSafeInteger(c.threshold) || c.threshold < 1 || !Number.isSafeInteger(c.consecutive)
    || c.consecutive < 1 || c.consecutive > c.threshold
    || !['none', 'open', 'recovering'].includes(c.incident)
    || !['disabled', 'pending', 'confirmed', 'none'].includes(c.delivery)
    || !Array.isArray(c.pending) || c.pending.length > 1000 || c.pending.some(p => !['open', 'close', 'nota'].includes(p))
    || !nullableTime(c.green_since) || !nullableTime(c.close_not_before)) throw new Error('dashboard-invalid');
  const age = now - Date.parse(counts.la);
  const fresh = age >= 0 && age < 900000 && snapshot.run_id === counts.run_id && snapshot.la === counts.la;
  if (!fresh) return { nume: name, stare: 'NECITIT', detail: 'No fresh complete-run evidence', checked_at: counts.la, fresh: false };
  const stare = c.verdict === 'NECITIT' ? 'NECITIT' : c.verdict === 'picat' || c.incident !== 'none' ? 'picat' : 'verde';
  const detail = stare === 'verde' ? 'ok' : `${c.verdict}: ${descriptions[c.reason] || c.reason.replaceAll('-', ' ')}; samples ${c.consecutive}/${c.threshold}; incident ${c.incident}; delivery ${c.delivery}`
    + `${c.pending.length ? ` (${c.pending.join(',')})` : ''}; checked ${counts.la}`
    + (c.close_not_before ? `; close no earlier than ${c.close_not_before}` : '');
  return { nume: name, stare, detail, checked_at: counts.la, fresh: true, ...c };
}
