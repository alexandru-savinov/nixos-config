import { randomUUID } from 'node:crypto';
import { iso } from './common.mjs';

export const HOLD_DOWN = 30 * 60 * 1000;
export function initial() {
  return { verdict: null, consecutive: 0, greenSince: null, open: null, openDelivered: false, nota: null, notaDelivered: false };
}

// Pure transition calculation: the caller commits state and events together.
export function advance(previous, contract, verdict, { now, gazda, ack = false, uuid = randomUUID }) {
  if (!['verde', 'picat', 'NECITIT'].includes(verdict)) throw new Error('incident-verdict');
  const state = { ...(previous || initial()) };
  const events = [];
  const changed = verdict !== state.verdict;
  const retireNota = changed || ack;
  if (retireNota) { state.nota = null; state.notaDelivered = false; }
  state.consecutive = changed || ack && verdict === 'NECITIT'
    ? 1 : Math.min(state.consecutive + 1, contract.picat_dupa);
  state.verdict = verdict;
  if (verdict !== 'verde') state.greenSince = null;
  else if (state.greenSince === null) state.greenSince = now;

  const emit = (tranzitie, nivel, incidentId) => events.push({
    gazda, nume: contract.nume, verdict, tranzitie, nivel,
    event_id: uuid(), incident_id: incidentId, occurred_at: iso(now),
  });
  if (verdict === 'picat' && state.consecutive >= contract.picat_dupa && !state.open) {
    state.open = iso(now);
    state.openDelivered = false;
    emit('open', contract.nivel, state.open);
  } else if (verdict === 'verde' && state.open && state.consecutive >= contract.picat_dupa
    && now - state.greenSince >= HOLD_DOWN) {
    emit('close', contract.nivel, state.open);
    state.open = null;
    state.openDelivered = false;
  } else if (verdict === 'NECITIT' && state.consecutive >= contract.picat_dupa && !state.nota) {
    state.nota = iso(now);
    emit('nota', 'nota', state.nota);
  }
  return { state, events, retireNota };
}
