// After tsc: replace dist/noble.js with a CommonJS bundle of @noble/ed25519
// and @noble/hashes, so the package (and its /testing entry) loads under plain
// Jest with no transformIgnorePatterns. Bigint stays, so target ES2020.
import { buildSync } from 'esbuild';
import path from 'node:path';

const here = path.dirname(new URL(import.meta.url).pathname);
buildSync({
  entryPoints: [path.join(here, '../src/noble.ts')],
  outfile: path.join(here, '../dist/noble.js'),
  bundle: true, format: 'cjs', platform: 'neutral', target: 'es2020', mainFields: ['module', 'main'],
  logLevel: 'warning',
});
