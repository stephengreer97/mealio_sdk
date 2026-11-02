# Mealio Cart SDK for Android

Kotlin library `co.mealio.sdk`. It puts an **Add to my grocery cart** button in
your recipe app. The user fills their own store cart with their own store
login, inside your app.

The SDK is the hands. Mealio's server is the brain. Every step arrives as an
Ed25519-signed envelope. The SDK checks the signature and every URL against a
built-in allowlist (checkout and payment are always blocked), runs the step in
a hidden WebView, and sends back what the store answered. See
[../PROTOCOL.md](../PROTOCOL.md).

| Module | What |
| --- | --- |
| `mealio-sdk` | The core: protocol, signature checks, allowlist, guard script, runner, client, WebView host, login sheet. No Compose. |
| `mealio-sdk-compose` | Optional drop-in `MealioCartSheet` composable (Material 3). |

minSdk 24, compileSdk 34, Java 17, Kotlin 1.9.

## Install

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories { google(); mavenCentral() }
}

// app/build.gradle.kts
dependencies {
    implementation("co.mealio:mealio-sdk:0.1.0")
    // Optional, for the ready-made sheet:
    implementation("co.mealio:mealio-sdk-compose:0.1.0")
}
```

The SDK's manifest adds the `INTERNET` permission and the login sheet
activity. You do not need to add anything to your manifest.

## 1. Server side: one endpoint

Your app never holds your Mealio secret key. Add one endpoint to your server
that calls `POST https://mealio.co/api/v1/sessions` with your **secret key**
and your user's id, and returns the SDK session token it gets back. See
`examples/partner-server` in this repo.

The SDK calls your `sessionTokenProvider` when it needs a token, and calls it
again if Mealio says the token expired.

## 2. Configure once

```kotlin
class MyApp : Application() {
    override fun onCreate() {
        super.onCreate()
        MealioCart.configure(
            context = this,
            publishableKey = "pk_live_...",
            sessionTokenProvider = { myApi.fetchMealioSessionToken() }, // suspend
        )
    }
}
```

## 3. Fill a cart

```kotlin
lifecycleScope.launch {
    try {
        val recipe = Recipe(
            id = "r_123",
            title = "Chicken tacos",
            ingredients = listOf(
                RecipeIngredient("chicken thighs", quantity = 1),
                RecipeIngredient("corn tortillas"),
            ),
        )
        // Shows the store's login sheet if the user is not signed in yet.
        val session = MealioCart.prepareCart(store = "heb", recipe = recipe, zip = "78701")

        // Items in session.ready are already picked (the user's earlier choice).
        // Items in session.needsChoice wait for the user:
        for (item in session.needsChoice) {
            val option = item.options.first()              // let the USER pick in real UI
            session.choose(item.key, option.id, preferenceId = option.preferences.firstOrNull()?.id)
        }

        val result = session.addToCart()
        result.storeCartUrl?.let { openInBrowser(it) }    // user checks out on the store's site
    } catch (e: MealioException) {
        when (e.code) {
            "login_cancelled" -> { /* user closed the sign-in sheet */ }
            "store_unavailable" -> { /* try later */ }
            else -> showError(e.message)
        }
    }
}
```

### Or use the drop-in sheet (Compose)

```kotlin
var session by remember { mutableStateOf<CartSession?>(null) }

session?.let { s ->
    MealioCartSheet(
        session = s,
        onDismiss = { session = null },
        onAdded = { result -> session = null; result.storeCartUrl?.let(::openInBrowser) },
    )
}
```

It shows ready items, the options for each item that needs a pick (and the
"sliced or shaved?" preference when a product has one), unavailable items, and
an **Add to cart** button that stays off until every item is picked or skipped.
`MealioCartContent` is the same thing without the bottom sheet.

### Sign out of stores

```kotlin
MealioCart.signOutOfStore("heb")
MealioCart.signOutOfAllStores()
```

Both clear the store's cookies and web storage on the device and bump a
device "epoch" the SDK sends to Mealio, so the server forgets any session it
held for this device.

**Note:** `CookieManager` and `WebStorage` are process-wide on Android.
`signOutOfAllStores()` clears every cookie and all web storage of **every**
WebView in your app, not only the stores'.

## Public API

```kotlin
object MealioCart {
    const val SDK_VERSION: String
    fun configure(context: Context, publishableKey: String, sessionTokenProvider: suspend () -> String,
                  baseUrl: String = "https://mealio.co", attestationProvider: (suspend () -> String?)? = null)
    val isConfigured: Boolean
    val client: MealioClient
    suspend fun prepareCart(store: String, recipe: Recipe, zip: String? = null): CartSession
    suspend fun signOutOfStore(store: String)
    suspend fun signOutOfAllStores()
}

class CartSession {
    val cartId: String; val store: String; val cart: PreparedCart
    val ready: List<CartItem>; val needsChoice: List<CartItem>; val unavailable: List<CartItem>
    fun pending(): List<CartItem>
    fun choose(key: String, productId: String, quantity: Int? = null, remember: Boolean = true, preferenceId: String? = null)
    fun skip(key: String)
    fun selectionFor(key: String): Selection?
    fun selections(): List<Selection>
    suspend fun addToCart(): AddResult
}

class MealioException(val code: String, message: String, cause: Throwable? = null) : Exception
```

Error codes are the ones in PROTOCOL.md: `bad_envelope`, `blocked`,
`store_unavailable`, `login_cancelled`, `session_expired`, `network`,
`unsupported`. Also `server` (Mealio answered with an error) and
`unknown_item` / `unknown_product` from `choose`.

Advanced: `MealioClient(config, host, transport)` lets you supply your own
`Host` (WebViews) or `HttpTransport`.

## ProGuard / R8

Nothing to add. The AAR ships `consumer-rules.pro`, which R8 applies to your
app automatically. It keeps the `@JavascriptInterface` bridge class
(`co.mealio.sdk.MealioNativeBridge`) and its annotation, keeps the login
activity, and silences BouncyCastle warnings about JDK classes Android does
not have.

## Things to know

- **The hidden WebView is not attached to a window.** JS, network, cookies
  and storage work. `requestAnimationFrame` does not fire and the page reports
  itself hidden. Mealio's store scripts are written for that.
- **Google / Apple sign-in inside a WebView.** Google refuses OAuth in embedded
  WebViews (`disallowed_useragent`). Users who log in to a store "with Google"
  must use the store's email and password in the sheet.
- **BouncyCastle** (`bcprov-jdk18on`) supplies Ed25519 because the platform
  only has it from API 33. If your app also bundles BouncyCastle and the build
  complains about duplicate `META-INF` files, add
  `packaging { resources { excludes += "META-INF/versions/9/OSGI-INF/MANIFEST.MF" } }`.
- **Fetch methods.** `HttpURLConnection` has no `PATCH`; such a fetch returns
  `error: "bad_method"` to the server.

## Build and test (CI)

The Gradle wrapper jar is not checked in. In GitHub Actions:

```yaml
- uses: actions/setup-java@v4
  with: { distribution: temurin, java-version: 17 }
- uses: android-actions/setup-android@v3
- uses: gradle/actions/setup-gradle@v3
  with: { gradle-version: "8.7" }
- run: gradle :mealio-sdk:testDebugUnitTest :mealio-sdk:assembleRelease :mealio-sdk-compose:assembleRelease
  working-directory: android
```

Locally, run `gradle wrapper --gradle-version 8.7` once in `android/` and then
`./gradlew :mealio-sdk:testDebugUnitTest :mealio-sdk:assembleRelease :mealio-sdk-compose:assembleRelease`.

The unit tests run on the JVM (JUnit 4):

- `VectorTest` runs every case, allowlist case and matcher case in
  `protocol/test-vectors.json` (copied to `mealio-sdk/src/test/resources/`)
  and must agree with `packages/core/test/core.test.ts`.
- `RunnerTest` covers skip-after-failure, done/fail, the fetch rate cap,
  every refusal reason, allowlist edges and matcher rules, with a fake Host.
  It signs extra envelopes with the same deterministic test key.
- `ClientTest` covers the drive loop, the 401 retry, headers, hello and
  allowlist widening, error mapping, and a full CartSession round trip.
- `GuardScriptTest` checks `GUARD_SCRIPT` and `BRIDGE_SHIM` byte for byte
  against `guard-expected.js` / `bridge-expected.js`, which are the exact
  strings `packages/core/src/guard.ts` produces. If `guard.ts` changes,
  regenerate those two files from it, and copy `protocol/test-vectors.json`
  again when the vectors change.
