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

### Several recipes in one cart

Pass `recipes` instead of `recipe` (at most `maxRecipes`, 10). Ingredients the
recipes share become one item, and a pick is remembered under every recipe
that calls for it. The sheet's header says "3 meals", and each row says which
meals it is for ("For Tacos and Pasta").

```dart
MealioCartButton(recipes: [tacos, pasta, soup], store: 'heb')

// or
await MealioCartFlow.show(context, recipes: [tacos, pasta, soup]);
final session = await MealioCart.instance.prepareCart(recipes: [tacos, pasta, soup]);
session.recipes;                     // [CartRecipe(id, title)], in the order sent
session.recipesFor(item.key);        // [ItemRecipe(id, title, quantity)] for one item
```

More than 10 throws `too_many_recipes` and none throws `bad_recipe`, before
any request. Older servers send neither list; both read as empty.

### Theme

`MealioTheme` has `accent`, `onAccent`, `background`, `surface`, `text`,
`muted`, `border`, `radius`, `fontFamily`, `warnBackground` and `warnText`.
Pass it to `MealioCart.configure(theme: ...)` or `MealioScope(theme: ...)`
(the scope wins), or wrap a subtree in `MealioThemeScope`.

### Look and text

Everything below sits beside `theme`, on `MealioCart.configure`, `MealioScope`
and `MealioThemeScope`. Each setting falls back on its own: scope, then
configure, then the default.

```dart
MealioScope(
  navigatorKey: navigatorKey,
  theme: const MealioTheme(accent: Color(0xFF0B5FFF), radius: 8),
  darkTheme: const MealioTheme.dark(accent: Color(0xFF7FB0FF)),
  colorScheme: MealioColorScheme.auto,
  strings: const {'addToCart': 'Buy the ingredients', 'done': 'All set'},
  formatMoney: (amount) => '${amount.toStringAsFixed(2)} EUR',
  sheet: MealioSheetOptions(
    showTotal: false,
    height: MealioSheetHeight.fraction(0.8),
    logo: const AssetImage('assets/logo.png'),
  ),
  child: child!,
)
```

**Words.** `strings` changes or translates any word the drop-in shows,
accessibility labels and the store settings sheet included. `mealioDefaultStrings`
lists every key. `{store}`-style placeholders are filled in; one that is unknown
stays visible, so a typo shows. Keys ending `_one` and `_other` are the singular
and plural of one message. "Cart by Mealio" does not change.

**Money.** `formatMoney` sets how every price reads. The default is `$12.50`.
With it set, option prices come from the numeric `unitPrice` rather than the
store's own text, which stays when there is no number.

**Dark mode.** `colorScheme` is `light` (the default), `dark`, or `auto`, which
follows the phone, even with the sheet open. `MealioTheme.standardDark` is the
default dark theme. To change it, pass `MealioTheme.dark(...)` as `darkTheme`:
what you leave out keeps its dark default, and `radius` and `fontFamily` carry
over from `theme`. A `theme:` passed to one widget is used exactly as given.
Product photos keep a white background.

**Button.** `variant` is `MealioButtonVariant.solid` (the default), `outline`,
`compact` (uses the `addToCartShort` string) or `icon` (a round 48 cart button,
with the label as its accessibility label).

```dart
MealioCartButton(recipe: recipe, variant: MealioButtonVariant.compact)
```

To draw your own, pass `builder`. It keeps the whole flow and the warm-up.
`onPressed` is null when the button is disabled.

```dart
MealioCartButton(
  recipe: recipe,
  builder: (context, button) => FilledButton(onPressed: button.onPressed, child: Text(button.label)),
)
```

**Sheet.** `MealioSheetOptions` has `showTotal` (default true; hides the list
total, the done subtitle price and the done row prices, while options keep
theirs), `height` (`MealioSheetHeight.auto`, `.full`, or `.fraction(x)`, clamped
to 0.5 to 1) and `logo` (any `ImageProvider`, shown in the header). A total only
ever shows when every item has a price.

**Done screen.** `doneMessage` adds a line of your own. `doneAction` adds a
button: it becomes the main button and Done turns quiet. Tapping it closes the
sheet, reports `onClose`, then calls `onPress` with the result. Both work on
`MealioCartButton` and `MealioCartFlow.show`.

```dart
MealioCartButton(
  recipe: recipe,
  doneMessage: 'Enjoy your meal!',
  doneAction: MealioDoneAction(
    label: 'Back to meal plan',
    onPress: (result) => Navigator.of(context).pop(),
  ),
)
```

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
                                     // total is null when any item is unpriced
final AddResult result = await session.addToCart();
session.addedTotal(result);          // the same, for what the store took

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
| `location_required` | A Kroger family store with no store chosen yet. The drop-in asks the user |
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

## Kroger family stores

Each user chooses their own store. The drop-in asks for a zip, shows nearby
stores for that chain and saves the pick, one per chain. The list has a Change
link. Passing `zip` only fills in the zip box.

To change it outside a cart, for example from your settings screen:

```dart
await MealioCart.instance.openStoreSettings(context);
```

On your own screens, a cart with no store chosen fails with `location_required`
before any sign-in. Use `storeLocations(store, zip)`, then
`setStore(store, locationId: id)`, and prepare again.
