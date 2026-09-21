#!/usr/bin/env node
import fs from 'node:fs';
import path from 'node:path';
import os from 'node:os';
import { createHash, randomUUID } from 'node:crypto';
import { spawn } from 'node:child_process';
import { pathToFileURL } from 'node:url';
import { contract } from './lib/schema.mjs';
import { check } from './lib/checks.mjs';
import { advance } from './lib/incident.mjs';
import { DAY, atomicWrite, iso, remove, namedPath, stateRoot, statePath } from './lib/common.mjs';
import { loadStore, saveStore, cleanup, ackIdentity, projectOutbox, expireHistory, drain } from './lib/store.mjs';
import { say } from './vigil-say.mjs';

export function loadContracts(directories) {
  const entries = [];
  for (const directory of directories) {
    // Enumeration failure is an inventory fault: the number of present files
    // is unknown, so --expect cannot be verified. Do not fabricate a contract.
    // main returns 3; systemd reports self-failure and leaves the tick stale.
    for (const name of fs.readdirSync(directory).filter(name => name.endsWith('.toml')).sort()) {
      const file = path.resolve(directory, name);
      try {
        const stat = fs.statSync(file); // Follow agenix symlinks, not Dirent.isFile().
        if (!stat.isFile() || stat.size > 65536) throw new Error('contract-invalid');
        entries.push({ contract: contract(fs.readFileSync(file, 'utf8')) });
      } catch (error) {
        entries.push({ contract: {
          nume: `invalid-${createHash('sha256').update(file).digest('hex').slice(0, 16)}`,
          verifica: 'invalid', picat_dupa: 2, nivel: 'nota',
        }, invalid: error.message === 'recuperare: plan 2' ? error.message : 'contract-invalid' });
      }
    }
  }
  return entries;
}

export function invokeSay(args, event, env, timeout = 10000) {
  return new Promise(resolve => {
    if (!env.VIGIL_BIN || !path.isAbsolute(env.VIGIL_BIN)) { resolve(1); return; }
    const child = spawn(env.VIGIL_BIN, ['say', ...args], { env, stdio: ['pipe', 'ignore', 'ignore'] });
    const timer = setTimeout(() => child.kill('SIGKILL'), Math.max(1, timeout));
    child.once('error', () => { clearTimeout(timer); resolve(1); });
    child.once('close', code => { clearTimeout(timer); resolve(code === 0 ? 0 : 1); });
    child.stdin.on('error', () => { /* EPIPE is reflected in the child exit status. */ });
    child.stdin.end(event ? JSON.stringify(event) : undefined);
  });
}

async function mapChecks(entries, inspect) {
  const results = new Array(entries.length);
  let cursor = 0;
  await Promise.all(Array.from({ length: Math.min(4, entries.length) }, async () => {
    while (cursor < entries.length) {
      const index = cursor++;
      const entry = entries[index];
      results[index] = entry.invalid ? { verdict: 'NECITIT', motiv: entry.invalid } : await inspect(entry.contract);
    }
  }));
  return results;
}

export async function run(entries, options = {}) {
  const env = options.env || process.env;
  const root = stateRoot(env);
  const clock = options.clock || Date.now;
  const gazda = options.gazda || os.hostname();
  const boundary = options.boundary || (() => {});
  const enabled = env.VIGIL_SAY !== '0';
  const output = options.output || (line => process.stdout.write(`${line}\n`));
  const summary = options.summary || (line => process.stderr.write(`${line}\n`));
  const names = entries.map(entry => entry.contract.nume);
  if (new Set(names).size !== names.length) throw new Error('duplicate-name');
  if (options.expect !== undefined && options.expect !== entries.length) throw new Error('contract-count');
  // Private runtime contracts cannot be inspected by the Nix prerequisite gate.
  // Preserve explicit row-only mode, but never hide its notification consequence.
  if (!enabled && entries.some(({ contract: c }) => c.nivel === 'incident' || c.nume === 'channel')) {
    summary('vigil-check: WARNING delivery-disabled for incident/channel contracts');
  }
  const store = loadStore(root);
  cleanup(root, store);

  if (enabled) {
    let due = true;
    try {
      const age = clock() - fs.statSync(statePath(root, 'last-chataction')).mtimeMs;
      due = age < 0 || age >= DAY;
    } catch (error) { if (error.code !== 'ENOENT') throw new Error('channel-state-unreadable'); }
    if (due) await (options.probe || (() => invokeSay(['--chataction'], null, env)))();
  }
  const results = await mapChecks(entries, options.inspect || (c => check(c, { env, now: clock() })));
  const now = clock();
  const events = [];
  const counts = { verde: 0, picat: 0, necitit: 0 };
  const unknownIdentities = entries.some(entry => entry.invalid);
  for (const name of Object.keys(store.contracts)) {
    if (!names.includes(name)) {
      if (unknownIdentities && !name.startsWith('invalid-')) {
        // A synthetic invalid-file name cannot prove the old contract was removed.
        // Preserve its episode, but an unobserved interval cannot count as recovery.
        Object.assign(store.contracts[name], { verdict: 'NECITIT', consecutive: 1, greenSince: null });
        const ack = ackIdentity(root, name);
        if (ack !== null) {
          // The known identity can still acknowledge its old nota while its
          // contract is unreadable. Commit cleanup with the preserved episode.
          Object.assign(store.contracts[name], { nota: null, notaDelivered: false });
          store.queue = store.queue.filter(event => event.nume !== name || event.tranzitie !== 'nota');
          store.cleanup.push({ name, marker: true, ack });
        }
        continue;
      }
      // Synthetic names identify files even when their content cannot be read.
      delete store.contracts[name];
      store.queue = store.queue.filter(event => event.nume !== name || event.tranzitie !== 'nota');
      store.cleanup.push({ name, marker: true, ack: null });
    }
  }
  for (let index = 0; index < entries.length; index++) {
    const c = entries[index].contract;
    const result = results[index];
    counts[result.verdict === 'NECITIT' ? 'necitit' : result.verdict]++;
    const ack = ackIdentity(root, c.nume);
    const previous = Object.hasOwn(store.contracts, c.nume) ? store.contracts[c.nume] : undefined;
    if (enabled && previous?.open && !previous.openDelivered
      && !store.queue.some(event => event.nume === c.nume && event.incident_id === previous.open && event.tranzitie === 'open')) {
      events.push({ gazda, nume: c.nume, verdict: 'picat', tranzitie: 'open', nivel: c.nivel,
        event_id: randomUUID(), incident_id: previous.open, occurred_at: previous.open });
    }
    const transition = advance(previous, c, result.verdict, { now, gazda, ack: ack !== null });
    store.contracts[c.nume] = { ...transition.state, nivel: c.nivel };
    if (transition.retireNota) {
      store.queue = store.queue.filter(event => event.nume !== c.nume || event.tranzitie !== 'nota');
      store.cleanup.push({ name: c.nume, marker: true, ack });
    }
    events.push(...transition.events);
    if (enabled && transition.state.nota && !transition.state.notaDelivered
      && !store.queue.some(event => event.nume === c.nume && event.incident_id === transition.state.nota && event.tranzitie === 'nota')
      && !events.some(event => event.nume === c.nume && event.incident_id === transition.state.nota && event.tranzitie === 'nota')) {
      events.push({ gazda, nume: c.nume, verdict: 'NECITIT', tranzitie: 'nota', nivel: 'nota',
        event_id: randomUUID(), incident_id: transition.state.nota, occurred_at: transition.state.nota });
    }
    output(JSON.stringify({ nume: c.nume, verifica: c.verifica, verdict: result.verdict, motiv: result.motiv, incident: transition.state.open }));
  }

  if (enabled) {
    store.queue.push(...events);
    if (expireHistory(store, now)) summary('vigil-check: history-expired');
  } else store.queue = [];
  saveStore(root, store);
  boundary('transitions-committed');
  cleanup(root, store);
  boundary('cleanup-committed');
  // Persistence faults fail the invocation: alerts are already durable above.
  // Do not publish fresh evidence or acknowledge delivery after a failed row write.
  for (const event of events) await say(event, { env: { ...env, VIGIL_SAY: '0' }, now });
  if (enabled || fs.existsSync(statePath(root, 'outbox'))) projectOutbox(root, store.queue);
  if (enabled) await drain(root, store, options.deliver || ((event, timeout) => invokeSay([], event, env, timeout)), { boundary });

  const stare = counts.necitit || !entries.length ? 'NECITIT'
    : counts.picat || Object.values(store.contracts).some(state => state.open) ? 'picat' : 'verde';
  const completed = iso(clock());
  atomicWrite(statePath(root, 'row.json'), { gazda, stare, la: completed, ...counts });
  atomicWrite(statePath(root, 'tick.counts.json'), { run_id: env.INVOCATION_ID || randomUUID(), la: completed, ...counts });
  boundary('counts-committed');
  remove(namedPath(root, 'nota-sent', 'vigil'));
  summary(`files present=${entries.length} parsed=${entries.filter(entry => !entry.invalid).length} necitit=${counts.necitit}`);
  return counts.necitit || !entries.length ? 2 : counts.picat ? 1 : 0;
}

export async function main(args = process.argv.slice(2)) {
  if (args.length === 1 && args[0] === '--autoproba') return (await import('./autoproba.mjs')).autoproba();
  try {
    const directories = [];
    let expect;
    for (let index = 0; index < args.length; index++) {
      if (args[index] === '--expect') {
        if (expect !== undefined || !/^(0|[1-9][0-9]*)$/.test(args[++index] || '')) throw new Error('check-usage');
        expect = Number(args[index]);
        if (!Number.isSafeInteger(expect)) throw new Error('check-usage');
      } else if (args[index].startsWith('-')) throw new Error('check-usage');
      else directories.push(args[index]);
    }
    if (!directories.length) throw new Error('check-usage');
    return await run(loadContracts(directories), { expect });
  } catch {
    process.stderr.write('vigil-check: internal-fault\n');
    return 3;
  }
}
if (process.argv[1] && import.meta.url === pathToFileURL(process.argv[1]).href) process.exitCode = await main();
