// Deliberately small grammar. The same accept/reject corpus is used by Nix.
function fail() { throw new Error('contract-invalid'); }
function lineWithoutComment(line) {
  let quoted = false;
  let escaped = false;
  for (let i = 0; i < line.length; i++) {
    const char = line[i];
    if (quoted) {
      if (escaped) escaped = false;
      else if (char === '\\') escaped = true;
      else if (char === '"') quoted = false;
    } else if (char === '#') return line.slice(0, i);
    else if (char === '"') quoted = true;
  }
  if (quoted) fail();
  return line;
}
function parseValue(source) {
  let cursor = 0;
  const space = () => { while (/[ \t]/.test(source[cursor] || '\0')) cursor++; };
  function scalar() {
    space();
    if (source[cursor] === '"') {
      const start = cursor++;
      while (cursor < source.length) {
        const char = source[cursor++];
        if (char === '"') {
          let result;
          try { result = JSON.parse(source.slice(start, cursor)); } catch { fail(); }
          if (/[\u0000-\u001f\u007f]/.test(result)) fail();
          return result;
        }
        if (char === '\\') {
          const escape = source[cursor++];
          if (!['"', '\\', 'u'].includes(escape)) fail();
          if (escape === 'u') {
            if (!/^[0-9a-fA-F]{4}$/.test(source.slice(cursor, cursor + 4))) fail();
            cursor += 4;
          }
        }
      }
      fail();
    }
    const match = /^(?:true|false|[+-]?(?:0|[1-9][0-9]*))/.exec(source.slice(cursor));
    if (!match) fail();
    cursor += match[0].length;
    if (match[0] === 'true') return true;
    if (match[0] === 'false') return false;
    const number = Number(match[0]);
    if (!Number.isSafeInteger(number)) fail();
    return number;
  }
  function value() {
    space();
    if (source[cursor] === '[') {
      cursor++;
      const result = [];
      space();
      while (source[cursor] !== ']') {
        if (source[cursor] !== '"') fail();
        result.push(scalar());
        space();
        if (source[cursor] !== ',') break;
        cursor++;
        space();
      }
      if (source[cursor++] !== ']') fail();
      return result;
    }
    if (source[cursor] === '{') {
      cursor++;
      const result = Object.create(null);
      space();
      while (source[cursor] !== '}') {
        const key = /^[a-zA-Z0-9_-]+/.exec(source.slice(cursor));
        if (!key || Object.hasOwn(result, key[0])) fail();
        cursor += key[0].length;
        space();
        if (source[cursor++] !== '=') fail();
        result[key[0]] = scalar();
        space();
        if (source[cursor] !== ',') break;
        cursor++;
        space();
        if (source[cursor] === '}') fail();
      }
      if (source[cursor++] !== '}') fail();
      return result;
    }
    return scalar();
  }
  const result = value();
  space();
  if (cursor !== source.length) fail();
  return result;
}
export function parseToml(source) {
  if (typeof source !== 'string' || Buffer.byteLength(source) > 65_536) fail();
  const document = Object.create(null);
  let table;
  for (const raw of source.split(/\r?\n/)) {
    const line = lineWithoutComment(raw).trim();
    if (!line) continue;
    const section = /^\[([a-zA-Z0-9_-]+)\]$/.exec(line);
    if (section) {
      if (Object.hasOwn(document, section[1])) fail();
      table = document[section[1]] = Object.create(null);
      continue;
    }
    const assignment = /^([a-zA-Z0-9_-]+)[ \t]*=[ \t]*(.+)$/.exec(line);
    if (!table || !assignment || Object.hasOwn(table, assignment[1])) fail();
    table[assignment[1]] = parseValue(assignment[2]);
  }
  return document;
}
