# mealio_sdk (Flutter)

Put an **Add to my grocery cart** button in your Flutter recipe app. Your
users fill their own H-E-B, Kroger, Safeway, ALDI or Wegmans cart from your
recipe without leaving your app.

The brain lives on Mealio's server. The hands live on the phone. Mealio sends
signed instructions; this package checks each signature, checks every URL
against an allowlist built into the SDK (checkout and payment are always
blocked), runs the instruction in a hidden WebView signed in to the user's
store, and sends back what the store answered. It never decides anything by
itself. See [PROTOCOL.md](../PROTOCOL.md).

## Install

```yaml
dependencies:
  mealio_sdk:
    git:
      url: https://github.com/mealio/mealio-sdk.git
      path: flutter
```

Requirements: Dart 3.3+, Flutter 3.19+, Android minSdk 21+, iOS 12+.

Android: make sure your release manifest has
`<uses-permission android:name="android.permission.INTERNET" />` (Flutter
only adds it to the debug manifest by default).

## 1. Server side: one endpoint

Your app never holds your Mealio secret key. Add one endpoint to your server
that calls `POST https://mealio.co/api/v1/sessions` with your **secret key**
and your user's id, and returns the SDK session token it gets back. See
`examples/partner-server` in this repo.

The SDK calls your `sessionTokenProvider` when it needs a token, and calls it
once more if Mealio answers 401.

## 2. Configure once, and place MealioScope

`MealioScope` hosts the hidden WebView that holds the user's store login. Put
it **once**, high enough that it stays mounted while your app runs. The
`MaterialApp.builder` slot is the best place: it wraps every route, and passing
the same `navigatorKey` lets the SDK push the store login screen.

```dart
import 'package:flutter/material.dart';
import 'package:mealio_sdk/mealio_sdk.dart';

final navigatorKey = GlobalKey<NavigatorState>();

void main() {
  MealioCart.configure(
    publishableKey: 'pk_live_...',
    sessionTokenProvider: () => myApi.fetchMealioSessionToken(),
  );
  runApp(MaterialApp(
    navigatorKey: navigatorKey,
    builder: (context, child) => MealioScope(navigatorKey: navigatorKey, child: child!),
    home: const RecipePage(),
  ));
}
```

If `MealioScope` sits below your `Navigator` instead (for example inside
`home`), you can leave out `navigatorKey`. Without a scope, `prepareCart`
throws `MealioException('no_scope', ...)`.

## 3. Fill a cart

```dart
try {
  final session = await MealioCart.instance.prepareCart(
    store: 'heb',
    recipe: const Recipe(
      id: 'r_123',
      title: 'Chicken tacos',
      ingredients: [
        RecipeIngredient(name: 'chicken thighs', amount: 1.5, unit: 'lb'),
        RecipeIngredient(name: 'corn tortillas'),
      ],
    ),
  );

  // The ready-made sheet: ready items, products to pick (with preference
  // pickers such as "sliced or shaved?"), unavailable items, Add to cart.
  final result = await MealioCartSheet.show(
    context,
    session,
    onOpenStoreCart: (url) => launchUrl(Uri.parse(url)), // optional, e.g. url_launcher
  );
} on MealioException catch (e) {
  // e.code is one of the codes below.
}
```

`prepareCart` signs the user in to the store first if needed: the SDK shows the
store's own login page full screen and closes it when the user is signed in.

### Your own UI

`CartSession` is all the sheet uses:

```dart
session.ready;        // List<CartItem>, already chosen (picked before, in stock)
session.needsChoice;  // List<CartItem>, each with up to 8 options, best first
session.unavailable;  // List<CartItem>, with a reason

session.choose(item.key, product.id);                         // quantity defaults to the item's
session.choose(item.key, product.id, preferenceId: 'sliced'); // when product.preferences is not empty
session.choose(item.key, product.id, quantity: 2, remember: false);
session.skip(item.key);
session.pending();    // needsChoice items still waiting on the user

final AddResult result = await session.addToCart();
result.added; result.skipped; result.failed; result.storeCartUrl;
```

If your app already has classes named `Recipe` or `Product`, import with a
prefix: `import 'package:mealio_sdk/mealio_sdk.dart' as mealio;`.

## Sign out of stores

```dart
await MealioCart.instance.signOutOfAllStores();
await MealioCart.instance.signOutOfStore('heb');
```

webview_flutter can only clear **all** WebView cookies, not one site's, so
`signOutOfStore` signs the user out of every store (and clears any other
WebView cookies in your app). Both bump a stored store-session epoch that the
SDK reports to Mealio on its next run.

## Errors

Every failure is a `MealioException(code, message)`.

| code | meaning |
| --- | --- |
| `bad_envelope` | Signature, expiry, job or sequence check failed |
| `blocked` | An instruction broke the allowlist |
| `store_unavailable` | The server says the store cannot be reached now |
| `login_cancelled` | The user closed the login sheet |
| `session_expired` | The SDK session token expired; get a new one from your server |
| `network` | Could not reach Mealio |
| `unsupported` | An instruction `op` this SDK does not know |
| `server` | Mealio answered with an error the protocol does not name |
| `no_scope` | No `MealioScope` is mounted |
| `not_configured` | `MealioCart.configure` was not called |
| `unknown_item`, `unknown_product` | `choose` got a key or product the cart did not offer |

## How the Flutter host works

- **Hidden WebView.** `MealioScope` draws a 1x1 WebView at 0.01 opacity in the
  corner. It is not `Offstage` and not `Opacity(0)`: Flutter does not paint
  either, and an unpainted platform view gets throttled or never started.
- **Bridge.** Every Mealio WebView has a JavaScriptChannel named
  `__mealioNativeBridge`. webview_flutter has no document-start script API on
  every platform, so the SDK injects
  `window.__mealioNativePost = function(s){ __mealioNativeBridge.postMessage(s) };`
  plus `BRIDGE_SHIM` at every page start and again before every script. Store
  scripts post with `window.ReactNativeWebView.postMessage`, as on React Native.
- **Login sheet.** A full-screen route with the store page in a visible
  WebView that shares the hidden WebView's cookie store. Top-frame navigations
  the allowlist refuses are cancelled.
- **fetch runs in the page.** `WebViewCookieManager` cannot read cookies, so a
  `fetch` instruction runs inside the hidden page as
  `fetch(url, {credentials: 'include'})` and the response comes back over the
  bridge (truncated to `maxBytes` in JS). The server opens a store page first,
  so the request is same-origin with the store's cookies.

## Development

```
cd flutter
flutter pub get
flutter analyze
flutter test
```

`test/fixtures/test-vectors.json` is a copy of `protocol/test-vectors.json`;
copy it again after running `node protocol/make-vectors.mjs`.
`test/fixtures/guard_script.js` and `bridge_shim.js` are the exact text
`packages/core/src/guard.ts` produces; the tests check the Dart strings
against them byte for byte.
