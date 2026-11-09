import type { Json, JsonMessage, Matcher } from './protocol';

/** How deep a message from the page is built. PROTOCOL.md "page_script". */
export const MESSAGE_MAX_DEPTH = 512;

/**
 * JSON.parse with a depth limit: the top container is depth 1, containers
 * down to `maxDepth` are built, and one deeper is kept empty in its place,
 * its contents skipped by bracket and string matching. A 100,000-deep message
 * parses without recursion and can still be stringified and matched (V8
 * parses any depth, but JSON.stringify and other engines overflow the stack).
 * Throws as JSON.parse does on text that is not JSON.
 */
export function parseJson(text: string, maxDepth: number = MESSAGE_MAX_DEPTH): unknown {
  let out = '', last = 0, depth = 0, inString = false;
  for (let i = 0; i < text.length; i += 1) {
    const c = text.charCodeAt(i);
    if (inString) {
      if (c === 0x5c) i += 1; // backslash: skip the escaped character
      else if (c === 0x22) inString = false;
      continue;
    }
    if (c === 0x22) { inString = true; continue; }
    if (c === 0x5b || c === 0x7b) {
      depth += 1;
      if (depth <= maxDepth) continue;
      // Too deep: find where this container closes, and keep it empty.
      const start = i, open = c;
      let d = 1, str = false, j = i + 1;
      for (; j < text.length && d > 0; j += 1) {
        const k = text.charCodeAt(j);
        if (str) { if (k === 0x5c) j += 1; else if (k === 0x22) str = false; continue; }
        if (k === 0x22) str = true;
        else if (k === 0x5b || k === 0x7b) d += 1;
        else if (k === 0x5d || k === 0x7d) d -= 1;
      }
      if (d > 0) break; // never closes: not JSON, and JSON.parse will say so
      out += text.slice(last, start) + (open === 0x5b ? '[]' : '{}');
      last = j;
      i = j - 1;
      depth -= 1;
      continue;
    }
    if (c === 0x5d || c === 0x7d) depth -= 1;
  }
  return JSON.parse(last === 0 ? text : out + text.slice(last));
}

/** Parse one posted message. Anything that is not a JSON object is dropped. */
export function parseMessage(raw: unknown): JsonMessage | null {
  let v: unknown = raw;
  if (typeof raw === 'string') {
    try { v = parseJson(raw); } catch { return null; }
  }
  if (!v || typeof v !== 'object' || Array.isArray(v)) return null;
  return v as JsonMessage;
}

function same(a: Json | undefined, b: Json): boolean {
  if (a === undefined) return false;
  if (a === null || b === null || typeof a !== 'object' || typeof b !== 'object') return a === b;
  return JSON.stringify(a) === JSON.stringify(b);
}

/** PROTOCOL.md "Matcher". */
export function matches(msg: JsonMessage, m: Matcher): boolean {
  if (msg.type !== m.type) return false;
  if (m.eq) for (const k of Object.keys(m.eq)) if (!same(msg[k], m.eq[k])) return false;
  if (m.ne) for (const k of Object.keys(m.ne)) if (same(msg[k], m.ne[k])) return false;
  return true;
}

export function matchesAny(msg: JsonMessage, list: Matcher[]): boolean {
  for (const m of list) if (matches(msg, m)) return true;
  return false;
}
