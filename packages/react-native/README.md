# @mealio/react-native-cart

Add a recipe's ingredients to your user's own grocery store cart, from your React Native app. One component draws the button and runs the whole flow in a sheet: store sign-in, product choices, and the add.

```sh
npm install @mealio/react-native-cart react-native-webview
# optional, for "sign out of stores" (New Architecture):
npm install @preeternal/react-native-cookie-manager
# apps still on the old architecture can use @react-native-cookies/cookies instead
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

Get keys and read the full guide at https://developers.mealio.co.

Use of this package is subject to the [Mealio Cart SDK License](./LICENSE).
