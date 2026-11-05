// Builds protocol/test-vectors.json: envelopes signed with a TEST key (never
// the production key), shared by the TS, Swift, Kotlin and Dart test suites so
// every SDK agrees on what a valid and an invalid envelope look like.
import crypto from 'node:crypto';
import fs from 'node:fs';

const seed = Buffer.alloc(32, 7); // deterministic test key
const pkcs8 = Buffer.concat([Buffer.from('302e020100300506032b657004220420', 'hex'), seed]);
const privateKey = crypto.createPrivateKey({ key: pkcs8, format: 'der', type: 'pkcs8' });
const publicRaw = crypto.createPublicKey(privateKey).export({ format: 'der', type: 'spki' }).subarray(-32).toString('base64');
const sign = (payload) => crypto.sign(null, Buffer.from(payload, 'utf8'), privateKey).toString('base64');

const exp = 4102444800; // 2100-01-01
const ok = JSON.stringify({
  v: 1, kind: 'instructions', job: 'job_test', seq: 1, exp, store: 'heb',
  instructions: [
    { op: 'page_open', id: 'i1', url: 'https://www.heb.com/robots.txt', timeoutMs: 15000 },
    { op: 'page_script', id: 'i2', script: 'window.ReactNativeWebView.postMessage(JSON.stringify({type:"HEB_SESSION",loggedIn:true}));true;', until: [{ type: 'HEB_SESSION' }], timeoutMs: 5000 },
  ],
});
const done = JSON.stringify({ v: 1, kind: 'instructions', job: 'job_test', seq: 2, exp, store: 'heb',
  instructions: [{ op: 'done', id: 'i3', result: { hello: 'café ✓' } }] });
const expired = JSON.stringify({ v: 1, kind: 'instructions', job: 'job_test', seq: 1, exp: 1000, store: 'heb',
  instructions: [{ op: 'done', id: 'i1', result: null }] });
const blocked = JSON.stringify({ v: 1, kind: 'instructions', job: 'job_test', seq: 1, exp, store: 'heb',
  instructions: [{ op: 'page_open', id: 'i1', url: 'https://www.heb.com/checkout/review', timeoutMs: 1000 }] });

const vectors = {
  note: 'Signed with a deterministic TEST key. Never trust this key in production.',
  kid: 'ktest',
  publicKey: publicRaw,
  cases: [
    { name: 'valid_two_instructions', envelope: { payload: ok, sig: sign(ok), kid: 'ktest' }, job: 'job_test', lastSeq: 0, expect: 'ok' },
    { name: 'valid_unicode_done', envelope: { payload: done, sig: sign(done), kid: 'ktest' }, job: 'job_test', lastSeq: 1, expect: 'ok' },
    { name: 'tampered_payload', envelope: { payload: ok.replace('robots.txt', 'robots.txT'), sig: sign(ok), kid: 'ktest' }, job: 'job_test', lastSeq: 0, expect: 'signature' },
    { name: 'unknown_kid', envelope: { payload: ok, sig: sign(ok), kid: 'nope' }, job: 'job_test', lastSeq: 0, expect: 'unknown_kid' },
    { name: 'expired', envelope: { payload: expired, sig: sign(expired), kid: 'ktest' }, job: 'job_test', lastSeq: 0, expect: 'expired' },
    { name: 'wrong_job', envelope: { payload: ok, sig: sign(ok), kid: 'ktest' }, job: 'job_other', lastSeq: 0, expect: 'job' },
    { name: 'wrong_seq', envelope: { payload: ok, sig: sign(ok), kid: 'ktest' }, job: 'job_test', lastSeq: 4, expect: 'seq' },
    { name: 'blocked_url_runs_but_refuses', envelope: { payload: blocked, sig: sign(blocked), kid: 'ktest' }, job: 'job_test', lastSeq: 0, expect: 'ok', firstResultError: 'blocked' },
  ],
  allowlist: [
    { store: 'heb', url: 'https://www.heb.com/robots.txt', use: 'page', ok: true },
    { store: 'heb', url: 'http://www.heb.com/robots.txt', use: 'page', ok: false },
    { store: 'heb', url: 'https://heb.com.evil.io/', use: 'page', ok: false },
    { store: 'heb', url: 'https://www.heb.com/checkout', use: 'page', ok: false },
    { store: 'heb', url: 'https://www.heb.com/cart?step=PAYMENT', use: 'fetch', ok: false },
    { store: 'heb', url: 'https://accounts.google.com/o/oauth2', use: 'login', ok: true },
    { store: 'heb', url: 'https://accounts.google.com/o/oauth2', use: 'page', ok: false },
    { store: 'safeway', url: 'https://www.safeway.com/abs/pub/xapi/search', use: 'fetch', ok: true },
    { store: 'kroger', url: 'https://api.kroger.com/v1/connect/oauth2/authorize', use: 'login', ok: true },
    { store: 'kroger', url: 'https://api.kroger.com/v1/cart', use: 'fetch', ok: false },
    { store: 'nostore', url: 'https://www.heb.com/', use: 'page', ok: false },
    // A URL is read the way a browser reads it, or refused. Each of these went
    // to evil.com while a looser pattern read the host as heb.com.
    { store: 'heb', url: 'https://www.heb.com:x@evil.com/', use: 'page', ok: false },
    { store: 'heb', url: 'https://www.heb.com:443@evil.com/a', use: 'login', ok: false },
    { store: 'heb', url: 'https://evil.com\\.heb.com/', use: 'page', ok: false },
    { store: 'heb', url: 'https://www.heb.com@evil.com/', use: 'fetch', ok: false },
    { store: 'heb', url: 'https://www.heb.com/ robots.txt', use: 'page', ok: false },
    { store: 'heb', url: 'https://www.heb.com:443/robots.txt', use: 'page', ok: true },
    { store: 'heb', url: 'https://WWW.HEB.COM/robots.txt', use: 'page', ok: true },
    // A blocked path is blocked percent-encoded too.
    { store: 'heb', url: 'https://www.heb.com/%63heckout', use: 'page', ok: false },
    { store: 'heb', url: 'https://www.heb.com/search?q=%2525', use: 'page', ok: true },
    // Multi-tenant identity providers: only the store's own tenant, or only the store that uses one.
    { store: 'safeway', url: 'https://albertsons.okta.com/oauth2/v1/authorize', use: 'login', ok: true },
    { store: 'safeway', url: 'https://evil.okta.com/login', use: 'login', ok: false },
    { store: 'heb', url: 'https://albertsons.okta.com/oauth2/v1/authorize', use: 'login', ok: false },
    { store: 'safeway', url: 'https://evil.us.auth0.com/login', use: 'login', ok: false },
    { store: 'wegmans', url: 'https://wegmansb2c.b2clogin.com/x/oauth2', use: 'login', ok: true },
    { store: 'heb', url: 'https://evil.b2clogin.com/x', use: 'login', ok: false },
  ],
  // Request bodies the runner's fetch op and the guard refuse.
  blockedBodies: [
    { body: '{"operationName":"cartItemsV2","variables":{}}', blocked: false },
    { body: '{"operationName":"PlaceOrder","variables":{}}', blocked: true },
    { body: '{"operationName":"place\\u004frder"}', blocked: true },
    { body: '[{"operationName":"cartItemsV2"},{"operationName":"submitOrder"}]', blocked: true },
    { body: '{"query":"mutation PlaceOrder { placeOrder { id } }"}', blocked: true },
    { body: '{"query":"query Search { products { id } }"}', blocked: false },
    { body: 'q=checkout+guide', blocked: false },
    { body: '', blocked: false },
  ],
  matchers: [
    { msg: { type: 'ALB_SESSION', loggedIn: true, early: true }, m: { type: 'ALB_SESSION', ne: { early: true } }, ok: false },
    { msg: { type: 'ALB_SESSION', loggedIn: true }, m: { type: 'ALB_SESSION', ne: { early: true } }, ok: true },
    { msg: { type: 'HEB_SESSION', loggedIn: true }, m: { type: 'HEB_SESSION', eq: { loggedIn: true } }, ok: true },
    { msg: { type: 'HEB_SESSION', loggedIn: false }, m: { type: 'HEB_SESSION', eq: { loggedIn: true } }, ok: false },
    { msg: { type: 'X' }, m: { type: 'Y' }, ok: false },
  ],
};
fs.writeFileSync(new URL('./test-vectors.json', import.meta.url), JSON.stringify(vectors, null, 2) + '\n');
console.log('wrote test-vectors.json, ktest =', publicRaw);
