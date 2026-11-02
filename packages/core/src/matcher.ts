import type { Json, JsonMessage, Matcher } from './protocol';

/** Parse one posted message. Anything that is not a JSON object is dropped. */
export function parseMessage(raw: unknown): JsonMessage | null {
  let v: unknown = raw;
  if (typeof raw === 'string') {
    try { v = JSON.parse(raw); } catch { return null; }
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
