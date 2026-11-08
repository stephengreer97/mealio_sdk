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
| `POST /api/v1/sdk/carts` | SDK | Start a cart for one recipe or several. Returns the first signed envelope |
| `POST /api/v1/sdk/jobs/{job}/step` | SDK | Return results for one envelope. Returns the next envelope |
| `POST /api/v1/sdk/carts/{cart}/add` | SDK | Send the user's choices and start filling the cart |
| `POST /api/v1/sdk/warm` | SDK | Run the login check for the user's store before they tap. Optional |

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

## One recipe or several

`POST /api/v1/sdk/carts` takes `recipe` (one) or `recipes` (1 to 10, unique ids):

```json
{ "store": "heb", "recipes": [
  { "id": "tacos", "title": "Tacos", "ingredients": [{ "name": "1 yellow onion" }] },
  { "id": "pasta", "title": "Pasta", "ingredients": [{ "name": "2 yellow onions", "quantity": 2 }] }
] }
```

Ingredients the recipes share become ONE item, with the quantities added up
(`yellow onion`, quantity 3). The item's `recipes` lists each recipe that calls
for it and its share. The add call does not change: a pick on a shared item is
remembered under every recipe on it, so each recipe brings it back pre-selected
whether it runs alone or with others. When two recipes remember different
products for the same ingredient, the more recently saved one is pre-selected.

SDKs send a single recipe as `recipe`, so they keep working against a server
from before multi-recipe. The `cart.completed` webhook adds `recipeIds`
(`recipeId` is the first).

## Kroger family locations

A Kroger family chain has many stores, and prices and stock differ by store, so
the user says which one they shop at. One is saved per chain.

| Call | Body | Answer |
|---|---|---|
| `POST /api/v1/sdk/locations` | `{ store, zip }` | `{ locations: [{ id, name, address, zip }] }`, that chain's stores, nearest first, at most 10 |
| `POST /api/v1/sdk/preferences` | `{}` | `{ defaultStore, location }` |
| `POST /api/v1/sdk/preferences` | `{ store, locationId? }` | The same, after changing it. `locationId` moves the user to that store |

`POST /api/v1/sdk/carts` for a chain with no saved store answers 409
`location_required`. It writes nothing, and it comes before Kroger's sign-in, so
nobody signs in only to be asked a question. A prepared cart then carries
`cart.location`, and the list shows it with a way to change it.

The drop-in sends no `zip` to prepare. Sent there, it skips the question and
saves the nearest store of that chain, for partners with their own screens.

## Recipe details

A recipe may send `servings` and `makeServings`. Together they scale that
recipe's weights and any `quantity` it set, up to 10 times either way. A line
with no `quantity` stays at one package. Each recipe scales on its own before
ingredients merge.

An ingredient marked `pantry` or `optional` comes back as an item with
`startUnchecked: true`. The SDK does not pre-select it, even with a remembered
product. Merged across recipes, the mark holds only if every recipe set it.

`photoUrl` is for the drop-in and the server ignores it.

## Sheet events

The drop-in reports each step to the partner's `onEvent`, and nothing goes to
Mealio. The names are in `packages/core/src/events.ts`: `sheet_opened`,
`store_picked`, `location_asked`, `signin_shown`, `list_shown`, `item_unchecked`,
`item_checked`, `add_started`, `cart_added`, `error` and `sheet_closed`, which
carries the step the user left from.

## Warm-up

`POST /api/v1/sdk/warm` with `{ "store"?: string }` runs the login check ahead
of the cart, while the user is still reading the recipe. Without `store` it
uses the user's default store. It answers `{ "warm": null }` when there is
nothing to warm (no store on file yet, or Kroger, which signs in through its
API), and otherwise `{ job, envelope }`, driven like any other job. The job
opens the store, runs the session check, parks on the quiet page, and ends
`done` with `{ store, signedIn: true | false | null }`. It never shows sign-in.

The SDK keeps the job id when `signedIn` is true and passes it once, as
`"warm": "<job id>"`, on the next `POST /api/v1/sdk/carts`, but only if:

- the hidden page has not been told to load anything since (`page_open` count unchanged),
- the storage epoch is the same (no sign-out of stores in between),
- the cart is for the same store, or names none, and
- it finished less than 4 minutes ago (the server allows 5).

The server checks the same things it can see: the job is this SDK session's,
for this store, signed in and fresh. Then the prepare's first envelope is the
search alone. If that search gets no answer at all, the prepare starts over
from the session check, so a stale hint costs one search and never a wrong
cart. Any other hint is ignored. While a warm-up runs, every other job waits
for it, because both would drive the same hidden page.

## Products, items and selections

A prepare job's `done.result` is a `PreparedCart` (`packages/core/src/protocol.ts`).
The fields an SDK needs for amounts and prices:

| Object | Field | Meaning |
| --- | --- | --- |
| `CartItem` | `quantity` | Packages to add, from the recipe (every recipe's share added together) |
| `CartItem` | `recipes` | `[{ id, title, quantity }]`: the recipes that call for it. Absent from older servers |
| `PreparedCart` | `recipes` | `[{ id, title }]`: the recipes the cart was made from, in the order sent |
| `CartItem` | `weightLb` | The recipe's own weight for the line in lb, when it gave the amount in lb, oz, g or kg. Absent otherwise |
| `Product` | `unitPrice` | One unit's price as a number, for an estimate |
| `Product` | `estimated` | The price is an estimate (weighed or "Avg." items) |
| `Product` | `maxQuantity` | The store's per-order cap, or null |
| `Product` | `soldByWeight` | Bought by weight (deli, meat and fish counters). Use a weight, not a count |
| `Product` | `weightOptions` | The weights in lb the store sells it in, ascending. Absent when it lists none |
| `Product` | `pricePerLb` | Price per lb for a weight item priced by the pound. Null for one priced as a package. Absent on count items |

`POST /api/v1/sdk/carts/{cart}/add` takes `{ "selections": Selection[] }`:

```json
{ "key": "deli turkey", "productId": "30", "quantity": 1, "weightLb": 1.25, "remember": true, "preferenceId": null }
```

- `productId: null` leaves the item out of this run. Its remembered choice stays.
- `quantity` is a count, 1 to 99, clamped to the store's cap.
- `weightLb` is the pounds for a `soldByWeight` product: a JSON number above 0
  and at most 20, or the server answers 400 `bad_weight`. It is ignored for a
  product that is not sold by weight.

**What the SDK sends for a weight item.** `weightLb` is the user's weight,
else the item's `weightLb`, else the first `weightOption`, else 0.25. The user
steps through `weightOptions` when there are some, else in 0.25 lb steps from
0.25 to 20. A weight is always snapped to a weight the product sells. The
estimate is `pricePerLb × weightLb`, or the package `unitPrice` once when
`pricePerLb` is null, and is always marked estimated.

**What the server does with it.** The server snaps `weightLb` up to the next
`weightOption` (or the largest one), then:

| Store | Weight selection |
| --- | --- |
| H-E-B | Written by weight (`weight` on `addItemToCartV2`), on top of what the line already holds |
| Albertsons family | Written as `qty: 1, selectedWeight: "1.25"`, on top of what the line holds, capped at the product's max |
| Every other store, and the Kroger family | Not written. The item comes back in `failed` with reason `weight_not_supported` |

A weight line is verified by its weight: it is `added` only when the cart
holds a weight line of the product of at least `weightLb`, and the added entry
carries `weightLb`. A weight item retried after the first read is written only
if the cart holds no line of it, so its pounds are never added twice.

## The add result

An add job's `done.result` is an `AddResult` (`packages/core/src/protocol.ts`):
`added`, `skipped`, `failed`, `storeCartUrl`, and `verified` (true when a cart
read after the write confirmed every added item).

Each `added` entry is an `AddedItem`. `key`, `productId`, `name` and
`quantity` are always there. The rest is for the finished-run screen and comes
from the product the prepare or search step already offered: the server does
not search again. Each is present only when known, and absent from servers
older than these fields, so an SDK falls back to the product it selected.

| Field | Meaning |
| --- | --- |
| `weightLb` | Set on an item added by weight: the pounds asked for |
| `imageUrl` | The product's image |
| `ingredient` | The recipe line it was added for, as the partner wrote it |
| `unitPrice` | One unit's price. On a weight item priced as a package, the package price |
| `pricePerLb` | Price per lb, for a weight item priced by the pound |
| `estimated` | The price is the store's estimate (weighed or "Avg." items) |

A line's price is `pricePerLb × weightLb` for a weight item (else its
`unitPrice` once), otherwise `unitPrice × quantity`.

## Totals

**No partial totals.** If even one counted item has no price, there is no
total: the SDK shows no number ("Prices at checkout"), never a sum of the
items it could price. This holds for the list's estimate (the selected items)
and the finished-run total (the added items). A weight item with a
`pricePerLb`, or a package `unitPrice`, counts as priced. Per-row prices still
show where they are known. In core, `CartSession.estimate()` and
`CartSession.addedTotal(result)` return `total: null` whenever `unpriced` is
above 0.

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
place[-_]?order
submit[-_]?order
order[-_]?confirm
gift-?card
/account/(delete|close|security|password)
/addresses?/(add|edit|delete|new)
/orders?/(submit|place)(/|\?|$)
/cart/confirm
/purchase(/|\?|$)
```

The bundled allowlist is in `packages/core/src/allowlist.ts` (`STORES`). The
server may widen a store's `hosts` with a signed envelope of
`"kind": "allowlist"` returned by `hello`. It can only add hosts that share a
registrable domain with a host already listed for that store, and it can
never touch `BLOCKED_PATTERNS`.

## Guard script

`GUARD_SCRIPT` (in `packages/core/src/guard.ts`) is injected before every
server script. It wraps `window.fetch`, `XMLHttpRequest` and
`navigator.sendBeacon` in the page so a request whose URL matches
`BLOCKED_PATTERNS`, or whose body is a blocked operation, throws (or, for a
beacon, returns false) instead of leaving the device. It also caps requests at
240 per minute per page. This is defense in depth. The signature is the
primary control.

A body is a blocked operation when any of these match
`BLOCKED_GRAPHQL_OPERATION` (case-insensitive): its `operationName` (JSON,
single or batched, or form-encoded), the declared name of any `mutation` in
its `query`, or any root field of any mutation. A root field sits directly in
the mutation's top selection set, or inside an inline fragment or a fragment
spread at that level (spreads followed through other spreads). Aliases are
looked through (`a: placeOrder` counts as `placeOrder`). Nested fields,
arguments, variables and directives are never tested, so an add that reads
back `maxPurchaseQuantity` or `checkoutUrl` is allowed. Strings, block strings
(with `\"""` escapes) and comments are stripped before parsing.

```
check_?out|place_?order|submit_?order|confirm_?order|create_?order|purchase|payment
```

A GraphQL multipart upload's `operations` field is judged as a JSON body, whether the body is FormData or raw multipart text, and whatever the part name's quoting (`name="operations"`, `name='operations'` or bare). A leading byte order mark is ignored. Every SDK reads JSON exactly as `JSON.parse` does: any nesting depth, ASCII hex digits only in `\u` escapes, lone surrogates accepted. The cases are in `protocol/test-vectors.json` (`blockedBodies` and `jsonBodies`).

The guard is injected at document start into every frame where the platform allows it: iOS (`WKUserScript`, all frames), Android (`addDocumentStartJavaScript`, on WebViews that support it) and React Native on iOS. Elsewhere, and as a second layer everywhere, it installs itself into same-origin frames through DOM hooks. It also refuses `blob:` and `data:` workers.
A body that cannot be read, such as a stream, is allowed, but its path is
still checked.

`Request`, `Blob`, `ArrayBuffer`,
`URLSearchParams` and `FormData` bodies are read before the check. A beacon
cannot wait for a body to be read, so a beacon whose body is not text is
refused. The cases every SDK must agree on are in `protocol/test-vectors.json`
(`blockedBodies`), and `node protocol/check-rails.mjs` confirms none of the
rails' own paths or operations are blocked.

## Rate caps

SDKs cap `fetch` instructions at 120 per minute per store, and refuse
envelopes with more than 64 instructions.

## Keys

| kid | Ed25519 public key (base64, raw 32 bytes) |
| --- | --- |
| `k1` | see `packages/core/src/keys.ts` |

Rotating a key means shipping the new public key in an SDK release first,
then switching the server's `kid`.

## One job at a time

Every job that drives the hidden page (prepare, search, add and warm) runs
through one queue in the client, so no two jobs ever overlap on the page. A
page load or script result belongs to the job that asked for it.

Every wait is bounded. Each HTTP request to Mealio, and each call to the
partner's session function, times out after 30 seconds (`network` or
`session_failed`). A host that never answers an instruction is cut off 5
seconds after that instruction's own timeout.

A prepare or search can be cancelled, for example when the user closes the
sheet. It stops after the current step, sends nothing more, never shows
sign-in, and frees the queue. An add cannot be cancelled once it starts, so
the drop-in cannot be closed while adding. A second add on the same cart
returns the first one's result.

## Users

`setUser(id)` (React Native: the provider's `userId` prop) tells the SDK who
is signed in. When the id changes, the SDK cancels any prepare or search,
forgets the session, and if a user was signed in before, signs out of the
stores. While the id is null nobody is signed in: no session is requested,
warm-ups do nothing, and the drop-in button calls `onSignInRequired`.
`resetSession()` forgets the session alone.

## Warnings

A prepared cart may carry `warnings: [{ code, message }]`. The SDK exposes
them as `cart.warnings` and logs them in debug builds.

| code | meaning |
| --- | --- |
| `ingredients_dropped` | A recipe had more than 60 ingredients. Only the first 60 were used |
| `lines_dropped` | The cart had more than 100 items. Only the first 100 were used |
| `servings_ignored` | `makeServings` was sent without `servings`, so nothing scaled |

## Errors the SDK raises to the app

| code | meaning |
| --- | --- |
| `bad_envelope` | Signature, expiry, job or sequence check failed |
| `blocked` | An instruction broke the allowlist |
| `store_unavailable` | The server says the store cannot be reached now |
| `login_cancelled` | The user closed the login sheet |
| `session_expired` | Mealio refused the session twice in a row |
| `session_failed` | The partner's session function threw or timed out. The message is the partner's own |
| `not_signed_in` | A cart was started while `userId` is null |
| `cancelled` | The job was cancelled, for example by closing the sheet or a user change |
| `cart_expired` | The prepared cart is too old to add. Prepare it again |
| `too_many_searches` | This cart reached its search limit |
| `network` | Could not reach Mealio |
| `unsupported` | An instruction `op` this SDK does not know |
| `cart_cap_reached` | The app reached the monthly cap set in its dashboard. The drop-in shows `capReached` |
| `too_many_carts` | This user started too many carts. The drop-in shows `tooManyCarts` |
| `store_not_allowed` | The app's dashboard limit leaves out that store. The drop-in shows the picker |
| `location_required` | A Kroger family store with no store chosen yet. The drop-in asks the user |
| `bad_weight` | A selection's `weightLb` was not a number above 0 and at most 20 |
