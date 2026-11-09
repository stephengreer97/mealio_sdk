# @mealio/react-native-cart

Add a recipe's ingredients to your user's own grocery store cart, from your React Native app. One component draws the button and runs the whole flow in a sheet: store sign-in, product choices, and the add.

```sh
npm install @mealio/react-native-cart react-native-webview
# optional, for "sign out of stores" (New Architecture):
npm install @preeternal/react-native-cookie-manager
# apps still on the old architecture can use @react-native-cookies/cookies instead
# recommended, for the sign-in sheet's insets (most apps have it already):
npm install react-native-safe-area-context
```

```tsx
import { MealioProvider, MealioCartButton } from '@mealio/react-native-cart';

<MealioProvider publishableKey="pk_live_..." getSessionToken={fetchFromYourServer} userId={user?.id ?? null}
  onSignInRequired={() => navigation.navigate('SignIn')}>
  <MealioCartButton recipe={{ id: 'tacos', title: 'Tacos', ingredients: [{ name: '1 lb ground beef' }] }} />
</MealioProvider>
```

`getSessionToken` calls your own server, which asks Mealio for a session with your secret key. The secret key never ships in the app.
If it fails, calls fail with the code `session_failed` and your error's message.

Pass `userId` so a new user never sees the last one's cart: changing it stops a cart in progress, starts a new session and signs the old user out of the stores. While it is null the button calls `onSignInRequired`, or is disabled without one.

In Jest tests, use the ready mock:

```js
jest.mock('@mealio/react-native-cart', () => require('@mealio/react-native-cart/jest'));
```

`mockCart()` gives a cart with every CartSession member. To test a guest, call `setMockUser(null)` from `@mealio/react-native-cart/jest`: `hasUser` is false and the button calls `onSignInRequired`.
The mock resets (`resetMealioMock()`) after every test, so `setMockUser` and scripted answers never leak into the next one, when its after-each hook is registered. Its functions are `jest.fn()`s, typed so `useMealio().prepareCart.mockResolvedValue(mockCart())` type-checks.
The reliable way to register that hook, on any runner, is a setup file (Jest's `setupFilesAfterEnv`, Vitest's `setupFiles`) with `require('@mealio/react-native-cart/jest').setupMealioMock();`: it then runs after every test of every file. Without it, on Jest 29 and 30, the mock registers the hook itself when it first loads while a file is being collected (the usual `jest.mock` line, or a `require` in a `describe` body), on the file's root so it covers every test in the file. When it first loads after tests have started (a `require` inside `beforeAll` or a test, a lazy `require`), it adds no hook, since Jest allows none there, and nothing resets. On other runners (Vitest) it registers the hook where it first loads: at a file's top level it covers the whole file, but first loaded inside a `describe` body it covers only that `describe`, and `setupMealioMock()` there returns true all the same.
With Jest's `resetMocks` (or `restoreMocks`) on, the same setup also puts each default answer back before every test, so `useMealio().prepareCart()` still gives a cart; an answer your test scripts is kept.

To test your own screens built on `useMealio()` against the real client, use the testing kit. No network, no WebView, no `transformIgnorePatterns`, and no `react-native-webview` mock: with `testing` set the provider never loads it:

```tsx
import { createFakeMealio } from '@mealio/react-native-cart/testing';

const fake = createFakeMealio({
  items: [{ key: 'garlic', options: [{ id: 'g1', name: 'Garlic', unitPrice: 0.5 }], remembered: 'g1' }],
  search: { 'minced garlic': [{ id: 'jar', name: 'Minced garlic jar', unitPrice: 3 }] },
});
render(<MealioProvider publishableKey="pk" getSessionToken={async () => 't'} testing={fake}><MyScreen /></MealioProvider>);
// fake.requests, fake.hostCalls, fake.hold('prepare'), fake.script.add = { fail: 'store_unavailable' } ...
```

A prepare that is cancelled fails with `code: 'cancelled'` and a `reason`: `user_changed` (prepare again for the new user), `closed`, or `cancelled`.

Security: every instruction the SDK runs is signed by Mealio, and the SDK checks every page it opens and every request it makes against the store's hosts and blocked checkout paths. Inside the store page an in-page guard also refuses checkout requests; it is best-effort, since code already in the page can get around it. Unlike the iOS and Android SDKs, React Native has no native network blocking: `react-native-webview` gives no hook on the page's own requests. See PROTOCOL.md, "Guard script".

Get keys and read the full guide at https://developers.mealio.co.

Use of this package is subject to the [Mealio Cart SDK License](./LICENSE).
