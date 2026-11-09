# Mealio Cart SDK

Put an **Add to my grocery cart** button in your recipe app. Your users fill
their own H-E-B, Kroger, Safeway, ALDI or Wegmans cart from your recipe without
leaving your app.

Docs: https://developers.mealio.co

## How it works

The brain lives on Mealio's server. The hands live on the phone.

```
Partner app ──prepareCart()──> SDK ──signed steps / raw answers──> Mealio relay
                                │                                    (search, choice, memory)
                                └── requests with the user's own store login ──> grocery store
```

The SDK verifies every instruction's Ed25519 signature, checks every URL
against an allowlist built into the SDK (checkout and payment are always
blocked), runs it in a hidden WebView signed in to the user's store, and sends
back what the store answered. See [PROTOCOL.md](PROTOCOL.md).

## Install

| Platform | Install |
| --- | --- |
| React Native | `npm install @mealio/react-native-cart react-native-webview` |
| iOS (Swift Package Manager) | `.package(url: "https://github.com/stephengreer97/mealio_sdk.git", from: "0.6.1")` |
| iOS (CocoaPods) | `pod 'MealioSDK', :git => 'https://github.com/stephengreer97/mealio_sdk.git', :tag => 'v0.6.1'` (installed from GitHub: CocoaPods Trunk stops taking releases on 2026-12-02) |
| Android | `implementation("co.mealio:mealio-sdk:0.6.1")`, plus `co.mealio:mealio-sdk-compose:0.6.1` for the Compose sheet |
| Flutter | `flutter pub add mealio_sdk` |

Use of the SDK is subject to the [Mealio Cart SDK License](LICENSE).

## Integrate with an AI agent

[`skills/mealio-integrate/SKILL.md`](skills/mealio-integrate/SKILL.md) walks any
coding agent through adding Mealio to an app: it studies the app, asks a few
design questions, writes a plan, then builds it. See
https://developers.mealio.co/docs/skill.

When the public API changes, update the skill too. `node scripts/check-skill.mjs`
fails if the skill names something the SDK lacks, or the SDK offers something the
skill does not teach. The site serves a copy: run
`scripts/sync-developer-skill.sh` in mealio_central after editing it. A release
fails if the two differ.

## Releasing

Bump every version together (`node scripts/check-versions.mjs` must pass),
merge, then push a tag `vX.Y.Z`. `.github/workflows/release.yml` runs the full
suite and publishes npm, Maven Central and pub.dev; Swift Package Manager and
CocoaPods (from git) read the tag directly.

## Packages

| Path | What |
| --- | --- |
| `packages/core` | TypeScript reference: protocol types, signature checks, allowlist, guard script, relay loop, client |
| `packages/react-native` | `@mealio/react-native-cart`: `MealioProvider`, `useMealio`, `MealioCartSheet` |
| `ios/` | Swift Package `MealioSDK` |
| `android/` | Kotlin library `co.mealio.sdk` (+ optional Compose sheet) |
| `flutter/` | Dart package `mealio_sdk` |
| `protocol/test-vectors.json` | Signed vectors every SDK's tests must pass (test key, never trusted in production) |
| `examples/` | A partner server (one endpoint) and a React Native example app |

## Quickstart (React Native)

1. Get keys at https://developers.mealio.co/dashboard.
   To offer "sign out of stores", also install
   `@preeternal/react-native-cookie-manager` (or, on the old architecture,
   `@react-native-cookies/cookies`). React Native cannot delete WebView cookies
   without one, and `signOutOfAllStores()` throws `unsupported` rather than pretend.
2. Add one endpoint to your server that calls `POST https://mealio.co/api/v1/sessions`
   with your secret key and your user id (see `examples/partner-server`).
3. Wrap your app:

```tsx
<MealioProvider publishableKey="pk_test_..." getSessionToken={fetchFromYourServer}>
  <App />
</MealioProvider>
```

4. Fill a cart:

```ts
const cart = await useMealio().prepareCart({ store: 'heb', recipe: { id, title, ingredients } });
cart.choose(cart.needsChoice[0].key, cart.needsChoice[0].options![0].id);
const result = await cart.addToCart();
```

## Development

```
npm install
npm test            # core tests, including the shared vectors
npm run typecheck
node protocol/make-vectors.mjs   # regenerate test vectors (test key only)
```
