# mealio_sdk (Flutter)

Put an **Add to my grocery cart** button in your Flutter recipe app. Your
users fill their own H-E-B, Kroger, Safeway, ALDI or Wegmans cart from your
recipe without leaving your app.

```dart
MealioCartButton(recipe: recipe, store: 'heb')
```

That one widget is the integration. It opens one sheet that signs the user in
to their store, shows every ingredient with their usual picks already checked,
fills the store cart and says what was added. Setup is below.

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

## 2. Configure once, place MealioScope, drop in the button

```dart
import 'package:flutter/material.dart';
import 'package:mealio_sdk/mealio_sdk.dart';

final navigatorKey = GlobalKey<NavigatorState>();

void main() {
  MealioCart.configure(
    publishableKey: 'pk_live_...',
    sessionTokenProvider: () => myApi.fetchMealioSessionToken(),
    theme: const MealioTheme(accent: Color(0xFF0B5FFF)), // optional
  );
  runApp(MaterialApp(
    navigatorKey: navigatorKey,
    builder: (context, child) => MealioScope(navigatorKey: navigatorKey, child: child!),
    home: const RecipePage(),
  ));
}

// On your recipe page. This is the whole integration:
MealioCartButton(
  recipe: const Recipe(
    id: 'r_123',
    title: 'Chicken tacos',
    ingredients: [
      RecipeIngredient(name: 'chicken thighs', amount: 1.5, unit: 'lb'),
      RecipeIngredient(name: 'corn tortillas'),
    ],
  ),
  store: 'heb',              // optional: leave it out to use the user's default store
  onAdded: (result) {},      // optional
)
```

The button opens **one sheet** over your app and runs the whole flow in it:

1. **Loading.** "Checking your H-E-B sign-in", then "Finding your 6 ingredients".
2. **Store sign-in**, only when needed. The store's own page shows inside the
   same sheet. Mealio never sees the password.
3. **The list.** Every ingredient, every time. The user's usual products come
   back already checked. Unchecking leaves an item out of this run only; the
   usual pick stays saved. Each item can be expanded to pick another option,
   pick a variant ("sliced or shaved?"), or search the store for something
   else. A store chip at the top switches stores. The footer shows the
   (estimated) total and "Add 5 items to H-E-B".
4. **Done.** What was added, what could not be, what was left out. The user
   checks out on the store's own site or app when they want; the sheet never
   opens the store cart.

`MealioScope` hosts the hidden WebView that holds the user's store login. Put
it **once**, high enough that it stays mounted while your app runs; the
`MaterialApp.builder` slot is the best place. If it sits below your
`Navigator` instead, you can leave out `navigatorKey`. Without a scope the
sheet shows a `no_scope` error.

### Your own button

```dart
final AddResult? result = await MealioCartFlow.show(context, recipe: recipe, store: 'heb');
```

`null` means nothing was added.

### Theme

`MealioTheme` has `accent`, `onAccent`, `background`, `surface`, `text`,
`muted`, `border`, `radius`, `fontFamily`, `warnBackground` and `warnText`.
Pass it to `MealioCart.configure(theme: ...)` or `MealioScope(theme: ...)`
(the scope wins), or wrap a subtree in `MealioThemeScope`.

## 3. Your own UI (optional)

`CartSession` is the model the sheet uses. It is a `ChangeNotifier`, so a
`ListenableBuilder` rebuilds on every change.

```dart
final session = await MealioCart.instance.prepareCart(
  store: 'heb',
  recipe: recipe,
  onStep: (step, _) => print(step), // connecting, checkingSignIn, signingIn, searching, adding
);

session.items;                       // every recipe line, in order; item.status is
                                     // remembered, choose, rememberedUnavailable or unavailable
session.options(item.key);           // options, plus anything found with search()
session.isSelected(item.key);        // remembered items start selected
session.select(item.key, product.id, preferenceId: 'sliced');
session.deselect(item.key);          // leave out of THIS run; the usual pick is kept
await session.search(item.key, 'minced garlic jar');
session.estimate();                  // total, count, estimated, unpriced
final AddResult result = await session.addToCart();

final stores = await MealioCart.instance.stores(); // id, name, via
```

`MealioCartList(session: session, onAdd: ...)` is the list screen on its own,
for hosting in your own sheet. `MealioCartSheet.show(context, session)` (the
0.1 sheet) still works and now shows the same list.

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
SDK reports to Mealio with its next cart.

## Errors

Every failure is a `MealioException(code, message)`.

| code | meaning |
| --- | --- |
| `bad_envelope` | Signature, expiry, job or sequence check failed |
| `blocked` | An instruction broke the allowlist |
| `store_unavailable` | The server says the store cannot be reached now |
| `login_cancelled` | The user closed the login sheet |
| `store_required` | No store was given and the user has no default store yet (the sheet shows the store picker) |
| `session_expired` | The SDK session token expired; get a new one from your server |
| `network` | Could not reach Mealio |
| `unsupported` | An instruction `op` this SDK does not know |
| `server` | Mealio answered with an error the protocol does not name |
| `no_scope` | No `MealioScope` is mounted |
| `not_configured` | `MealioCart.configure` was not called |
| `unknown_item`, `unknown_product` | `select` got a key or product the cart did not offer |

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
- **Store sign-in.** A visible WebView that shares the hidden WebView's
  cookie store. While a cart flow sheet is open, `WebViewHost.login` (a
  `ValueNotifier<MealioLoginView?>`) hands it to that sheet, which shows it
  inside itself. With no flow open (your own UI on `CartSession`) it is pushed
  as a full-screen route instead. Either way, top-frame navigations the
  allowlist refuses are cancelled.
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
