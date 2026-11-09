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
    // Order paths, in every spelling seen.
    { store: 'heb', url: 'https://www.heb.com/place_order', use: 'fetch', ok: false },
    { store: 'heb', url: 'https://www.heb.com/api/order/submit', use: 'fetch', ok: false },
    { store: 'heb', url: 'https://www.heb.com/orders/place?x=1', use: 'fetch', ok: false },
    { store: 'heb', url: 'https://www.heb.com/cart/confirm', use: 'page', ok: false },
    { store: 'heb', url: 'https://www.heb.com/purchase', use: 'fetch', ok: false },
    { store: 'heb', url: 'https://www.heb.com/purchase/review', use: 'fetch', ok: false },
    // Their neighbors that only read stay open.
    { store: 'heb', url: 'https://www.heb.com/orders/placed', use: 'page', ok: true },
    { store: 'heb', url: 'https://www.heb.com/my-account/purchases', use: 'page', ok: true },
    // Paths the store rails use today (lib/cart-relay/stores). None may block.
    { store: 'safeway', url: 'https://www.safeway.com/abs/pub/xapi/pgmsearch/v1/search/products?q=milk', use: 'fetch', ok: true },
    { store: 'safeway', url: 'https://www.safeway.com/abs/pub/erums/cartservice/api/v2/cart/items', use: 'fetch', ok: true },
    { store: 'safeway', url: 'https://www.safeway.com/abs/pub/erums/cartservice/api/v2/cart/customer/', use: 'fetch', ok: true },
    { store: 'wegmans', url: 'https://www.wegmans.com/commerce/cart/carts/lineitems', use: 'fetch', ok: true },
    { store: 'wegmans', url: 'https://www.wegmans.com/commerce/order/orders/activeorders', use: 'fetch', ok: true },
    { store: 'aldi', url: 'https://www.aldi.us/graphql', use: 'fetch', ok: true },
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
    // Any mutation: its name, and its root fields.
    { body: '{"query":"mutation Go { placeOrder(input:{}) { id } }"}', blocked: true },
    { body: '{"query":"mutation { placeOrder { id } }"}', blocked: true },
    { body: '{"query":"mutation($a:ID!){ checkoutComplete(id:$a){id} }"}', blocked: true },
    // 0.6 round 2: a nested field is not a root field, so this one passes now.
    { body: '{"query":"mutation Go { cart { submitOrder { id } } }"}', blocked: false },
    { body: '{"query":"mutation Go { done: place_order { id } }"}', blocked: true },
    { body: '{"query":"mutation Go { ...F } fragment F on Mutation { placeOrder { id } }"}', blocked: true },
    { body: '{"operationName":"place_order"}', blocked: true },
    { body: 'operationName=PlaceOrder&query=mutation+PlaceOrder', blocked: true },
    { body: 'operationName=Search&query=mutation+Go+%7B+placeOrder+%7B+id+%7D+%7D', blocked: true },
    { body: 'mutation { submit_order { id } }', blocked: true },
    // A query may read any field. Arguments, strings, comments and type conditions are not fields.
    { body: '{"query":"query Wallet { me { paymentMethods { id } } }"}', blocked: false },
    { body: '{"query":"mutation Add($p: String!) { addItem(note: \\"checkout\\", purchasePreferenceId: $p) { ... on PaymentError { message } } } # placeOrder"}', blocked: false },
    { body: 'operationName=Search&query=query+Search+%7B+a+%7D', blocked: false },
    // 0.6 round 2. Only operation names and a mutation's ROOT fields count:
    // fields in its top selection set, in inline fragments at that level, and
    // at the top of fragments spread there. Aliases, nested fields, arguments
    // and variables never count.
    { body: JSON.stringify({ query: 'mutation AddToCart($id: ID!) { addItemsToCart(items: [{id: $id}]) { cart { id items { id quantity maxPurchaseQuantity } } } }' }), blocked: false },
    { body: JSON.stringify({ query: 'mutation UpdateCartItems($i: [CartItemInput!]!) { updateCartItems(items: $i) { cart { id itemCount checkoutUrl } } }' }), blocked: false },
    { body: JSON.stringify({ query: 'mutation addToCart { addToCart(sku: "1") { ...Cart } } fragment Cart on Cart { id total paymentMethodRequired }' }), blocked: false },
    { body: JSON.stringify({ query: 'mutation AddItem { addItem(id: 1) { product { id isPurchasable purchaseLimit } } }' }), blocked: false },
    { body: JSON.stringify({ query: 'query Search { search(q: "milk") { ...P } } fragment P on Product { purchaseLimit } mutation Track { track(e: "x") }' }), blocked: false },
    { body: JSON.stringify({ query: 'mutation Add($checkoutId: ID, $purchase: Int) { addItem(checkoutId: $checkoutId, purchase: $purchase) { id } }' }), blocked: false },
    { body: JSON.stringify({ query: 'mutation Add { addItem @include(if: true) { id } placed: addItem(placeOrder: true) { id } }' }), blocked: false },
    { body: JSON.stringify({ query: 'mutation { checkout: addItem { id } }' }), blocked: false },
    { body: JSON.stringify({ query: 'query { placeOrder { id } }' }), blocked: false },
    { body: JSON.stringify({ query: 'mutation { a: placeOrder { id } }' }), blocked: true },
    { body: JSON.stringify({ query: 'mutation { addItem { id } ... on Mutation { placeOrder { id } } }' }), blocked: true },
    { body: JSON.stringify({ query: 'mutation { ... @include(if: true) { ... on Mutation { checkout { id } } } }' }), blocked: true },
    { body: JSON.stringify({ query: 'mutation M { addItem { id } ...F } fragment F on Mutation { ...G } fragment G on Mutation { checkoutComplete { id } }' }), blocked: true },
    { body: JSON.stringify({ query: 'fragment F on Mutation { submitOrder { id } } mutation M @trace { ...F }' }), blocked: true },
    { body: JSON.stringify({ query: 'mutation PlaceOrder { addItem { id } }' }), blocked: true },
    { body: JSON.stringify({ operationName: 'Checkout', query: 'query Checkout { cart { id } }' }), blocked: true },
    { body: JSON.stringify({ query: 'mutation M { addItem(note: "a") { id } # x\n placeOrder { id } }' }), blocked: true },
    // Strings are not fields, block strings with \""" inside them included.
    { body: JSON.stringify({ query: 'mutation M { addItem(note: """a\\""" b""") { id } placeOrder { id } x: addItem(n: "y") { id } }' }), blocked: true },
    { body: JSON.stringify({ query: 'mutation M { addItem(note: """a\\""" placeOrder { id } """) { id } }' }), blocked: false },
    { body: JSON.stringify({ query: 'mutation M { addItem(note: "a \\" placeOrder { id } \\"") { id } }' }), blocked: false },
    { body: JSON.stringify({ query: 'mutation M { addItem(note: "a \\\\") { id } placeOrder { id } }' }), blocked: true },
    // GraphQL multipart: the guard reads a FormData body's operationName, query
    // and operations fields as this form-encoded text. operations is JSON, one
    // operation or a batch, judged like a JSON body.
    { body: 'operations=' + encodeURIComponent(JSON.stringify({ query: 'mutation { placeOrder(id: 1) { id } }', variables: {} })) + '&map=%7B%7D', blocked: true },
    { body: 'operations=' + encodeURIComponent(JSON.stringify([{ operationName: 'Search' }, { operationName: 'submit_order' }])), blocked: true },
    { body: 'operations=' + encodeURIComponent(JSON.stringify({ query: 'mutation Upload($f: Upload!) { uploadPhoto(file: $f) { id } }', variables: { f: null } })) + '&map=%7B%7D', blocked: false },
    // The store rails' own writes (lib/cart-relay/stores) must pass.
    { body: JSON.stringify({ operationName: 'cartItemV2', variables: {}, query: 'mutation cartItemV2($productId: String!, $skuId: String!, $quantity: Int, $purchasePreferenceId: String) { addItemToCartV2(productId: $productId, skuId: $skuId, quantity: $quantity, purchasePreferenceId: $purchasePreferenceId) { __typename ... on Cart { id } ... on AddOnsCart { id cart { id } } ... on AddItemToCartV2Error { message title code } ... on AddItemToCartV2TimeslotError { message title errorCode: code } } }' }), blocked: false },
    { body: JSON.stringify({ operationName: 'cartItemsV2', variables: {}, query: 'mutation cartItemsV2($p0: String!, $s0: String!, $w0: Float, $r0: String) { a0: addItemToCartV2(productId: $p0, skuId: $s0, weight: $w0, purchasePreferenceId: $r0) { __typename ... on Cart { id } } }' }), blocked: false },
    { body: '{"operationName":"MergeAndGetCart","variables":{}}', blocked: false },
    { body: '{"operationName":"updateItems","variables":{}}', blocked: false },
    // 0.6 round 3. A leading byte order mark is dropped before parsing, as a
    // server's JSON reader does, so it cannot turn a JSON body into "not JSON".
    { body: '﻿' + JSON.stringify({ query: 'mutation { placeOrder { id } }' }), blocked: true },
    { body: '﻿' + JSON.stringify([{ operationName: 'Search' }, { operationName: 'submitOrder' }]), blocked: true },
    { body: '﻿{"operationName":"cartItemsV2","variables":{}}', blocked: false },
    { body: '﻿', blocked: false },
    // Raw multipart/form-data sent as a string: the operations part is judged
    // as JSON, a query part as a document, an operationName part as a name.
    { body: '--b\r\nContent-Disposition: form-data; name="operations"\r\n\r\n' + JSON.stringify({ query: 'mutation { placeOrder { id } }', variables: {} }) + '\r\n--b\r\nContent-Disposition: form-data; name="map"\r\n\r\n{}\r\n--b--\r\n', blocked: true },
    { body: '--b\r\nContent-Disposition: form-data; name="operations"\r\nContent-Type: application/json\r\n\r\n' + JSON.stringify([{ operationName: 'Search' }, { operationName: 'submit_order' }]) + '\r\n--b--', blocked: true },
    { body: '--b\nContent-Disposition: form-data; name="operations"\n\n' + JSON.stringify({ query: 'mutation Go { checkoutComplete { id } }' }) + '\n--b--\n', blocked: true },
    { body: '--b\r\nContent-Disposition: form-data; name="operations"\r\n\r\n﻿' + JSON.stringify({ query: 'mutation { placeOrder { id } }' }), blocked: true },
    { body: '--b\r\nContent-Disposition: form-data; name="query"\r\n\r\nmutation { placeOrder { id } }\r\n--b--', blocked: true },
    { body: '--b\r\nContent-Disposition: form-data; name="operationName"\r\n\r\nPlaceOrder\r\n--b--', blocked: true },
    { body: '--b\r\nContent-Disposition: form-data; name="operations"\r\n\r\n' + JSON.stringify({ query: 'mutation Upload($f: Upload!) { uploadPhoto(file: $f) { id } }', variables: { f: null } }) + '\r\n--b\r\nContent-Disposition: form-data; name="map"\r\n\r\n{"0":["variables.f"]}\r\n--b\r\nContent-Disposition: form-data; name="0"; filename="a.jpg"\r\nContent-Type: image/jpeg\r\n\r\nplaceOrder checkout\r\n--b--\r\n', blocked: false },
    { body: '--b\r\nContent-Disposition: form-data; name="note"\r\n\r\n' + JSON.stringify({ query: 'mutation { placeOrder { id } }' }) + '\r\n--b--', blocked: false },
    // 0.6 round 4. A part's name may be double-quoted, single-quoted or bare.
    { body: '--b\r\nContent-Disposition: form-data; name=operations\r\n\r\n' + JSON.stringify({ query: 'mutation { placeOrder { id } }' }) + '\r\n--b--', blocked: true },
    { body: "--b\r\nContent-Disposition: form-data; name='operations'\r\n\r\n" + JSON.stringify({ query: 'mutation { placeOrder { id } }' }) + '\r\n--b--', blocked: true },
    { body: '--b\r\nContent-Disposition: form-data; name=query\r\n\r\nmutation { placeOrder { id } }\r\n--b--', blocked: true },
    { body: "--b\r\nContent-Disposition: form-data; name='query'\r\n\r\nmutation { placeOrder { id } }\r\n--b--", blocked: true },
    { body: '--b\r\nContent-Disposition: form-data; name=operationName\r\n\r\nPlaceOrder\r\n--b--', blocked: true },
    { body: "--b\r\nContent-Disposition: form-data; name='operationName'\r\n\r\nPlaceOrder\r\n--b--", blocked: true },
    { body: '--b\nContent-Disposition: form-data; name=operations; filename=x\n\n' + JSON.stringify([{ operationName: 'submit_order' }]) + '\n--b--', blocked: true },
    { body: '--b\r\nContent-Disposition: form-data; name=operationsX\r\n\r\n' + JSON.stringify({ query: 'mutation { placeOrder { id } }' }) + '\r\n--b--', blocked: false },
    { body: "--b\r\nContent-Disposition: form-data; name='operationNameX'\r\n\r\nPlaceOrder\r\n--b--", blocked: false },
    { body: '--b\r\nContent-Disposition: form-data; name=operations\r\n\r\n' + JSON.stringify({ query: 'mutation Upload($f: Upload!) { uploadPhoto(file: $f) { id } }' }) + '\r\n--b--', blocked: false },
  ],
  // 0.6 round 4. Every SDK's JSON reader accepts exactly what JSON.parse does,
  // because a body is judged as JSON only when it parses. Kept apart from
  // blockedBodies so each platform's test can name the rule that failed.
  //   depth: nesting JSON.parse reads, so a deep array cannot make a body "not JSON"
  //   hex: a \u escape takes ASCII hex digits only; anything else is not JSON
  //   surrogate: a lone or reversed surrogate escape is still JSON
  // A body that is not JSON is then read as text, where strings are not names.
  jsonBodies: [
    { rule: 'depth', body: '{"x":' + '['.repeat(600) + ']'.repeat(600) + ',"query":"mutation { placeOrder { id } }"}', blocked: true },
    { rule: 'depth', body: '{"x":' + '['.repeat(2000) + ']'.repeat(2000) + ',"query":"mutation { placeOrder { id } }"}', blocked: true },
    { rule: 'depth', body: '[' + '{"a":'.repeat(700) + '1' + '}'.repeat(700) + ',{"query":"mutation { submitOrder { id } }"}]', blocked: true },
    { rule: 'depth', body: '{"x":' + '['.repeat(2000) + ']'.repeat(2000) + ',"query":"query { placeOrder { id } }"}', blocked: false },
    { rule: 'hex', body: '{"operationName":"Search","query":"mutation { \\u0070laceOrder { id } }"}', blocked: true },
    { rule: 'hex', body: '{"operationName":"place\\u٠٠٤Frder"}', blocked: false },
    { rule: 'hex', body: '{"operationName":"place\\u００４Frder"}', blocked: false },
    { rule: 'hex', body: '{"query":"mutation { place\\u٠٠٤Frder { id } }"}', blocked: false },
    { rule: 'hex', body: '{"query":"mutation { place\\u004frder { id } }"}', blocked: true },
    { rule: 'hex', body: '{"query":"mutation { place\\u004Frder { id } }"}', blocked: true },
    { rule: 'surrogate', body: '{"query":"mutation { placeOrder { id } }","x":"\\ud800"}', blocked: true },
    { rule: 'surrogate', body: '{"query":"mutation { placeOrder { id } }","x":"\\udfff"}', blocked: true },
    { rule: 'surrogate', body: '{"query":"mutation { placeOrder { id } }","x":"\\udc00\\ud800"}', blocked: true },
    { rule: 'surrogate', body: '{"query":"mutation { placeOrder { id } }","x":"a\\ud83dz"}', blocked: true },
    { rule: 'surrogate', body: '{"query":"query { a }","x":"\\ud800"}', blocked: false },
    { rule: 'surrogate', body: '{"query":"mutation { placeOrder { id } }","x":"\\ud83d\\ude00"}', blocked: true },
  ],
  // 0.6 round 5. Limits on reading a body, in a compact form: the body is
  // prefix + fill repeated `times` times + suffix.
  //   depth: a body nests inside an `operations` field (form-encoded or a raw
  //     multipart part) at most 8 times and is still read; deeper is blocked.
  //   size: a body longer than 1048576 UTF-16 code units (after a leading BOM
  //     is dropped) is always blocked. Store requests are far smaller, and a
  //     body that size could hide a blocked name in escapes no text match sees.
  bodyLimits: [
    { rule: 'depth', prefix: '', fill: 'operations=', times: 8, suffix: '{"operationName":"Search"}', blocked: false },
    { rule: 'depth', prefix: '', fill: 'operations=', times: 9, suffix: '{"operationName":"Search"}', blocked: true },
    { rule: 'depth', prefix: '', fill: 'operations=', times: 8, suffix: '{"operationName":"PlaceOrder"}', blocked: true },
    { rule: 'depth', prefix: '--b\r\nContent-Disposition: form-data; name=operations\r\n\r\n', fill: 'operations=', times: 7, suffix: '{"operationName":"Search"}\r\n--b--', blocked: false },
    { rule: 'depth', prefix: '--b\r\nContent-Disposition: form-data; name=operations\r\n\r\n', fill: 'operations=', times: 8, suffix: '{"operationName":"Search"}\r\n--b--', blocked: true },
    { rule: 'depth', prefix: '', fill: 'operations=', times: 50000, suffix: '{"operationName":"Search"}', blocked: true },
    { rule: 'size', prefix: '{"operationName":"Search","pad":"', fill: 'a', times: 1048576 - 33 - 19, suffix: '","note":"payment"}', blocked: false },
    { rule: 'size', prefix: '{"operationName":"Search","pad":"', fill: 'a', times: 1048576 - 33 - 19 + 1, suffix: '","note":"payment"}', blocked: true },
    { rule: 'size', prefix: '{"operationName":"Search","pad":"', fill: 'a', times: 1048576 - 33 - 13 + 1, suffix: '","note":"x"}', blocked: true },
    { rule: 'size', prefix: '﻿{"operationName":"Search","pad":"', fill: 'a', times: 1048576 - 33 - 19, suffix: '","note":"payment"}', blocked: false },
    { rule: 'size', prefix: '', fill: 'a', times: 1048577, suffix: '', blocked: true },
    { rule: 'size', prefix: '--b\r\nContent-Disposition: form-data; name=operations\r\n\r\n{"operationName":"Search"}\r\n--b\r\nContent-Disposition: form-data; name="0"\r\n\r\n', fill: 'x\n', times: 600000, suffix: '\r\n--b--', blocked: true },
    { rule: 'size', prefix: '--b\r\nContent-Disposition: form-data; name=operations\r\n\r\n{"query":"mutation { placeOrder { id } }"}\r\n--b\r\nContent-Disposition: form-data; name="0"\r\n\r\n', fill: 'x\n', times: 600000, suffix: '\r\n--b--', blocked: true },
  ],
  // 0.6 round 6. The raw multipart scan (multipartFields in allowlist.ts) is
  // linear in the body. Each body is prefix + fill repeated `times` times +
  // suffix, under BODY_MAX_TEXT, and must be judged in well under a second.
  // A regex scan (MULTIPART_FIELD run as a regex) takes minutes on these: it
  // walks every following line again from every name.
  multipartScan: [
    { prefix: '', fill: 'name=query\n', times: 95000, suffix: '', blocked: false },
    { prefix: '', fill: 'name="query"\r\n', times: 74000, suffix: '', blocked: false },
    { prefix: '', fill: 'name=operations\r', times: 65000, suffix: '', blocked: false },
    { prefix: '', fill: 'name=query ', times: 95000, suffix: '', blocked: false },
    { prefix: '--b\r\nContent-Disposition: form-data; ', fill: 'name=operationName\n', times: 55000, suffix: '\nPlaceOrder\r\n--b--', blocked: true },
    { prefix: '--b\r\nContent-Disposition: form-data; ', fill: 'name=operationName\n', times: 55000, suffix: '\nSearch\r\n--b--', blocked: false },
  ],
  // 0.6 round 5. A message a page posts is parsed with a depth limit of 512.
  // The top container is depth 1. Containers down to depth 512 are built; a
  // container at depth 513 is kept, empty, in its place, and its contents are
  // skipped, never built. So a parsed message is at most 513 deep. The message
  // is prefix + open repeated `times` + close repeated `times` + suffix;
  // `depth` is the nesting depth of the parsed message (an empty container is
  // one level) and `keep` a field that must survive as given.
  deepMessages: [
    { prefix: '{"type":"X","a":', open: '[', close: ']', times: 10, suffix: ',"keep":1}', depth: 11, keep: 1 },
    { prefix: '{"type":"X","a":', open: '[', close: ']', times: 511, suffix: ',"keep":1}', depth: 512, keep: 1 },
    { prefix: '{"type":"X","a":', open: '[', close: ']', times: 512, suffix: ',"keep":1}', depth: 513, keep: 1 },
    { prefix: '{"type":"X","a":', open: '[', close: ']', times: 600, suffix: ',"keep":1}', depth: 513, keep: 1 },
    { prefix: '{"type":"X","a":', open: '[', close: ']', times: 100000, suffix: ',"keep":1}', depth: 513, keep: 1 },
    { prefix: '{"type":"X","a":', open: '{"b":[', close: ']}', times: 50000, suffix: ',"keep":1}', depth: 513, keep: 1 },
    { prefix: '{"type":"X","a":', open: '["]}\\"{[",[', close: ']]', times: 50000, suffix: ',"keep":1}', depth: 513, keep: 1 },
  ],
  matchers: [
    { msg: { type: 'ALB_SESSION', loggedIn: true, early: true }, m: { type: 'ALB_SESSION', ne: { early: true } }, ok: false },
    { msg: { type: 'ALB_SESSION', loggedIn: true }, m: { type: 'ALB_SESSION', ne: { early: true } }, ok: true },
    { msg: { type: 'HEB_SESSION', loggedIn: true }, m: { type: 'HEB_SESSION', eq: { loggedIn: true } }, ok: true },
    { msg: { type: 'HEB_SESSION', loggedIn: false }, m: { type: 'HEB_SESSION', eq: { loggedIn: true } }, ok: false },
    { msg: { type: 'X' }, m: { type: 'Y' }, ok: false },
  ],
};
// A byte order mark is written escaped, so it is visible and no tool strips it.
fs.writeFileSync(new URL('./test-vectors.json', import.meta.url), JSON.stringify(vectors, null, 2).replace(/\uFEFF/g, '\\ufeff') + '\n');
console.log('wrote test-vectors.json, ktest =', publicRaw);
