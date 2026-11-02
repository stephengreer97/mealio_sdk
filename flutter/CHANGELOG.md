## 0.1.0

- First release. Follows relay protocol v1 (PROTOCOL.md) and packages/core 0.1.0.
- `MealioCart.configure`, `prepareCart`, `CartSession` (`choose`, `skip`, `addToCart`),
  `signOutOfStore` / `signOutOfAllStores`.
- `MealioScope` hosts the hidden store WebView; the login sheet shares its cookies.
- Ed25519 envelope verification, bundled allowlist, GUARD_SCRIPT and fetch rate cap.
- Drop-in `MealioCartSheet`.
