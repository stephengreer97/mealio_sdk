## 0.5.1

- Fixed: signing out of the stores now ends the Mealio session too. Before, a
  second user on the same phone could reuse the first user's session for up to
  15 minutes.
- New: `MealioCart.resetSession()`, for when the signed-in user changes.

## 0.5.0

- The sheet shows a clear message for the monthly cart cap and per-user cart limits.
  The words are the `capReached` and `tooManyCarts` strings.
- `stores()` sends the publishable key, so it lists only the stores your dashboard allows.
- A `store` your app does not offer now shows the store picker.

- Sheet events. `MealioCart.configure`, `MealioScope` and `MealioThemeScope`
  take `onEvent`, which reports every step of the sheet as a `MealioEvent`:
  `sheet_opened`, `store_picked`, `location_asked`, `signin_shown`,
  `list_shown`, `item_unchecked`, `item_checked`, `add_started`, `cart_added`,
  `error` and `sheet_closed`, which carries the `MealioSheetStep` the user left
  from. Nothing is sent to Mealio, and a listener that throws never breaks the
  sheet. New: `mealioSafeListener`, `MealioUi.emit`.
- Kroger family stores: the user chooses their exact store. When a cart answers
  `location_required`, the sheet asks for a zip and lists that chain's stores
  (the store picker comes first if no store is known). The list shows the
  chosen store with a Change link.
- `MealioStoreSettings.show(context)`, also
  `MealioCart.instance.openStoreSettings(context)`: a sheet where the user
  changes their store or zip. Put it on your settings screen.
- New: `MealioCart.storeLocations`, `storePreferences` and `setStore`, the same
  on `MealioClient`; `StoreLocation`, `StorePreferences`,
  `PreparedCart.location`, `CartSession.location`,
  `MealioCartList.onChangeLocation` and
  `MealioErrorCode.locationRequired`.
- Recipe data. `Recipe` gains `servings`, `makeServings` and `photoUrl`;
  `RecipeIngredient` gains `pantry` and `optional`. Each goes to the server
  only when set. Pantry and optional items come back with the new
  `CartItem.startUnchecked`, stay unchecked even with a remembered product,
  and show the new `pantryHint` string until checked. The sheet header shows
  up to 3 recipe photos, https only.
- `MealioCartFlow` and `MealioCartButton` no longer send `zip` to
  `prepareCart`. The parameter stays and fills the zip box.
- Look and text. `MealioCart.configure`, `MealioScope` and `MealioThemeScope`
  now also take `darkTheme`, `colorScheme`, `strings`, `formatMoney` and
  `sheet`. See "Look and text" in the README.
- `strings`: every word the drop-in shows comes from `mealioDefaultStrings`,
  which matches `protocol/strings.json`, with placeholders and `_one`/`_other`
  plurals. New: `MealioUi`, `mealioFillText`.
- `formatMoney`: with it set, option prices use the numeric `unitPrice`.
- Dark mode: `MealioColorScheme` (light, dark, auto), `MealioTheme.dark()`,
  `MealioTheme.standardDark`, `MealioTheme.resolve`. The search button text is
  now `onAccent`, not white.
- `MealioCartButton`: `variant` (`MealioButtonVariant`) and `builder`
  (`MealioCartButtonDetails`) for your own button.
- `MealioSheetOptions`: `showTotal`, `height` (`MealioSheetHeight`) and `logo`.
- Done screen: `doneMessage` and `doneAction` (`MealioDoneAction`) on
  `MealioCartButton`, `MealioCartFlow` and `MealioCartFlow.show`, which also
  gains `onClose`.
- Screen reader labels now come from the table. The busy add button and search
  button keep their own label ("Adding" and "Searching" are gone), the option
  hints are gone, and the done screen's item rows read "For onion, Quantity 2".
- `MealioThemeScope.theme` is now nullable. `MealioTheme.configured` can no
  longer be set directly: use `MealioCart.configure`.

## 0.4.2

- No Flutter changes. React Native's sign-out now uses the maintained
  `@preeternal/react-native-cookie-manager`, falling back to the deprecated
  `@react-native-cookies/cookies`.

## 0.4.1

- No code changes. The release pipeline now publishes npm through Trusted
  Publishing. The iOS SDK installs from GitHub with Swift Package Manager or
  CocoaPods (`:git`, `:tag`); nothing is pushed to CocoaPods Trunk, which stops
  taking releases on 2026-12-02.

## 0.4.0

First public release.

- Security: URLs are parsed strictly by the allowlist (no userinfo, backslash
  or whitespace); identity providers are scoped to the store that uses them;
  the hidden page stays on its store; bridge messages from sub-frames are
  dropped; a signed fetch naming an order or payment is refused; the login
  sheet checks POST navigations.
- Warm-up: `MealioCart.warm()` runs the login check for the user's store
  before they tap, so the cart starts at search. `MealioCartButton` calls it.
- The list says "Pick a product for each item and Mealio will remember your
  preferences." while any item still needs a choice; the footnote is gone.

## 0.3.0

- Several recipes in one cart: `prepareCart(recipes: [...])` on `MealioCart` and
  `MealioClient` (1 to `maxRecipes`, 10). One recipe is still sent as `recipe`, so
  older servers keep working. `bad_recipe` for none and `too_many_recipes` for more
  than 10, both thrown before any request. `recipe` is now optional.
- `PreparedCart.recipes` (`CartRecipe`: `id`, `title`) and `CartItem.recipes`
  (`ItemRecipe`: `id`, `title`, `quantity`). Both null from older servers.
- `CartSession.recipes` and `CartSession.recipesFor(key)`, empty from older servers.
- Drop-in: `MealioCartButton`, `MealioCartFlow` and `MealioCartFlow.show` take
  `recipes`. The header says "N meals", loading counts every recipe's ingredients,
  and on a cart of two or more recipes each row says "For Tacos and Pasta".
  `forRecipes(session, key)` and `forRecipesLabel(count, itemRecipes)` build that line.
- `MealioCartFlow(prepareCarts:)` and the `PrepareCarts` type inject a multi-recipe
  prepare. `prepareCart:` (`PrepareCart`) is unchanged and used for one recipe.
- `sdkCoreVersion` 0.2.0.

## 0.2.0

- Drop-in: `MealioCartButton` and `MealioCartFlow.show` run the whole flow in one
  sheet (loading, store sign-in inside the sheet, list, adding, done, error, store picker).
- `MealioTheme` via `MealioCart.configure(theme:)`, `MealioScope(theme:)` or `MealioThemeScope`.
- `CartSession` is a `ChangeNotifier`: `items`, `options`, `select`, `deselect`, `search`,
  `selections` (every item), `estimate`. `choose`/`skip`/`pending` are deprecated aliases.
- `PreparedCart.items` and `storeName`; `CartItem.status`, `selectedId`, `remembered`,
  `rememberedPreferenceId`; `Product.unitPrice` and `estimated`; `AddResult.verified`;
  `StoreInfo` and `MealioClient.stores()`. 0.1 carts are still read.
- No separate hello call: `sdk` and `epoch` ride on every job-starting call.
  `MealioClient.search` (`POST /api/v1/sdk/carts/{cart}/search`). `prepareCart`'s `store`
  is optional (`store_required` when the user has no default).
- Progress: `MealioStep`, `stepOf`, `onStep` on the client, `CartSession` and `Runner.run`.
- `MealioCartSheet` now reuses `MealioCartList`.
- Finished-run screen: "In your <Store> cart", a banner with the count and total, one row
  per added item (image or initials, product, recipe line, amount, price), a collapsed
  "Left out this time" that opens on its own when an item failed, Done and "Cart by Mealio".
- `AddedItem` gains `imageUrl`, `ingredient`, `unitPrice`, `pricePerLb` and `estimated`.
  `addedPrice()`, `CartSession.addedTotal()` and `CartSession.addedPrice()` price the added lines.
- No partial totals: `CartEstimate.total` is null when any counted item has no price, and the
  list and done screen show "Prices at checkout".

## 0.1.0

- First release. Follows relay protocol v1 (PROTOCOL.md) and packages/core 0.1.0.
- `MealioCart.configure`, `prepareCart`, `CartSession` (`choose`, `skip`, `addToCart`),
  `signOutOfStore` / `signOutOfAllStores`.
- `MealioScope` hosts the hidden store WebView; the login sheet shares its cookies.
- Ed25519 envelope verification, bundled allowlist, GUARD_SCRIPT and fetch rate cap.
- Drop-in `MealioCartSheet`.
