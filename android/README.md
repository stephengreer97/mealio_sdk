# Mealio Cart SDK for Android

Kotlin library `co.mealio.sdk`. It puts an **Add to my grocery cart** button in
your recipe app. The user fills their own store cart with their own store
login, inside your app.

The SDK is the hands. Mealio's server is the brain. Every step arrives as an
Ed25519-signed envelope. The SDK checks the signature and every URL against a
built-in allowlist (checkout and payment are always blocked), runs the step in
a hidden WebView, and sends back what the store answered. See
[../PROTOCOL.md](../PROTOCOL.md).

## The whole integration

```kotlin
// Application.onCreate, once:
MealioCart.configure(this, publishableKey = "pk_live_...", sessionTokenProvider = { myApi.mealioSessionToken() })

// Your recipe screen (Compose):
MealioCartButton(recipe = recipe, store = "heb")
```

That is all. The button opens ONE sheet over your app that runs everything:
checking the store sign-in, the store's own sign-in page (inside the same
sheet) when needed, the list of every ingredient with prices, adding to the
store cart, and a done screen. The user checks out on the store's own site
or app when they want to; the sheet never opens the store cart.

`store` is optional. Without it the user's default store is used, and the
sheet asks them to pick one the first time. The user can change store from a
chip above the list either way.

A Kroger family store is a chain, so the sheet asks the user which store they
shop at the first time: a zip box, then that chain's stores near them. `zip`
only fills the box. The list shows the chosen store with a Change link.

To let users change their store outside a cart, put `MealioStoreSettings` on
your settings screen:

```kotlin
var open by rememberSaveable { mutableStateOf(false) }
Button(onClick = { open = true }) { Text("Grocery store") }
MealioStoreSettings(visible = open, onClose = { open = false })
```

| Module | What |
| --- | --- |
| `mealio-sdk` | The core: protocol, signature checks, allowlist, guard script, runner, client, cart session, WebView host, login screen. No Compose. |
| `mealio-sdk-compose` | The drop-in: `MealioCartButton`, `MealioCartFlow`, `MealioCartList`, `MealioStoreSettings`, `MealioTheme`, `MealioThemeProvider`. |
| `mealio-sdk-testing` | Tests only (`testImplementation`): `FakeMealio`, a scripted Mealio for JVM and Robolectric tests. See Testing your screens. |

minSdk 24, compileSdk 34, Java 17, Kotlin 1.9.

## Install

```kotlin
// settings.gradle.kts
dependencyResolutionManagement {
    repositories { google(); mavenCentral() }
}

// app/build.gradle.kts
dependencies {
    implementation("co.mealio:mealio-sdk-compose:0.6.0") // pulls in mealio-sdk
}
```

The SDK's manifest adds the `INTERNET` permission and the fallback login
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

If `sessionTokenProvider` throws or takes over 30 seconds, the call fails with
`session_failed`, and your exception's message is the error's `message`.

### Who is signed in

```kotlin
MealioCart.setUser(user?.id)                       // at start-up and on every sign-in or sign-out
MealioCart.onSignInRequired = { openYourSignIn() } // optional
```

When the id changes, a cart still loading stops, the next call gets a new
session, and if the old value was a user, the device signs out of the stores
(an add under way finishes first; a failed sign-out is never thrown). While it
is null there is no session and no warm-up, and `MealioCartButton` calls
`onSignInRequired` when tapped (its own parameter, else `MealioCart.onSignInRequired`).
With neither, the button is disabled. `MealioStoreSettings` does the same.
Without `setUser`, nothing changes from before.

## 3. Add the button

```kotlin
val recipe = Recipe(
    id = "r_123",
    title = "Chicken tacos",
    ingredients = listOf(
        RecipeIngredient("chicken thighs", quantity = 1),
        RecipeIngredient("corn tortillas"),
    ),
)

MealioCartButton(
    recipe = recipe,
    store = "heb",                 // optional
    zip = "78701",                 // optional: fills the zip box for Kroger family stores
    label = "Add to my grocery cart", // optional: this is the default, from the `addToCart` string
    onAdded = { result -> analytics.log("added", result.added.size) },
    onClose = { result -> /* null when nothing was added */ },
    onError = { e -> /* MealioException with a code, see below */ },
    modifier = Modifier.fillMaxWidth(),
)
```

Optional recipe details: `servings` with `makeServings` scales weights and any `quantity` you set, `RecipeIngredient(pantry = true)` or `optional = true` starts that item unchecked (`CartItem.startUnchecked`) with a "You may already have this" hint (`pantryHint`), and an https `photoUrl` shows in the sheet header, up to 3 photos.

### Several meals in one cart

Pass `recipes` instead of `recipe`, up to 10 (`MAX_RECIPES`), each with its
own `id`. Ingredients the recipes share become one item, and a pick on it is
remembered under every recipe that calls for it.

```kotlin
MealioCartButton(recipes = listOf(tacos, pasta), store = "heb")
```

The sheet's kicker reads "2 meals", and each item says which meals it is for
("For Tacos and Pasta"). Without Compose:

```kotlin
val cart = MealioCart.prepareCart("heb", listOf(tacos, pasta))
cart.recipes                       // [CartRecipe(id, title)], in the order sent
cart.recipesFor(item.key)          // [ItemRecipe(id, title, quantity, share)]: each recipe's share
forRecipes(cart, item.key)         // "For Tacos and Pasta", or null on a one-recipe cart
```

An empty list fails with `bad_recipe` and more than 10 with
`too_many_recipes`, before any network call. One recipe is still sent as
`recipe`, so older servers keep working; they return no `recipes` lists, and
both come back empty.

### Button styles

```kotlin
MealioCartButton(recipe = recipe, variant = MealioButtonVariant.OUTLINE)
```

| Variant | Looks like |
| --- | --- |
| `SOLID` | The default. A filled accent button. |
| `OUTLINE` | Transparent, with an accent border and accent text. |
| `COMPACT` | A small button for a recipe card. Its label defaults to the `addToCartShort` string. |
| `ICON` | A round 48dp cart button. `label` is its content description. |

### Your own button

Pass `button` to draw it yourself. It keeps the whole flow and the warm-up.

```kotlin
MealioCartButton(
    recipe = recipe,
    button = { onClick, enabled, label ->
        MyButton(onClick = onClick, enabled = enabled) { Text(label) }
    },
)
```

`MealioCartFlow` is the sheet on its own, for when you start it yourself. Call
`MealioCart.warm(store)` too if you want the warm-up.

```kotlin
var open by remember { mutableStateOf(false) }
MyButton(onClick = { open = true })
MealioCartFlow(visible = open, recipe = recipe, store = "heb", onClose = { open = false })
```

### The done screen

`MealioCartButton` and `MealioCartFlow` both take these.

```kotlin
MealioCartButton(
    recipe = recipe,
    doneMessage = "Enjoy your meal!",
    doneAction = MealioDoneAction("Back to meal plan") { result -> openMealPlan(result) },
)
```

With `doneAction`, your button is the main button and Done turns quiet. Tapping
your button closes the sheet, which calls `onClose`, and then calls its
`onClick`.

### Theme

Set your brand once with a CompositionLocal (or pass `theme =` to either
composable). Every value has a default. `MealioThemeProvider` also takes the
dark colors, words, prices and sheet options below.

```kotlin
MealioThemeProvider(MealioTheme(accent = Color(0xFF0A5BD3), radius = 10.dp, fontFamily = myFont)) {
    AppContent()
}
```

| Field | Default | Used for |
| --- | --- | --- |
| `accent` | `#1F6B47` | buttons, checkmarks, selected rings |
| `onAccent` | `#FFFFFF` | text on accent |
| `background` | `#FFFFFF` | the sheet |
| `surface` | `#F2F1EE` | thumbnails, search box, chips |
| `text` / `muted` | `#1B1B1A` / `#5F5D58` | text, secondary text |
| `border` | `#E4E2DD` | card borders |
| `radius` | `14.dp` | cards and buttons |
| `fontFamily` | system | all text |
| `warnBackground` / `warnText` | `#FFF4E5` / `#7A4A06` | out-of-stock notes |

### Dark mode

`colorScheme` is `LIGHT` by default. `DARK` always uses the dark colors, and
`AUTO` follows the phone through `isSystemInDarkTheme()`.

```kotlin
MealioThemeProvider(
    theme = MealioTheme(accent = Color(0xFF0A5BD3), radius = 10.dp),
    darkTheme = MealioDarkTheme(accent = Color(0xFF7FB2FF)), // optional
    colorScheme = MealioColorScheme.AUTO,
) {
    AppContent()
}
```

The default dark colors are `MealioTheme.Dark`. `MealioDarkTheme` lays yours
over them, and a value you leave null keeps the default. `radius` and
`fontFamily` carry over from your light theme unless `MealioDarkTheme` sets
them. Product photos always sit on white.

A `theme =` passed straight to a composable is used as it is. Dark mode applies
to the theme from `MealioThemeProvider`.

### Words

Change or translate any word the sheet shows with `strings`, alongside the
theme. `DEFAULT_STRINGS` has every key.

```kotlin
MealioThemeProvider(
    strings = mapOf(
        "addToCart" to "Add to my Kroger cart",
        "titleList" to "Your {store} shopping list",
        "options_one" to "1 choice",
        "options_other" to "{count} choices",
    ),
) {
    AppContent()
}
```

`{store}`-style placeholders are filled in when the text shows. A placeholder
with no value stays as written, so a typo shows. A key ending `_one` or
`_other` is the singular or plural of the same message. "Cart by Mealio" does
not change. Unit marks like "lb" are not in the table.

The fallback sign-in screen (`MealioLoginActivity`, used only when no flow
sheet is open) has no Compose around it, so `strings` does not reach it.

### Prices

`formatMoney` sets how prices read. The default is `$12.50`.

```kotlin
MealioThemeProvider(formatMoney = { euros.format(it) }) { AppContent() }
```

With it set, option prices come from the numeric `unitPrice` rather than the
store's text. An option with no `unitPrice` keeps the store's text.

### Sheet options

```kotlin
MealioThemeProvider(
    sheet = MealioSheetOptions(
        showTotal = false,
        height = MealioSheetHeight.Fraction(0.8f),
        logo = painterResource(R.drawable.logo),
    ),
) {
    AppContent()
}
```

| Option | Default | What |
| --- | --- | --- |
| `showTotal` | `true` | `false` hides the list total row, the done subtitle price and the done row prices. Options keep their own prices. With `true`, a total shows only when every item has a price. |
| `height` | `Auto` | `Auto` fits a tall sheet, `Full` fills the screen, `Fraction(x)` is a share of the screen, clamped to 0.5..1. |
| `logo` | none | A `Painter`, drawn at 36dp in the sheet header. |

Inside your own composables, `LocalMealioUi.current` gives the same `tr`,
`plural` and `money`.

### Events

`onEvent` on `MealioThemeProvider` reports every step of the sheet as a
`MealioEvent`, for your analytics: `MealioThemeProvider(onEvent = { analytics.track(it.type) }) { AppContent() }`.
`type` is the same name on every Mealio SDK (`sheet_opened`, `store_picked`,
`location_asked`, `signin_shown`, `list_shown`, `item_unchecked`, `item_checked`,
`add_started`, `cart_added`, `error`, `sheet_closed`), and `sheet_closed` carries
the step the user left from. A listener that throws never breaks the sheet.
Nothing is sent to Mealio.

### What the user sees

- **Loading:** "Checking your {store} sign-in", then "Finding your N ingredients".
- **Sign-in:** the store's own page inside the sheet. Mealio never sees the
  password. When no flow sheet is open (you drive the core yourself), the
  sign-in opens in its own full-screen activity instead.
- **List:** every item, every time. Remembered products ("Your usual") come
  back ticked. Unticking leaves an item out of THIS run only; the usual stays
  saved. Each item can show its options, a "sliced or shaved?" preference
  when the product has one, and a search box for something else. The footer
  shows the (estimated) total and "Add N items to {store}".
- **Done:** what was added, what could not be (and why), what was left out.

## Without Compose: the core

```kotlin
lifecycleScope.launch {
    try {
        val stores = MealioCart.stores()                         // public list, no session
        val cart = MealioCart.prepareCart("heb", recipe, zip = "78701") { step, _ -> showProgress(step) }
        for (item in cart.items) {
            // Remembered items arrive selected. Let the USER change things in real UI:
            //   cart.select(item.key, productId, preferenceId)
            //   cart.deselect(item.key)              // left out this run, usual kept
            //   cart.search(item.key, "minced garlic jar")  // adds to cart.options(item.key)
        }
        val est = cart.estimate()                                // total, count, estimated, unpriced
        val result = cart.addToCart()
    } catch (e: MealioException) {
        when (e.code) {
            "store_required" -> { /* no default store yet: ask which store */ }
            "location_required" -> { /* Kroger family: storeLocations, then setStore, or pass zip */ }
            "login_cancelled" -> { /* user closed the sign-in */ }
            "store_unavailable" -> { /* try later */ }
            else -> showError(e.message)
        }
    }
}
```

### When a prepare is cancelled

A cancelled prepare or search throws `MealioException` with code
`"cancelled"` and a `reason`, so a custom screen knows what to do next:

```kotlin
catch (e: MealioException) {
    if (e.code == "cancelled") when (e.reason) {
        CancelReason.USER_CHANGED -> prepareAgain()   // setUser moved to another user: prepare for them
        CancelReason.CLOSED -> Unit                   // your screen closed it (token.cancel(CancelReason.CLOSED))
        else -> Unit                                  // cancelJobs, a store sign-out, resetSession
    }
}
```

After a failed add, prepare a new cart and call `fresh.restorePicks(old)`.
It is a suspend call: a product the user found with `search` is known to
Mealio only on the cart it was found in, so the item's last search runs again
on the new cart (it counts toward the search cap) and the same product is
picked if it comes back. If not, the item keeps the new cart's own pick.

### Sign out of stores

```kotlin
MealioCart.signOutOfStore("heb")
MealioCart.signOutOfAllStores()
```

Both stop a cart still loading, wait for an add under way to end, then clear the store's cookies and web storage on the device and bump a
device "epoch" the SDK sends to Mealio with every job, so the server forgets
any session it held for this device.

**Note:** `CookieManager` and `WebStorage` are process-wide on Android.
`signOutOfAllStores()` clears every cookie and all web storage of **every**
WebView in your app, not only the stores'.

## Public API

```kotlin
// mealio-sdk-compose
@Composable fun MealioCartButton(recipe: Recipe, store: String? = null, zip: String? = null,
    label: String? = null, onAdded: (AddResult) -> Unit = {}, onClose: (AddResult?) -> Unit = {},
    onError: (Exception) -> Unit = {}, modifier: Modifier = Modifier, enabled: Boolean = true,
    theme: MealioTheme = LocalMealioTheme.current, variant: MealioButtonVariant = MealioButtonVariant.SOLID,
    button: (@Composable (onClick: () -> Unit, enabled: Boolean, label: String) -> Unit)? = null,
    doneMessage: String? = null, doneAction: MealioDoneAction? = null, onSignInRequired: (() -> Unit)? = null)
@Composable fun MealioCartFlow(visible: Boolean, recipe: Recipe, store: String? = null, zip: String? = null,
    onClose: (AddResult?) -> Unit, onAdded: (AddResult) -> Unit = {}, onError: (Exception) -> Unit = {},
    theme: MealioTheme = LocalMealioTheme.current, doneMessage: String? = null, doneAction: MealioDoneAction? = null)
// MealioCartButton and MealioCartFlow each have a twin taking `recipes: List<Recipe>` in place of `recipe`.
@Composable fun MealioCartList(cart: CartSession, storeName: String, busy: Boolean, onAdd: () -> Unit,
    modifier: Modifier = Modifier, onChange: () -> Unit = {}, onChangeStore: (() -> Unit)? = null, theme: MealioTheme = ...,
    onChangeLocation: (() -> Unit)? = null)
@Composable fun MealioStoreSettings(visible: Boolean, onClose: () -> Unit, onChange: (StorePreferences) -> Unit = {},
    theme: MealioTheme = LocalMealioTheme.current, onSignInRequired: (() -> Unit)? = null)
data class MealioTheme(accent, onAccent, background, surface, text, muted, border, radius, fontFamily, warnBackground, warnText)
MealioTheme.Default; MealioTheme.Dark
data class MealioDarkTheme(accent, onAccent, background, surface, text, muted, border, radius, fontFamily, warnBackground, warnText) // every value nullable
enum class MealioColorScheme { LIGHT, DARK, AUTO }
enum class MealioButtonVariant { SOLID, OUTLINE, COMPACT, ICON }
data class MealioDoneAction(val label: String, val onClick: (AddResult) -> Unit)
data class MealioSheetOptions(val showTotal: Boolean = true, val height: MealioSheetHeight = MealioSheetHeight.Auto, val logo: Painter? = null)
sealed class MealioSheetHeight { Auto; Full; Fraction(val value: Float) }
class MealioUi : TextTools { val sheet: MealioSheetOptions; val customMoney: Boolean; fun money(amount: Double): String }
val LocalMealioTheme; val LocalMealioUi
@Composable fun MealioThemeProvider(theme: MealioTheme, content: @Composable () -> Unit)   // sets the theme only
@Composable fun MealioThemeProvider(theme: MealioTheme = MealioTheme.Default, darkTheme: MealioDarkTheme? = null,
    colorScheme: MealioColorScheme = MealioColorScheme.LIGHT, strings: Map<String, String> = emptyMap(),
    formatMoney: ((Double) -> String)? = null, sheet: MealioSheetOptions = MealioSheetOptions(),
    onEvent: MealioEventListener? = null, content: @Composable () -> Unit)

// mealio-sdk
object MealioCart {
    const val SDK_VERSION: String
    fun configure(context: Context, publishableKey: String, sessionTokenProvider: suspend () -> String,
                  baseUrl: String = "https://mealio.co", attestationProvider: (suspend () -> String?)? = null)
    val isConfigured: Boolean
    val client: MealioClient
    suspend fun prepareCart(store: String?, recipe: Recipe, zip: String? = null, onStep: StepListener? = null): CartSession
    suspend fun prepareCart(store: String?, recipes: List<Recipe>, zip: String? = null, onStep: StepListener? = null): CartSession
    suspend fun prepareCart(store: String?, recipes: List<Recipe>, zip: String?, cancel: CancelToken, onStep: StepListener? = null): CartSession
    fun setUser(id: String?)                       // null: nobody is signed in
    val user: StateFlow<MealioUser>
    var onSignInRequired: (() -> Unit)?
    fun cancelJobs()                               // stop every cart still loading and every search; an add runs on
                                                   // configure() again does this to the old setup, and queues behind its add
    suspend fun stores(): List<StoreInfo>
    suspend fun storeLocations(store: String, zip: String): List<StoreLocation>   // a Kroger family chain's stores near a zip
    suspend fun storePreferences(): StorePreferences                              // defaultStore, location
    suspend fun setStore(store: String, locationId: String? = null): StorePreferences
    suspend fun signOutOfStore(store: String)
    suspend fun signOutOfAllStores()
}

class CartSession {
    val cartId: String; val store: String; val storeName: String?; val cart: PreparedCart
    val items: List<CartItem>                       // every recipe line, in order
    val recipes: List<CartRecipe>                   // the recipes the cart was made from; empty from older servers
    fun recipesFor(key: String): List<ItemRecipe>   // the recipes an item is for; empty from older servers
    fun options(key: String): List<Product>         // server options + search results, no repeats
    fun selectedId(key: String): String?
    fun isSelected(key: String): Boolean
    fun selected(key: String): Product?
    fun selectedPreferenceId(key: String): String?
    fun selectedCount(): Int
    fun select(key: String, productId: String, preferenceId: String? = null)
    fun deselect(key: String)                       // this run only; the usual is kept
    suspend fun search(key: String, query: String, onStep: StepListener? = null): List<Product>
    suspend fun search(key: String, query: String, cancel: CancelToken, onStep: StepListener? = null): List<Product>
    val searching: Boolean                          // keep Add off while true
    fun cancelSearches(reason: String = CancelReason.CANCELLED)
    suspend fun restorePicks(from: CartSession, cancel: CancelToken = CancelToken(), onStep: StepListener? = null)
                                                    // after a failed add: same store, by item key; a searched pick is searched again here
    val warnings: List<CartWarning>                 // what the server changed or ignored; empty from older servers
    fun quantity(key: String): Int                  // never over the product's cap; what is sent
    fun selections(): List<Selection>               // one per item
    fun estimate(): Estimate                        // total (null if any item is unpriced), count, estimated, unpriced
    fun addedTotal(result: AddResult): Estimate     // same rule, over what the store took
    fun addedPrice(a: AddedItem): LinePrice?        // one added line's price, or null
    suspend fun addToCart(onStep: StepListener? = null): AddResult   // a second call while one runs waits for that one
    // deprecated 0.1: ready, needsChoice, unavailable, choose(), skip(), pending(), selectionFor()
}

enum class ItemStatus { REMEMBERED, CHOOSE, REMEMBERED_UNAVAILABLE, UNAVAILABLE }
enum class Step { CONNECTING, CHECKING_SIGN_IN, SIGNING_IN, SEARCHING, ADDING }
typealias StepListener = (Step, Instruction) -> Unit
fun stepOf(ins: Instruction): Step
data class StoreInfo(val id: String, val name: String, val via: String)
data class CartRecipe(val id: String, val title: String?)
class ItemRecipe(val id: String, val title: String?, val quantity: Int, val share: Double)   // quantity as in 0.5.0 (whole); share is exact (0.5). Binary compatible with 0.5.0
const val MAX_RECIPES = 10
fun forRecipes(cart: CartSession, key: String): String?   // "For Tacos and Pasta"; null unless 2+ recipes
fun forRecipes(cart: CartSession, key: String, text: TextTools): String?   // the same, in the partner's words
val DEFAULT_STRINGS: Map<String, String>                  // every word the drop-in shows, from protocol/strings.json
fun fillText(template: String, vars: Map<String, Any> = emptyMap()): String
open class TextTools(overrides: Map<String, String> = emptyMap()) {
    fun tr(key: String, vararg vars: Pair<String, Any>): String
    fun plural(base: String, count: Int, vararg vars: Pair<String, Any>): String
}
class MealioException(val code: String, message: String, cause: Throwable? = null) : Exception
class CancelToken { val cancelled: Boolean; fun cancel(); fun onCancel(fn: () -> Unit): () -> Unit }
data class CartWarning(val code: String, val message: String)   // ingredients_dropped, lines_dropped, servings_ignored
data class MealioUser(val tracked: Boolean, val id: String?) { val signedIn: Boolean }
sealed class MealioEvent(val type: String)                // one per step: SheetOpened, StorePicked, LocationAsked, SigninShown, ListShown,
                                                          // ItemUnchecked, ItemChecked, AddStarted, CartAdded, Error, SheetClosed
enum class MealioSheetStep(val wire: String) { LOADING, STORES, LOCATION, SIGNIN, LIST, ADDING, DONE, ERROR }
typealias MealioEventListener = (MealioEvent) -> Unit
fun safeListener(fn: MealioEventListener? = null): MealioEventListener
```

`CartItem` has `key, ingredient, quantity, status, options, selectedId,
remembered, rememberedPreferenceId, reason, recipes`. `Product` has `id, name, price,
imageUrl, size, outOfStock, badge, preferences, unitPrice, estimated`.
`AddResult` has `added, skipped, failed, storeCartUrl, verified`. Each
`AddedItem` has `key, productId, name, quantity, weightLb` and, from newer
servers, `imageUrl, ingredient, unitPrice, pricePerLb, estimated`. No partial
totals: `Estimate.total` is null when any counted item has no price, so show
"Prices at checkout" then (PROTOCOL.md, "Totals"). a failed
item with reason `not_confirmed` was sent but not found when the cart was
read back.

Error codes are the ones in PROTOCOL.md: `bad_envelope`, `blocked`,
`store_unavailable`, `login_cancelled`, `session_expired`, `network`,
`unsupported`, plus `session_failed` (your `sessionTokenProvider` threw or took
over 30 seconds; 0.5 and earlier said `session_expired` for this),
`not_signed_in` (`setUser(null)`), `cancelled` (a `CancelToken` fired),
`store_required` (no store given and no default yet),
`location_required` (a Kroger family store with no location chosen, before any
sign-in),
`server` (Mealio answered with an error, or with something that is not JSON), `unknown_item` /
`unknown_product` from `select`, and `bad_recipe` / `too_many_recipes` from
`prepareCart` with no recipes or more than 10.

Every request to Mealio has 30 seconds, then fails with `network`. One job
at a time drives the hidden page: prepare, search, add and warm-up queue
behind each other. An add cannot be cancelled; every wait in it is bounded,
so it ends by itself. While it runs the sheet cannot be closed. The sheet
and its running job survive an activity recreation (rotation, dark mode);
after process death the sheet closes instead of starting a new cart.

There is no separate hello call. `prepareCart`, `search` and `addToCart` each
send `sdk: {platform, version, core, ops}` and `epoch` in their body.

Advanced: `MealioClient(config, host, transport)` lets you supply your own
`Host` (WebViews) or `HttpTransport`. `MealioInlineLogin` is how
`MealioCartFlow` receives the sign-in WebView; a custom sheet can attach to
it the same way.

## Testing your screens: `co.mealio:mealio-sdk-testing`

A separate artifact, for tests only, so none of it can ship in a release app:

```kotlin
testImplementation("co.mealio:mealio-sdk-testing:0.6.0")
testImplementation("org.json:json:20231013") // android.jar's org.json is a stub on the JVM
```

It is a scripted fake Mealio (package `co.mealio.sdk.testing`), so your JVM and Robolectric
tests run the **real** `MealioClient`, `CartSession`, `MealioCart` and drop-in
sheet with no network and no reflection. Scripts are the same plain data as
`@mealio/sdk-core/testing` (`createFakeMealio`). It signs with the protocol
test key, which only a client built with `fake.config()` / `fake.install()`
trusts; `KEYS` in a production build never holds it.

```kotlin
val fake = FakeMealio(FakeScript(
    items = listOf(
        FakeItem("milk", options = listOf(Product("m1", "Milk", unitPrice = 3.0)), remembered = "m1"),
        FakeItem("salt", options = listOf(Product("s1", "Salt")), remembered = "s1", startUnchecked = true),
    ),
    search = mapOf("oat milk" to listOf(Product("o1", "Oat milk", unitPrice = 4.0))),
))

// The core on its own:
val cart = fake.client().prepareCart("heb", recipe)
assertEquals("m1", cart.selectedId("milk")); assertNull(cart.selectedId("salt"))
cart.select("salt", "s1")
assertNull(cart.estimate().total)               // salt has no price: no partial total

// Or MealioCart and MealioCartButton (no Context needed; Robolectric for Compose UI):
fake.install()
MealioCart.setUser("u1")
// ... your screen ...
FakeMealio.uninstall()                          // in @After
```

Under `runTest`, pass your test dispatcher to `install` as well as setting it
as Main. The store sign-outs (`setUser` to a new user, `signOutOfAllStores`)
do IO work, on `Dispatchers.IO` by default. On a real thread, virtual time can
jump past the SDK's sign-out timeouts while that work runs, and the test flakes:

```kotlin
@Test fun signsOut() = runTest {
    val main = StandardTestDispatcher(testScheduler)
    Dispatchers.setMain(main)
    fake.install(io = main)
    MealioCart.setUser("ana"); MealioCart.setUser("ben")
    MealioCart.signOutOfAllStores()
    assertEquals(2, fake.storeEpoch)
}
```

| | |
|---|---|
| `FakeMealio.fromJson(json)`, `FakeScript.fromJson(json)` | a script as JSON with the TypeScript field names, the same text `createFakeMealio` and Swift's `FakeMealio(json:)` take (`signIn: "cancelled"`, `errors: {"search": "network"}`, `add: {"fail": ...}`, `warm: {"signedIn": false}` or `null`). `protocol/fake-script.json` is one every kit runs |
| `FakeScript` | `store`, `storeName`, `items`, `recipes`, `warnings`, `search` (query to products) or `searchWith`, `add` or `addFail`, `signIn` (a `LoginOutcome`, null = already signed in), `errors` (by `FakeKind`: `PREPARE`, `SEARCH`, `ADD`, `WARM`, `STORES`, `PREFERENCES`, `LOCATIONS`, `SESSION`), `stores`, `preferences`, `locations`, `warmSignedIn` |
| `FakeItem` | `key`, `options`, `remembered`, `ingredient`, `quantity` (`Int`), `rememberedPreferenceId`, `rememberedUnavailable`, `startUnchecked`, `weightLb`, `recipes`, `unavailable`, `quantityExact` (`Double`, defaults to `quantity`; set it for TypeScript's other numbers: `1.5`, `3.0e9`. The cart sends it; a non-finite one is sent as null. A JSON script's quantity that is not a whole `Int` lands here, so `FakeItem("a", quantity = 2)` equals a script's `2`) |
| `FakeError(code, message?, status?)` | with `status`: an HTTP error; without: a job that fails with `code` |
| `fake.requests` / `fake.hostCalls` | what the client sent (`FakeRequest(kind, path, body, token)`) and what the store page was asked |
| `fake.hold(kind)` | holds the next request of that kind until the returned function is called (test cancels and user switches) |
| `fake.offered(cartId)` | products a cart offered; an add of anything else fails as `not_offered`, as on the server |
| `fake.install(sessionTokenProvider, io)` | `io`: the dispatcher for the sign-outs' IO work, `Dispatchers.IO` by default; pass your test dispatcher under `runTest` |
| `fake.storeEpoch` | bumped by each store sign-out while installed |
| `fake.config()`, `fake.client()`, `fake.host`, `fake.transport`, `TEST_KEYS`, `signTestEnvelope()` | build your own client |

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
- **Native network blocking.** While Mealio runs a job (from right before
  the job's first script until the job ends, done, failed or cancelled, or
  the store changes; for the sign-in sheet, until it closes), the SDK's
  WebViews refuse state-changing requests (`POST`, `PUT`, `PATCH`, `DELETE`)
  and documents (main-frame and subframe navigations, any method) to
  checkout, payment and the other blocked paths on that store's own hosts
  and its store-owned
  sign-in hosts (albertsons.com and albertsons.okta.com for the Albertsons
  banners, kroger.com and login.kroger.com for the Kroger family) with an
  empty 403. Shared identity providers (`SHARED_IDENTITY_HOSTS`, from
  `protocol/shared-identity-hosts.json`: Google, Apple, Facebook, Microsoft,
  Okta's own pages and other tenants, Auth0, mealio.co) are never blocked.
  Nothing the page does (a navigation, a reload) turns blocking off. The
  store's own page assets (scripts, styles, images, fonts: `GET`s that are
  not documents, whatever their path) and every third-party host (payment
  and captcha iframes included) are never blocked. A subframe document is
  told by its `Accept: text/html` header.
- **Known limit: redirects of fetch, XHR and subresources.** Android WebView
  shows `shouldInterceptRequest` only the URL a request starts with, not the
  redirects that follow. So a fetch to an ordinary path that the store
  redirects to a checkout path is not refused natively (the in-page guard
  still judges what the page asked for). Redirects of a navigation, in any
  frame, reach `shouldOverrideUrlLoading` and are refused.
- **Service worker requests are outside native blocking.** They do not pass
  through a `WebViewClient`, and the SDK never sets the process-wide
  `ServiceWorkerClient`, so any client your app sets stays yours. The in-page
  guard and the allowlist checks still apply.
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
- run: gradle testDebugUnitTest assembleRelease
  working-directory: android
```

Locally, run `gradle wrapper --gradle-version 8.7` once in `android/` and then
`./gradlew testDebugUnitTest assembleRelease` (every module: mealio-sdk, mealio-sdk-compose, mealio-sdk-testing).

The unit tests run on the JVM (JUnit 4):

- `VectorTest` runs every case, allowlist case and matcher case in
  `protocol/test-vectors.json` (copied to `mealio-sdk/src/test/resources/`)
  and must agree with `packages/core/test/core.test.ts`.
- `RunnerTest` covers skip-after-failure, done/fail, the fetch rate cap,
  every refusal reason, allowlist edges and matcher rules, with a fake Host.
  It signs extra envelopes with the same deterministic test key.
- `ClientTest` covers the drive loop, the 401 retry, headers and the
  `sdk`/`epoch` body fields, `recipe` vs `recipes` in the cart body and the
  recipe count limits, the store list, optional store and
  `store_required`, store locations and `location_required`, allowlist
  widening, error mapping, and the 0.1 server
  shape through the deprecated API.
- `CartSessionTest` covers remembered items pre-selected, deselect, search
  merging options, `estimate()` with server unit prices ("2 for $1.05"),
  the estimated flag, `stepOf` and the runner's onStep, and the multi-recipe
  fields (`recipes`, `recipesFor`, `forRecipes`) with and without a newer server.
- `StringsTest` checks `DEFAULT_STRINGS` against `protocol/strings.json`, read
  from the repo rather than copied, so a change to either one fails until the
  other follows. It also covers placeholders, plurals and overrides.
- `GuardScriptTest` checks `GUARD_SCRIPT` and `BRIDGE_SHIM` byte for byte
  against `guard-expected.js` / `bridge-expected.js`, which are the exact
  strings `packages/core/src/guard.ts` produces. If `guard.ts` changes,
  regenerate those two files from it, and copy `protocol/test-vectors.json`
  again when the vectors change. Where the WebView has DOCUMENT_START_SCRIPT, the guard is also
  added with `addDocumentStartJavaScript` for every frame on the stores' hosts,
  so it runs in iframes before the store's own scripts. Older WebViews keep
  the per-script injection only (main frame, its DOM hooks reaching
  same-origin frames).
