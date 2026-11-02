import * as ed from '@noble/ed25519';
import { sha512 } from '@noble/hashes/sha512';
import { EXP_SKEW_SECONDS, MAX_INSTRUCTIONS, PROTOCOL_VERSION, SUPPORTED_OPS } from './protocol';
import type { Envelope, InstructionsPayload, Payload } from './protocol';
import { KEYS } from './keys';

// React Native has no WebCrypto, so give noble a synchronous sha512.
ed.etc.sha512Sync = (...m: Uint8Array[]) => sha512(ed.etc.concatBytes(...m));

const B64 = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/';

/** base64 (standard or url-safe, padded or not) to bytes. No atob, for old RN. */
export function base64ToBytes(s: string): Uint8Array {
  const clean = s.replace(/-/g, '+').replace(/_/g, '/').replace(/[^A-Za-z0-9+/]/g, '');
  const out: number[] = [];
  let buf = 0, bits = 0;
  for (const ch of clean) {
    buf = (buf << 6) | B64.indexOf(ch);
    bits += 6;
    if (bits >= 8) { bits -= 8; out.push((buf >> bits) & 0xff); }
  }
  return Uint8Array.from(out);
}

export function utf8(s: string): Uint8Array {
  return new TextEncoder().encode(s);
}

export class EnvelopeError extends Error {
  code = 'bad_envelope' as const;
  constructor(public why: string) { super(`bad_envelope: ${why}`); }
}

/** Check the signature over the payload string as received, then parse it. */
export function openEnvelope(env: Envelope, keys: Record<string, string> = KEYS): Payload {
  if (!env || typeof env.payload !== 'string' || typeof env.sig !== 'string') throw new EnvelopeError('shape');
  const pub = keys[env.kid];
  if (!pub) throw new EnvelopeError('unknown_kid');
  let ok = false;
  try { ok = ed.verify(base64ToBytes(env.sig), utf8(env.payload), base64ToBytes(pub)); } catch { ok = false; }
  if (!ok) throw new EnvelopeError('signature');
  let p: Payload;
  try { p = JSON.parse(env.payload); } catch { throw new EnvelopeError('json'); }
  if (!p || p.v !== PROTOCOL_VERSION) throw new EnvelopeError('version');
  if (typeof p.exp !== 'number' || p.exp + EXP_SKEW_SECONDS < Date.now() / 1000) throw new EnvelopeError('expired');
  return p;
}

/** The job and sequence checks for an instruction envelope. */
export function checkInstructions(p: Payload, job: string | null, lastSeq: number): InstructionsPayload {
  if (p.kind !== 'instructions') throw new EnvelopeError('kind');
  if (job && p.job !== job) throw new EnvelopeError('job');
  if (p.seq !== lastSeq + 1) throw new EnvelopeError('seq');
  if (!Array.isArray(p.instructions) || p.instructions.length === 0) throw new EnvelopeError('empty');
  if (p.instructions.length > MAX_INSTRUCTIONS) throw new EnvelopeError('too_many');
  for (const i of p.instructions) {
    if (!i || typeof i.id !== 'string' || !SUPPORTED_OPS.includes(i.op)) throw new EnvelopeError('unsupported_op');
  }
  return p;
}
