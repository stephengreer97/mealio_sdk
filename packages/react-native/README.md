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

<MealioProvider publishableKey="pk_live_..." getSessionToken={fetchFromYourServer}>
  <MealioCartButton recipe={{ id: 'tacos', title: 'Tacos', ingredients: [{ name: '1 lb ground beef' }] }} />
</MealioProvider>
```

`getSessionToken` calls your own server, which asks Mealio for a session with your secret key. The secret key never ships in the app.

Get keys and read the full guide at https://developers.mealio.co.

Use of this package is subject to the [Mealio Cart SDK License](./LICENSE).
