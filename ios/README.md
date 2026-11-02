# Mealio Cart SDK for iOS

Add an "Add to my grocery cart" button to your recipe app. The user picks a
store, signs in to it once, and the recipe's ingredients land in their own
store cart.

How it works, in one line: Mealio's server decides every step and sends it as
a signed instruction batch. The SDK checks the signature, checks every URL
against an allowlist built into the SDK, and carries the steps out on the
phone with the user's own store login. It never decides what to buy.

- iOS 15+, Swift 5.9, no third-party dependencies (CryptoKit, WebKit, SwiftUI).
- The wire protocol is in [`../PROTOCOL.md`](../PROTOCOL.md).

## Install

### Swift Package Manager

In Xcode: **File > Add Package Dependencies...**, enter the repository URL and
add the `MealioSDK` product to your app target.

Or in `Package.swift`:

```swift
dependencies: [
    .package(url: "https://github.com/mealio/mealio_sdk.git", from: "0.1.0"),
],
targets: [
    .target(name: "MyApp", dependencies: [.product(name: "MealioSDK", package: "mealio_sdk")]),
]
```

The package manifest lives in `ios/`. If your SPM setup needs the manifest at
the repository root, add the package from a local checkout of `ios/` instead.

### CocoaPods

```ruby
pod 'MealioSDK', :git => 'https://github.com/mealio/mealio_sdk.git', :tag => 'ios-v0.1.0'
```

## Step 1: your server creates an SDK session

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

## Step 2: configure once

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

- `presenter:` returns the view controller to present the store login sheet
  from. The default is the key window's top-most view controller.
- `attestationProvider:` returns an App Attest token, if you turned
  attestation on in the Mealio dashboard.
- `baseURL:` for testing against a non-production Mealio.

## Step 3: prepare a cart and show it

```swift
let recipe = Recipe(id: "r_123", title: "Chicken Tacos", ingredients: [
    RecipeIngredient(name: "chicken thighs", amount: 1.5, unit: "lb"),
    RecipeIngredient(name: "corn tortillas"),
    RecipeIngredient(name: "limes", quantity: 2),
])

do {
    let session = try await MealioCart.prepareCart(store: "heb", recipe: recipe, zip: "78701")
    // Show the drop-in sheet...
    self.cartSession = session
} catch let error as MealioError {
    // error.code is one of MealioError.Code (see "Errors" below)
}
```

`prepareCart` signs the user in to the store if needed (see "Store login"
below), then searches every ingredient. The `CartSession` it returns sorts
items into:

- `ready`: the user picked a product for this ingredient before and it is in
  stock. Already selected.
- `needsChoice`: up to 8 options, best first. The user picks one or skips.
- `unavailable`: nothing could be offered (`reason`, for example `no_results`).

### The drop-in SwiftUI sheet

```swift
.sheet(item: $cartSession) { session in
    MealioCartSheet(session: session, accentColor: .green,
                    onFinished: { result in
                        // result.added / result.skipped / result.failed / result.storeCartUrl
                        cartSession = nil
                    },
                    onCancel: { cartSession = nil })
}
```

(`CartSession` is a class; wrap it in an `Identifiable` value of your own, or
present with `isPresented:`, as suits your app.)

When a product has `preferences` (for example H-E-B deli meat: sliced or
shaved), the sheet asks for one before selecting it.

### Or build your own UI

`CartSession` is an `ObservableObject`:

```swift
try session.choose(key: item.key, productId: product.id)                     // pick
try session.choose(key: item.key, productId: product.id, preferenceId: "sliced")
session.skip(key: item.key)                                                  // leave out
session.pending()                                                            // still waiting on the user
let result = try await session.addToCart()                                   // fill the store cart
```

`choose` throws `unknown_item` / `unknown_product` if the key or product was
not part of the cart the server sent.

## Store login

When the store needs the user to sign in, the SDK presents a sheet with a
visible `WKWebView` showing the store's own login page, with the store's name
as the title and a Close button. The user types their password into the
store's page; neither your app nor Mealio sees it.

- The login sheet and the SDK's hidden working `WKWebView` share the default
  persistent `WKWebsiteDataStore`, so the user stays signed in across launches.
- Top-frame navigations in the sheet are limited to the store's hosts, its
  identity providers and `mealio.co`. Checkout, payment, billing, gift card,
  password and address pages are blocked everywhere, always.
- Closing the sheet raises `login_cancelled` (via the server).

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
| `not_configured` | `MealioCart.configure` was not called |

## Development

The package builds for iOS. It also lists macOS 12 so the platform-neutral
tests (signatures, allowlist, runner, client) run with plain `swift test` on a
Mac. The WebView host, `MealioCart` and the SwiftUI sheet are iOS only.

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
