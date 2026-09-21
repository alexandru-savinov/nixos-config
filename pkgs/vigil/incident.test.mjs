import assert from 'node:assert/strict';
import { test } from 'node:test';
import { advance, HOLD_DOWN } from './lib/incident.mjs';

test('recovery hold is exactly thirty minutes', () => {
  assert.equal(HOLD_DOWN, 30 * 60 * 1000);
});

const contract = { nume: 'fixture', picat_dupa: 2, nivel: 'incident' };
const start = Date.parse('2026-09-20T12:00:00Z');
function harness() {
  let state;
  return (verdict, elapsed, ack = false) => {
    const result = advance(state, contract, verdict, { now: start + elapsed, gazda: 'fixture-host', ack });
    state = result.state;
    return result;
  };
}

test('an incident opens only after consecutive failures and closes after continuous healthy hold', () => {
  const tick = harness();
  assert.equal(tick('picat', 0).events.length, 0);
  assert.equal(tick('verde', 1000).events.length, 0);
  assert.equal(tick('picat', 2000).events.length, 0);
  const opened = tick('picat', 3000);
  assert.equal(opened.events[0].tranzitie, 'open');
  assert.equal(opened.events[0].incident_id, new Date(start + 3000).toISOString());
  assert.equal(tick('picat', 4000).events.length, 0);
  assert.equal(tick('verde', 5000).events.length, 0);
  assert.equal(tick('verde', 6000).events.length, 0);
  assert.equal(tick('verde', 5000 + HOLD_DOWN - 1).events.length, 0);
  const closed = tick('verde', 5000 + HOLD_DOWN);
  assert.equal(closed.events[0].tranzitie, 'close');
  assert.equal(closed.events[0].incident_id, opened.events[0].incident_id);
  assert.equal(closed.state.open, null);
  assert.equal(tick('verde', 6000 + HOLD_DOWN).events.length, 0);
});

test('unreadable periods preserve the open incident and reset the healthy hold', () => {
  const tick = harness();
  tick('picat', 0);
  const opened = tick('picat', 1000);
  tick('verde', 2000);
  tick('NECITIT', HOLD_DOWN);
  assert.equal(tick('verde', HOLD_DOWN + 1000).events.length, 0);
  assert.equal(tick('verde', HOLD_DOWN + 2000).events.length, 0);
  const closed = tick('verde', 2 * HOLD_DOWN + 1000);
  assert.equal(closed.events[0].incident_id, opened.events[0].incident_id);
});

test('NECITIT emits one nota per episode and acknowledgement rearms its threshold', () => {
  const tick = harness();
  assert.equal(tick('NECITIT', 0).events.length, 0);
  const first = tick('NECITIT', 1000);
  assert.equal(first.events[0].tranzitie, 'nota');
  assert.equal(first.events[0].nivel, 'nota');
  assert.equal(tick('NECITIT', 2000).events.length, 0);
  const acknowledged = tick('NECITIT', 3000, true);
  assert.equal(acknowledged.retireNota, true);
  assert.equal(acknowledged.events.length, 0);
  assert.equal(acknowledged.state.nota, null);
  const next = tick('NECITIT', 4000);
  assert.equal(next.events[0].tranzitie, 'nota');
  assert.notEqual(next.events[0].incident_id, first.events[0].incident_id);
  assert.equal(tick('verde', 5000).state.nota, null);
  assert.equal(tick('NECITIT', 6000).events.length, 0);
  assert.equal(tick('NECITIT', 7000).events[0].tranzitie, 'nota');
});

test('acknowledging a failure cannot close it or suppress its opening', () => {
  const tick = harness();
  tick('picat', 0);
  const opened = tick('picat', 1000, true);
  assert.equal(opened.events[0].tranzitie, 'open');
  const acknowledged = tick('picat', 2000, true);
  assert.equal(acknowledged.state.open, opened.state.open);
  assert.equal(acknowledged.events.length, 0);
});

test('transition payload is a closed privacy-safe shape', () => {
  const tick = harness();
  tick('picat', 0);
  const event = tick('picat', 1000).events[0];
  assert.deepEqual(Object.keys(event).sort(), ['gazda', 'nume', 'verdict', 'tranzitie', 'nivel', 'event_id', 'incident_id', 'occurred_at'].sort());
  assert.match(event.event_id, /^[0-9a-f-]{36}$/);
  assert.throws(() => advance(null, contract, 'unknown', { now: start, gazda: 'fixture' }), /incident-verdict/);
});
