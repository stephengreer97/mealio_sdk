# Mealio Cart SDK for iOS

Add an "Add to my grocery cart" button to your recipe app. One view does it:

```swift
import MealioSDK

MealioCartButton(recipe: recipe, store: "heb")
```

Tapping it opens ONE sheet over your app that runs the whole flow: checking
the store sign-in, the store's own sign-in page when needed, the list of every
ingredient with the user's usual products already checked, adding, and a done
screen. The user checks out on the store's own site or app later; the SDK never
opens the store cart.

How it works, in one line: Mealio's server decides every step and sends it as
a signed instruction batch. The SDK checks the signature, checks every URL
against an allowlist built into the SDK, and carries the steps out on the
phone with the user's own store login. It never decides what to buy.

- iOS 15+, Swift 5.9, no third-party dependencies (CryptoKit, WebKit, SwiftUI).
- The wire protocol is in [`../PROTOCOL.md`](../PROTOCOL.md).

## Quick start

1. Configure once, at launch (your server creates the session token, see
   "Your server creates an SDK session" below):

   ```swift
   @main
   struct RecipeApp: App {
       init() {
           MealioCart.configure(publishableKey: "pk_live_...",
                                sessionTokenProvider: { try await MyAPI.mealioSessionToken() },
                                theme: MealioTheme(accent: Color(mealioHex: 0x1F6B47)))
       }
       var body: some Scene { WindowGroup { ContentView() } }
   }
   ```

2. Drop the button on your recipe screen:

   ```swift
   let recipe = Recipe(id: "r_123", title: "Chicken Tacos", ingredients: [
       RecipeIngredient(name: "chicken thighs", amount: 1.5, unit: "lb"),
       RecipeIngredient(name: "corn tortillas"),
       RecipeIngredient(name: "limes", quantity: 2),
   ])

   MealioCartButton(recipe: recipe, store: "heb", zip: "78701",
                    onAdded: { result in /* result.added, result.failed */ },
                    onClose: { result in /* nil when nothing was added */ })
   ```

That is the whole integration.

- `store` is optional. Without it Mealio uses the user's default store, and when
  they have none yet the sheet asks them to choose one. The list also has a
  store chip ("H-E-B  Change") to switch stores.
- `zip` is needed for Kroger family stores.
- `label:` changes the button text (default "Add to my grocery cart");
  `disabled:` fades it.

### Several recipes in one cart

Pass `recipes:` instead of `recipe:` to fill one cart from up to 10 meals
(`MAX_RECIPES`):

```swift
MealioCartButton(recipes: [tacos, pasta], store: "heb")

// or
.mealioCartFlow(isPresented: $showCart, recipes: [tacos, pasta])
```

Ingredients the recipes share become one item, with the quantities added
together. The sheet's header says "2 meals", and each item shows which meals it
is for ("For Tacos and Pasta"). A pick is remembered under every recipe on the
item, so next time each meal comes back with that product checked. Building
your own UI:

```swift
let session = try await MealioCart.prepareCart(store: "heb", recipes: [tacos, pasta])
session.recipes                    // [CartRecipe]: id, title, in the order sent
session.recipes(for: key)          // [ItemRecipe]: id, title, quantity (that recipe's share)
session.recipesLabel(for: key)     // "For Tacos and Pasta", nil on a one-recipe cart
```

An empty list throws `bad_recipe` and more than 10 throws `too_many_recipes`,
both before any network call. One recipe is sent exactly as `recipe:` is, so
it works with every server; `recipes` and `CartItem.recipes` are empty from
servers older than multi-recipe.

### Your own button

Present the same sheet from any control with the view modifier:

```swift
@State private var showCart = false

Button("Shop this recipe") { showCart = true }
    .mealioCartFlow(isPresented: $showCart, recipe: recipe, store: "heb",
                    onAdded: { result in ... },
                    onError: { error in ... },
                    onClose: { result in ... })
```

Or put `MealioCartFlow(recipe:store:zip:onAdded:onError:onClose:)` in a
`.sheet` of your own. `onClose` is called exactly once, whether the user taps
Close, Done, or swipes the sheet away.

### What the user sees

- **Loading:** "Checking your H-E-B sign-in", then "Finding your 6 ingredients".
- **Store sign-in**, inside the same sheet, when the store needs it: the store's
  own page in a visible `WKWebView` with "Sign in on H-E-B's own page. Mealio
  never sees your password."
- **The list:** every ingredient, every time. Products the user picked before
  ("Your usual") come back checked. Each card expands to show other options,
  a search box ("Search H-E-B for something else") and, for products like deli
  meat, preference chips (sliced / shaved). Unchecking an item leaves it out of
  this run only; the usual pick stays saved. The footer shows the total
  ("about $31.20" when some items are sold by weight), or "Prices at checkout"
  when any checked item has no price, and "Add 5 items to H-E-B".
- **Done:** "In your H-E-B cart", a banner "5 items added" with "about $31.20"
  (or "Prices at checkout"), one row per added item (image, product, the recipe
  line, amount, price), a collapsed "Left out this time" that opens on its own
  when something failed (with the reason in plain words), and a Done button.

### Theme

```swift
MealioCart.configure(theme: MealioTheme(
    accent: .green,          // buttons, checkmarks, selected rings
    onAccent: .white,        // text on the accent
    background: .white,      // the sheet
    surface: Color(mealioHex: 0xF2F1EE),   // thumbnails, search box, chips
    text: .black,
    muted: .gray,            // secondary text; keep 4.5:1 against background
    border: Color(mealioHex: 0xE4E2DD),
    radius: 14,              // cards and buttons
    fontName: "Avenir Next", // nil for the system font
    warnBackground: Color(mealioHex: 0xFFF4E5),
    warnText: Color(mealioHex: 0x7A4A06)
))
```

Every field has a default (`MealioTheme.default`), so pass only what you change.

## Install

### Swift Package Manager

In Xcode: **File > Add Package Dependencies...**, enter the repository URL and
add the `MealioSDK` product to your app target.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mealio/mealio_sdk.git", from: "0.3.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "MealioSDK", package: "mealio_sdk")]),
]
```

The package manifest lives in `ios/`. If your SPM setup needs the manifest at
the repository root, add the package from a local checkout of `ios/` instead.

### CocoaPods

```ruby
pod 'MealioSDK', :git => 'https://github.com/mealio/mealio_sdk.git', :tag => 'ios-v0.3.0'
```

## Your server creates an SDK session

Your publishable key is safe to ship in the app. Your **secret** key is not.
Your server uses the secret key to create a short-lived SDK session for the
signed-in user, and hands the app only the session token.

```
POST https://mealio.co/api/v1/sessions        (from your server, with your SECRET key)
-> an SDK session token for this user
```

See Mealio's server API docs for the exact request body and response fields.
Never call this endpoint from the app.

The SDK asks your app for this token when it needs one, and asks again if the
token expires (a 401 from Mealio), so your provider should always fetch a
fresh one from your server.

## Configure

```swift
import MealioSDK

@main
struct RecipeApp: App {
    init() {
        MealioCart.configure(publishableKey: "pk_live_...") {
            try await MyAPI.mealioSessionToken()   // calls your server, which calls POST /api/v1/sessions
        }
    }
    var body: some Scene { WindowGroup { ContentView() } }
}
```

`configure` also takes:

- `theme:` the drop-in's look (see "Theme" above).
- `presenter:` returns the view controller to present the store login sheet
  from when no cart flow sheet is open (for example if you call
  `prepareCart` yourself). The default is the key window's top-most view
  controller.
- `attestationProvider:` returns an App Attest token, if you turned
  attestation on in the Mealio dashboard.
- `baseURL:` for testing against a non-production Mealio.

## Building your own UI

Everything the sheet does is public, if you want your own screens.

```swift
let stores = try await MealioCart.stores()          // [StoreInfo]: id, name, via
let session = try await MealioCart.prepareCart(store: "heb", recipe: recipe, zip: "78701",
                                               onStep: { step, _ in progress = step })
```

`onStep` reports a `Step`: `.connecting`, `.checkingSignIn`, `.signingIn`,
`.searching`, `.adding`. While no cart flow sheet is open, a store sign-in is
presented in a sheet of its own.

`CartSession` is an `ObservableObject`. `session.items` is every recipe line in
order; each `CartItem` has a `status`:

| status | meaning |
| --- | --- |
| `.remembered` | the user's usual product, in stock, already selected |
| `.choose` | nothing remembered yet; the user picks from `options` |
| `.rememberedUnavailable` | the usual is out of stock or gone today; `remembered` still says what it was |
| `.unavailable` | nothing found; `reason` says why (for example `no_results`) |

```swift
session.options(for: key)                        // options, plus any found by search
session.isSelected(key); session.selectedId(for: key); session.selected(for: key)
try session.select(key: key, productId: id, preferenceId: "sliced")
session.deselect(key: key)                       // leave out of THIS run; the usual stays saved
try await session.search(key: key, query: "minced garlic jar")   // adds to options(for:)
session.setQuantity(key: key, to: 2)             // count items, clamped to 1 and the store cap
session.isWeight(key)                            // soldByWeight: use weight, not quantity
session.weight(for: key); session.weightRange(for: key)
session.setWeight(key: key, to: 1.25); session.stepWeight(key: key, by: 1)   // snapped to the store's weights
session.needsPreference(key); session.pendingPreferences()  // ticked, but no preference chosen yet
let est = session.estimate()                     // total (nil if any item is unpriced), count, estimated, unpriced
let result = try await session.addToCart(onStep: { step, _ in })
```

`selections()` sends one entry for every item: selected ones with
`remember: true` (and the preference), the rest with `productId: nil,
remember: false`, which leaves them out without forgetting the usual pick. A
sold-by-weight item sends `quantity: 1` and `weightLb`, and is estimated as
`pricePerLb` times the weight. An item whose product has `preferences` and none
chosen is held out of `selections()` and `estimate()` until one is.
`select` throws `unknown_item` / `unknown_product` if the key or product was not
part of the cart.

`MealioCartList(cart:storeName:theme:busy:onChangeStore:onAdd:)` is the list
screen on its own, for hosting in a sheet of yours. `MealioCartSheet` (the 0.1
sheet) still works and now draws that list.

`AddResult` has `added`, `skipped` (reason `deselected` for unchecked items),
`failed` (reason `not_confirmed` when the cart read after adding did not find
the item) and `verified` (true when that read confirmed everything). Each added
entry may carry `imageUrl`, `ingredient`, `unitPrice`, `pricePerLb` and
`estimated` (absent from older servers). `session.addedTotal(result)` and
`session.addedPrice(entry)` price them, falling back to the selected product.

No partial totals: `estimate()` and `addedTotal(_:)` return `total: nil` when
any counted item has no price. Show no number then, never a sum of the rest.

### Upgrading from 0.1

- There is no separate hello call: `prepareCart`, `search` and `addToCart` send
  the SDK version and store-session epoch in their bodies. `resetHello()` is a
  no-op.
- `ready` / `needsChoice` / `unavailable`, `choose`, `skip` and `pending()` still
  work but are deprecated: use `items`, `select`, `deselect` and `isSelected`.
- `CartItem.options` is no longer optional. `Product` gains `unitPrice` and
  `estimated`. Older server payloads still decode.

## Store login

When the store needs the user to sign in, a visible `WKWebView` shows the
store's own login page: inside the cart flow sheet when one is open, otherwise
in a sheet of its own with the store's title and a Close button. The user types
their password into the store's page; neither your app nor Mealio sees it.

- The login sheet and the SDK's hidden working `WKWebView` share the default
  persistent `WKWebsiteDataStore`, so the user stays signed in across launches.
- Top-frame navigations in the sheet are limited to the store's hosts, its
  identity providers and `mealio.co`. Checkout, payment, billing, gift card,
  password and address pages are blocked everywhere, always.
- Closing the sign-in raises `login_cancelled` (via the server).

To sign a user out of stores (for example from your app's settings):

```swift
await MealioCart.signOutOfStore("heb")
await MealioCart.signOutOfAllStores()
```

These remove the cookies and website data of the store domains only. Your own
app's web content is not touched.

## Errors

All errors are `MealioError` with a `code` and a readable `message`:

| code | meaning |
| --- | --- |
| `bad_envelope` | Signature, expiry, job or sequence check failed |
| `blocked` | An instruction broke the allowlist |
| `store_unavailable` | The store cannot be reached now |
| `login_cancelled` | The user closed the login sheet |
| `session_expired` | The SDK session token expired twice in a row; get a new one from your server |
| `network` | Could not reach Mealio |
| `unsupported` | An instruction this SDK version does not know (update the SDK) |
| `server` | Mealio answered with an error, or something the SDK could not read |
| `store_required` | No store was given and the user has no default store yet (the drop-in shows its store picker) |
| `not_configured` | `MealioCart.configure` was not called |
| `bad_recipe` | `prepareCart` was given an empty `recipes` list |
| `too_many_recipes` | `prepareCart` was given more than 10 recipes |

## Development

The package builds for iOS. It also lists macOS 12 so the platform-neutral
tests (signatures, allowlist, runner, client, cart session) run with plain
`swift test` on a Mac. The WebView host, `MealioCart` and the SwiftUI views
are iOS only.

```bash
cd ios
swift test                                                  # fast, macOS host
xcodebuild -scheme MealioSDK -destination 'platform=iOS Simulator,name=iPhone 15' test
```

`Tests/MealioSDKTests/Resources/test-vectors.json` is a copy of
`protocol/test-vectors.json`. `guard-script.js` and `bridge-shim.js` there are
the exact text of `GUARD_SCRIPT` and `BRIDGE_SHIM` from
`packages/core/src/guard.ts`; the tests compare `MealioScripts` with them byte
for byte. Regenerate all three whenever the protocol or guard changes.
