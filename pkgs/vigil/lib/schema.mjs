import path from 'node:path';
import net from 'node:net';
import { NAME, duration } from './common.mjs';
import { parseToml } from './toml.mjs';

const TYPES = ['tcp', 'http', 'unit', 'age', 'disk', 'mount', 'cmd', 'hass-state'];
const fail = () => { throw new Error('contract-invalid'); };
function keys(object, allowed, required = []) {
  if (!object || typeof object !== 'object' || Array.isArray(object)) fail();
  if (Object.keys(object).some(key => !allowed.includes(key)) || required.some(key => !Object.hasOwn(object, key))) fail();
}
function text(value) { return typeof value === 'string' && value.length > 0 && value.length <= 2048 && !/[\u0000-\u001f\u007f]/.test(value); }
export function tailnetAddress(host) {
  if (net.isIP(host) !== 4) return false;
  const parts = host.split('.').map(Number);
  return parts[0] === 100 && parts[1] >= 64 && parts[1] <= 127;
}
export function tcpTarget(target) {
  const match = /^(\[[0-9a-fA-F:]+\]|[^:\s/]+):([0-9]+)$/.exec(target);
  if (!match || Number(match[2]) < 1 || Number(match[2]) > 65535) fail();
  return { host: match[1].replace(/^\[|\]$/g, ''), port: Number(match[2]) };
}
export function validate(document) {
  if (Object.hasOwn(document, 'recuperare')) throw new Error('recuperare: plan 2');
  keys(document, ['contract', 'spune'], ['contract', 'spune']);
  const c = document.contract;
  keys(c, ['nume', 'ce', 'verifica', 'tinta', 'astept', 'prag', 'picat_dupa', 'peer'], ['nume', 'ce', 'verifica', 'tinta', 'picat_dupa']);
  keys(document.spune, ['nivel'], ['nivel']);
  if (!NAME.test(c.nume) || c.nume === 'vigil' || c.nume.startsWith('invalid-')) fail();
  if (!text(c.ce) || c.ce.length > 200 || !TYPES.includes(c.verifica)) fail();
  if (!Number.isInteger(c.picat_dupa) || c.picat_dupa < 1 || c.picat_dupa > 12) fail();
  if (c.peer !== undefined && typeof c.peer !== 'boolean') fail();
  if (!['nota', 'incident'].includes(document.spune.nivel)) fail();
  let host = '';
  if (c.verifica === 'cmd') {
    if (!Array.isArray(c.tinta) || !c.tinta.length || c.tinta.length > 32 || !c.tinta.every(text) || !path.isAbsolute(c.tinta[0])) fail();
  } else if (!text(c.tinta)) fail();
  if (c.verifica === 'tcp') host = tcpTarget(c.tinta).host;
  if (c.verifica === 'http') {
    let url;
    try { url = new URL(c.tinta); } catch { fail(); }
    if (!['http:', 'https:'].includes(url.protocol) || url.username || url.password) fail();
    host = url.hostname.replace(/^\[|\]$/g, '');
    keys(c.astept, ['status', 'body', 'prospetime'], ['status']);
    if (!Number.isInteger(c.astept.status) || c.astept.status < 100 || c.astept.status > 599) fail();
    if (c.astept.body !== undefined) {
      if (!text(c.astept.body)) fail();
      try { new RegExp(c.astept.body); } catch { fail(); }
    }
    if (c.astept.prospetime !== undefined) duration(c.astept.prospetime);
  } else if (c.verifica === 'cmd') {
    keys(c.astept, ['valoare'], ['valoare']);
    if (!text(c.astept.valoare)) fail();
  } else if (c.verifica === 'hass-state') {
    // Exactly one expectation. `disponibil = true` means "the entity is not
    // unavailable/unknown" and is the ONLY safe shape for a device whose state
    // legitimately cycles (docked → cleaning → returning): a fixed `valoare`
    // would open an incident on every use, i.e. a usage log of the household
    // delivered to Telegram. Only `true` is accepted; `false` is meaningless.
    keys(c.astept, ['valoare', 'disponibil'], []);
    const hasValoare = c.astept.valoare !== undefined, hasDisponibil = c.astept.disponibil !== undefined;
    if (hasValoare === hasDisponibil) fail();
    if (hasValoare && !text(c.astept.valoare)) fail();
    if (hasDisponibil && c.astept.disponibil !== true) fail();
  } else if (c.astept !== undefined) fail();
  if ((tailnetAddress(host) || host.toLowerCase().startsWith('fd7a:115c:a1e0:')) && c.peer !== true) fail();
  if (c.verifica === 'age') {
    if (!(path.isAbsolute(c.tinta) || /^unit:[a-zA-Z0-9@_.:-]+\.service$/.test(c.tinta))) fail();
    duration(c.prag);
  } else if (c.verifica === 'disk') {
    if (!path.isAbsolute(c.tinta) || !Number.isInteger(c.prag) || c.prag < 1 || c.prag > 100) fail();
  } else if (c.prag !== undefined) fail();
  if (c.verifica === 'unit' && !/^[a-zA-Z0-9@_.:-]+\.service$/.test(c.tinta)) fail();
  if (c.verifica === 'mount' && !path.isAbsolute(c.tinta)) fail();
  if (c.verifica === 'hass-state' && (!/^[a-z_][a-z0-9_]*\.[a-z0-9_]+$/.test(c.tinta)
    || /^(person|device_tracker|mobile_app)\./.test(c.tinta))) fail();
  return { ...c, nivel: document.spune.nivel };
}
export function contract(source) { return validate(parseToml(source)); }
