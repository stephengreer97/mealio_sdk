# Mealio Cart SDK relay protocol, v1

This is the contract between the Mealio server (the brain) and every SDK
(the hands): React Native, iOS, Android and Flutter. Every SDK must behave
exactly as written here. The TypeScript in `packages/core/src` is the
reference implementation.

## The one rule

The server decides every step. The SDK only carries out signed instructions,
on the user's phone, with the user's own store login. The SDK never decides
which product to buy, how many, or what to search for.

## Transport

All calls are HTTPS to `https://mealio.co` (overridable for testing).

| Call | Who | Purpose |
| --- | --- | --- |
| `POST /api/v1/sdk/hello` | SDK | Open a run: report version, platform, ops, storage epoch |
| `POST /api/v1/sdk/carts` | SDK | Start a cart for a recipe. Returns the first signed envelope |
| `POST /api/v1/sdk/jobs/{job}/step` | SDK | Return results for one envelope. Returns the next envelope |
| `POST /api/v1/sdk/carts/{cart}/add` | SDK | Send the user's choices and start filling the cart |

Every SDK call carries:

```
Authorization: Bearer <SDK session token from POST /api/v1/sessions>
X-Mealio-Publishable-Key: <partner app's publishable key>
X-Mealio-SDK: <platform>/<version>          e.g. react-native/0.1.0
X-Mealio-Attestation: <optional App Attest / Play Integrity token>
Content-Type: application/json
```

## Signed envelopes

Every instruction batch from the server arrives in an envelope:

```json
{ "payload": "<a JSON string>", "sig": "<base64 Ed25519 signature>", "kid": "k1" }
```

1. `sig` is an Ed25519 signature over the **UTF-8 bytes of the `payload`
   string exactly as received**. Verify before parsing. Never re-serialize.
2. `kid` picks the public key. SDKs ship the public keys in `KEYS` below and
   refuse any `kid` they do not know.
3. Parse `payload` only after the signature checks out.

Payload:

```json
{
  "v": 1,
  "kind": "instructions",
  "job": "job_8f2c...",
  "seq": 3,
  "exp": 1793548800,
  "store": "heb",
  "instructions": [ ... ]
}
```

The SDK must refuse the envelope (and stop the run with `bad_envelope`) when:

- the signature fails, or `kid` is unknown
- `v` is not a version it supports
- `exp` (unix seconds) is in the past, allowing 120 seconds of clock skew
- `job` is not the job the SDK is running
- `seq` is not exactly one more than the last `seq` it ran for that job
  (the first envelope of a job has `seq` 1)

## Instructions

Instructions in one envelope run **in order**. Each carries an `id`. The SDK
returns one result per instruction, in the same order, then calls `step`.
If an instruction fails, the SDK still returns results for it and skips the
rest of that envelope, marking them `skipped: true`.

### `page_open`

Load a URL in the SDK's **hidden** WebView. The hidden WebView is the store
session: it shares cookies and storage with the login WebView.

```json
{ "op": "page_open", "id": "i1", "url": "https://www.heb.com/robots.txt", "timeoutMs": 15000 }
```

Result: `{ "id": "i1", "ok": true, "finalUrl": "...", "ms": 412 }` or
`{ "id": "i1", "ok": false, "error": "timeout" | "blocked" | "load_failed", "ms": 15000 }`.

### `page_script`

Inject JavaScript into the page the hidden WebView is on, and collect the
JSON messages it posts until one matches `until`, or `timeoutMs` passes.

```json
{
  "op": "page_script", "id": "i2",
  "script": "(function(){ ... })(); true;",
  "until": [ { "type": "HEB_SESSION" } ],
  "timeoutMs": 20000
}
```

- Scripts post messages with `window.ReactNativeWebView.postMessage(JSON.stringify(msg))`.
  Every SDK must define `window.ReactNativeWebView.postMessage` in its WebView
  (React Native's WebView does; native SDKs inject a shim, see `BRIDGE_SHIM`).
- Before the server's script, the SDK injects `GUARD_SCRIPT` (below) once per
  page load.
- Collect every message posted after injection. Messages that are not JSON
  objects are dropped.
- Matcher: `{ "type": string, "eq"?: {field: value}, "ne"?: {field: value} }`.
  A message matches when `msg.type === type`, every `eq` field is strictly
  equal, and every `ne` field is not strictly equal (a missing field is "not
  equal"). The run stops at the first message matching any matcher.

Result:
`{ "id": "i2", "ok": true, "messages": [ ... ], "timedOut": false, "ms": 840 }`.
A timeout is `ok: true, timedOut: true` with whatever messages arrived. The
server decides what a timeout means.

### `show_login`

Show the store's login page to the user in a **visible** sheet, using the same
WebView session. The SDK returns when the user is signed in, closes the
sheet, or `timeoutMs` passes.

```json
{
  "op": "show_login", "id": "i3",
  "url": "https://www.heb.com/my-account/login",
  "title": "Sign in to H-E-B",
  "check": { "script": "...", "intervalMs": 3000 },
  "doneWhen": [ { "type": "HEB_SESSION", "eq": { "loggedIn": true } } ],
  "doneWhenUrl": null,
  "timeoutMs": 600000
}
```

- After every page load in the sheet, and every `check.intervalMs`, the SDK
  injects `GUARD_SCRIPT` then `check.script` into the visible page and
  watches its messages. A message matching `doneWhen` means signed in.
- `doneWhenUrl`, when set, is a regex source. A navigation whose URL matches
  it also means signed in (used by Kroger's OAuth return).
- Navigations the allowlist forbids are cancelled, except to hosts listed in
  the store's `authHosts`.

Result: `{ "id": "i3", "ok": true, "outcome": "signed_in" | "cancelled" | "timeout", "messages": [ ... ], "ms": 41200 }`.

### `fetch`

One HTTP request from the device, with the store's cookies.

```json
{
  "op": "fetch", "id": "i4",
  "request": { "method": "POST", "url": "https://www.heb.com/graphql",
               "headers": { "content-type": "application/json" }, "body": "{...}" },
  "timeoutMs": 12000, "maxBytes": 400000
}
```

Result: `{ "id": "i4", "ok": true, "status": 200, "headers": {...}, "body": "...", "truncated": false, "ms": 312 }`.
`ok` means a response arrived, whatever its status.

### `done` and `fail`

The last instruction of a job.

```json
{ "op": "done", "id": "i9", "result": { ... } }
{ "op": "fail", "id": "i9", "code": "store_unavailable", "message": "H-E-B is not answering right now." }
```

The SDK hands `result` to the app (or raises the failure) and does not call
`step` again for this job.

## Allowlist

The SDK refuses (`error: "blocked"`) any `page_open`, `fetch` or login
navigation whose URL fails these checks. The checks live in the SDK, so the
server cannot turn them off.

1. Scheme is `https`.
2. Host is the store's host, or a subdomain of one of the store's `hosts`, or
   (login only) one of its `authHosts`. `mealio.co` is allowed for login
   returns only.
3. The path and query match none of `BLOCKED_PATTERNS`.

`BLOCKED_PATTERNS` (case-insensitive regex sources, never relaxed remotely):

```
checkout
payment
billing
wallet
place-?order
submit-?order
order-?confirm
gift-?card
/account/(delete|close|security|password)
/addresses?/(add|edit|delete|new)
```

The bundled allowlist is in `packages/core/src/allowlist.ts` (`STORES`). The
server may widen a store's `hosts` with a signed envelope of
`"kind": "allowlist"` returned by `hello`. It can only add hosts that share a
registrable domain with a host already listed for that store, and it can
never touch `BLOCKED_PATTERNS`.

## Guard script

`GUARD_SCRIPT` (in `packages/core/src/guard.ts`) is injected before every
server script. It wraps `window.fetch` and `XMLHttpRequest` in the page so a
request whose URL matches `BLOCKED_PATTERNS`, or whose body names a GraphQL
operation matching `/checkout|placeorder|submitorder|payment/i`, throws
instead of leaving the device. It also caps requests at 240 per minute per
page. This is defense in depth. The signature is the primary control.

## Rate caps

SDKs cap `fetch` instructions at 120 per minute per store, and refuse
envelopes with more than 64 instructions.

## Keys

| kid | Ed25519 public key (base64, raw 32 bytes) |
| --- | --- |
| `k1` | see `packages/core/src/keys.ts` |

Rotating a key means shipping the new public key in an SDK release first,
then switching the server's `kid`.

## Errors the SDK raises to the app

| code | meaning |
| --- | --- |
| `bad_envelope` | Signature, expiry, job or sequence check failed |
| `blocked` | An instruction broke the allowlist |
| `store_unavailable` | The server says the store cannot be reached now |
| `login_cancelled` | The user closed the login sheet |
| `session_expired` | The SDK session token expired; get a new one from your server |
| `network` | Could not reach Mealio |
| `unsupported` | An instruction `op` this SDK does not know |
