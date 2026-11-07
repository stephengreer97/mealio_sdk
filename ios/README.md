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
- `zip` is optional. A Kroger family store asks the user which store they shop
  at, and `zip` fills the zip box on that screen. Without it, they type it in.
  The list shows the store with a Change link.
- `Recipe` also takes `servings` and `makeServings`, to scale the recipe, and
  `photoUrl`, an https image shown at the top of the sheet (up to 3).
  `RecipeIngredient` takes `pantry` and `optional`: those items start unchecked,
  even with a remembered product, and say "You may already have this".
- `label:` changes the button text (default "Add to my grocery cart");
  `disabled:` fades it. `variant:` changes its shape, see "Button variants".

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

Or keep `MealioCartButton` and draw it yourself. It keeps the whole flow and
the warm-up:

```swift
MealioCartButton(recipe: recipe, store: "heb") { action, disabled, label in
    MyBrandButton(title: label, action: action)
        .opacity(disabled ? 0.5 : 1)
}
```

`action` opens the sheet, and does nothing while `disabled` is true. `label` is
your `label:` or the `addToCart` string. The closure takes all three parameters.

### Button variants

```swift
MealioCartButton(recipe: recipe, variant: .outline)
```

| variant | looks like |
| --- | --- |
| `.solid` | the accent filled, full width. The default |
| `.outline` | an accent border, full width |
| `.compact` | small, for a recipe card. The label defaults to "Add to cart" |
| `.icon` | a round 48pt cart button. The label is its accessibility label |

`.compact` and `.icon` are only as wide as they need to be, so place them where
you want them.

### What the user sees

- **Loading:** "Checking your H-E-B sign-in", then "Finding your 6 ingredients".
- **Store sign-in**, inside the same sheet, when the store needs it: the store's
  own page in a visible `WKWebView` with "Sign in on H-E-B's own page. Mealio
  never sees your password."
- **Your store**, inside the same sheet, the first time a Kroger family store is
  used: a zip box, then that chain's nearby stores. The user taps theirs and the
  cart starts there.
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

### The done screen

Add a line and a button of your own. `MealioCartButton`, `.mealioCartFlow` and
`MealioCartFlow` all take these:

```swift
MealioCartButton(recipe: recipe,
                 doneMessage: "Enjoy your meal!",
                 doneAction: MealioDoneAction(label: "Back to meal plan") { result in
                     router.showMealPlan(result)
                 })
```

Your button becomes the main button and Done turns quiet. Tapping it closes the
sheet, then calls your handler with the result. `onClose` runs first. The
handler waits until the sheet has gone, so it can present or navigate.

### Store settings

Put this on your settings screen so the user can change their store or zip
outside a cart. It is the same store list and location screens as the cart sheet:

```swift
@State private var showStore = false

Button("Grocery store") { showStore = true }
    .mealioStoreSettings(isPresented: $showStore,
                         onChange: { preferences in /* called each time the store changes */ })
```

Or put `MealioStoreSettings(onChange:)` in a `.sheet` of your own.

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

### Dark mode

The drop-in is light unless you say otherwise:

```swift
MealioCart.configure(colorScheme: .auto)     // .light (the default), .dark, or .auto

// Optional: your own dark colors. Anything you leave out is Mealio's dark default.
MealioCart.configure(darkTheme: MealioDarkTheme(accent: .mint))
```

`.auto` follows the SwiftUI `colorScheme` environment. `MealioDarkTheme` has the
same fields as `MealioTheme`. Its `radius` and `fontName` stay nil to carry over
from your light theme, so set them only if dark should differ. Product photos
keep a white background in both modes.

`MealioCart.resolvedTheme(for: colorScheme)` returns the theme in force, if you
draw screens of your own to match. `MealioCartList(theme:)` uses the theme you
pass exactly as given.

### Words and languages

Change or translate any word the drop-in shows, accessibility labels and the
store settings sheet included:

```swift
MealioCart.configure(strings: [
    .addToCart: "Zum Warenkorb",
    .done: "Fertig",
    .titleList: "Deine {store} Liste",
    .addItems_one: "1 Artikel zu {store}",
    .addItems_other: "{count} Artikel zu {store}",
])
```

Keys are `MealioStringKey`, and `DEFAULT_STRINGS` has every default. Keys you
leave out keep the default text.

- `{store}`-style placeholders are filled in at runtime. A placeholder with no
  value stays visible, so a typo shows on screen.
- A key ending `_one` or `_other` is the singular or plural of one message.
- "Cart by Mealio" on the done screen is fixed.
- Error messages from Mealio's server and the store's own sign-in title are not
  in the table. Weights always read "lb".

`MealioCart.text` is the table in force, with `tr`, `plural` and `money`, for
screens of your own. `session.recipesLabel(for: key, text: MealioCart.text)`
gives the "For Tacos and Pasta" line in your words.

### Prices

```swift
MealioCart.configure(formatMoney: { amount in
    amount.formatted(.currency(code: "EUR"))
})
```

The default reads "$12.50". With `formatMoney` set, totals, per-pound prices and
option prices all go through it. Option prices then come from the numeric
`unitPrice`, not the store's price text. An option with no `unitPrice` still
shows the store's text. Clear it with `MealioCart.formatMoney = nil`.

### The sheet

```swift
MealioCart.configure(sheet: MealioSheetOptions(showTotal: false,
                                               height: .fraction(0.8),
                                               logo: Image("BrandLogo")))
```

- `showTotal` (default true): false hides the list's total row, the price on the
  done screen and the prices on its rows. Options keep their own prices. There
  is never a partial total: if any item has no price, the sheet says "Prices at
  checkout" instead.
- `height`: `.auto` (the default) is the ordinary tall sheet. `.full` fills the
  screen. `.fraction(0.8)` is a share of the screen, clamped to 0.5...1.
  `.fraction` needs iOS 16. On iOS 15 it is the ordinary tall sheet. A large
  fraction stops at the system's tallest sheet, and iPad ignores it in regular
  width.
- `logo`: a SwiftUI `Image`, drawn 36pt at the top of the sheet.

`.mealioCartFlow`, `.mealioStoreSettings` and `MealioCartButton` present `.full`
as a full screen cover, which has no swipe to close. In a `.sheet` of your own,
`.full` is the tallest sheet the system allows.

While items are being added the sheet cannot be closed: the close button is
off and the swipe does nothing. The add always ends on its own.

### Hosting the sheet from UIKit

`MealioCartFlow` is a SwiftUI view, so wrap it in a `UIHostingController`.
SwiftUI's dismiss cannot close a controller UIKit presented, so dismiss it
yourself in `onClose`. Every close button calls `onClose` straight away.

```swift
var host: UIViewController?
let flow = MealioCartFlow(recipe: recipe, store: "heb", onClose: { result in
    host?.dismiss(animated: true)
})
host = UIHostingController(rootView: flow)
present(host!, animated: true)
```

## Install

### Swift Package Manager

In Xcode: **File > Add Package Dependencies...**, enter the repository URL and
add the `MealioSDK` product to your app target.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/stephengreer97/mealio_sdk.git", from: "0.5.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "MealioSDK", package: "mealio_sdk")]),
]
```

The repository root's `Package.swift` is the one Swift Package Manager reads;
`ios/Package.swift` adds the tests and is for working on the SDK itself.

### CocoaPods

```ruby
pod 'MealioSDK', :git => 'https://github.com/stephengreer97/mealio_sdk.git', :tag => 'v0.5.0'
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

- `theme:`, `darkTheme:`, `colorScheme:`, `strings:`, `formatMoney:` and
  `sheet:`: the drop-in's look and words (see "Theme" above and the sections
  after it). `MealioCart.configure(theme:...)` takes the same six on their own,
  any time. What you leave out stays as it is.
- `onEvent:` gets every step of the sheet as a `MealioEvent`, for your analytics.
  `event.type` is its name (`sheet_opened` ... `sheet_closed`, which carries the
  step the user left from). Nothing is sent to Mealio. It works on its own too:
  `MealioCart.configure(onEvent: { event in ... })`.
- `presenter:` returns the view controller to present the store login sheet
  from when no cart flow sheet is open (for example if you call
  `prepareCart` yourself). The default is the key window's top-most view
  controller.
- `attestationProvider:` returns an App Attest token, if you turned
  attestation on in the Mealio dashboard.
- `baseURL:` for testing against a non-production Mealio.

If your session function throws or takes over 30 seconds, calls fail with
`session_failed`, and your error's message is the `message`. Every request to
Mealio gets 30 seconds, then fails with `network`.

### Signed-in users

Tell the SDK who is signed in, at launch and whenever it changes:

```swift
MealioCart.setUser(user?.id)                      // nil while nobody is signed in
MealioCart.onSignInRequired = { router.showSignIn() }
```

A change of user stops a cart being prepared, starts a new Mealio session and,
when there was a user before, signs out of the stores (an add under way finishes
first). While it is nil there is no session and no warm-up, and
`MealioCartButton` and store settings call `onSignInRequired` instead of opening.
Without `onSignInRequired` the button is disabled then. Each also takes its own
`onSignInRequired:`. Until you call `setUser`, nothing changes.

## Building your own UI

Everything the sheet does is public, if you want your own screens.

```swift
let stores = try await MealioCart.stores()          // [StoreInfo]: id, name, via
let session = try await MealioCart.prepareCart(store: "heb", recipe: recipe, zip: "78701",
                                               onStep: { step, _ in progress = step })
```

`prepareCart` fails with `location_required`, before any sign-in, when a Kroger
family store has no saved location for the user. Ask them, or pass `zip` to use
the nearest store instead of asking. The drop-in always asks. The same calls
build your own store screen:

```swift
let nearby = try await MealioCart.storeLocations(store: "kroger", zip: "75202")   // [StoreLocation], nearest first
try await MealioCart.setStore("kroger", locationId: nearby[0].id)                 // needed the first time
try await MealioCart.setStore("heb")                                              // not a Kroger family store
let saved = try await MealioCart.storePreferences()                               // defaultStore, location
session.location                                                                  // the exact store on a Kroger family cart
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

`MealioCartList(cart:storeName:theme:busy:onChangeStore:onChangeLocation:onAdd:)` is the list
screen on its own, for hosting in a sheet of yours. `MealioCartSheet` (the 0.1
sheet) still works and now draws that list. Its `title:` defaults to the
`addToCartShort` string, and its cancel button reads `close`.

`AddResult` has `added`, `skipped` (reason `deselected` for unchecked items),
`failed` (reason `not_confirmed` when the cart read after adding did not find
the item) and `verified` (true when that read confirmed everything). Each added
entry may carry `imageUrl`, `ingredient`, `unitPrice`, `pricePerLb` and
`estimated` (absent from older servers). `session.addedTotal(result)` and
`session.addedPrice(entry)` price them, falling back to the selected product.

No partial totals: `estimate()` and `addedTotal(_:)` return `total: nil` when
any counted item has no price. Show no number then, never a sum of the rest.
Both sum whole cents line by line, so the list and done totals agree.

`quantity(for:)` never exceeds the selected product's cap, and is what is sent.
`session.warnings` lists what the server changed or ignored in your recipe
(`ingredients_dropped`, `lines_dropped`, `servings_ignored`); debug builds log them.

A prepare or search can be stopped with a `CancelToken`: it stops after the
current step, never shows sign-in, and fails with `cancelled`.
`session.searching` is true while a search runs (keep Add off), and
`session.cancelSearches()` stops them. An add cannot be cancelled, and a second
`addToCart` while one runs gets the same result. After a failed add, prepare a
new cart and call `newSession.restorePicks(from: oldSession)` to keep the user's picks.

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
- Top-frame navigations in the sheet are limited to the store's hosts, that
  store's own identity providers (multi-tenant providers such as Okta or Azure
  AD B2C only for the store that uses them), Google, Apple and Facebook sign-in,
  and `mealio.co`. Checkout, payment, billing, gift card, password and address
  pages are blocked everywhere, always, including when percent-encoded.
- Only the top page of either WebView can post messages to the SDK; messages
  from iframes are ignored.
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
| `session_failed` | Your session function threw or took over 30 seconds; `message` is your error's |
| `not_signed_in` | `setUser(nil)`: nobody is signed in, so there is no session |
| `cancelled` | A prepare or search was stopped (the sheet closed or the user changed) |
| `network` | Could not reach Mealio |
| `unsupported` | An instruction this SDK version does not know (update the SDK) |
| `server` | Mealio answered with an error, or something the SDK could not read |
| `store_required` | No store was given and the user has no default store yet (the drop-in shows its store picker) |
| `location_required` | A Kroger family store has no saved location for the user (the drop-in shows its location step) |
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
`protocol/test-vectors.json`, and `strings.json` there is a copy of
`protocol/strings.json`. `guard-script.js` and `bridge-shim.js` there are the
exact text of `GUARD_SCRIPT` and `BRIDGE_SHIM` from
`packages/core/src/guard.ts`; the tests compare `MealioScripts` with them byte
for byte. Regenerate all four whenever the protocol, strings or guard change.
When `protocol/strings.json` gains a key, add it to `MealioStringKey` and
`DEFAULT_STRINGS` in `Sources/MealioSDK/MealioStrings.swift`; `StringsTests`
fails until the two agree.
