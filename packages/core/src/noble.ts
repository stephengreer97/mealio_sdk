// The one place @noble is imported. The published build bundles this file
// (scripts/bundle-noble.mjs) into CommonJS, because @noble/ed25519 is ESM only
// and Jest would otherwise need transformIgnorePatterns to load the SDK.
import * as ed from '@noble/ed25519';
import { sha512 } from '@noble/hashes/sha512';

// React Native has no WebCrypto, so give noble a synchronous sha512.
ed.etc.sha512Sync = (...m: Uint8Array[]) => sha512(ed.etc.concatBytes(...m));

export { ed };
