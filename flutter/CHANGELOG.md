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
