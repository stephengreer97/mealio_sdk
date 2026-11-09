# @mealio/sdk-core

The platform-neutral core of the Mealio Cart SDK: protocol types, signature checks, the store allowlist and the relay loop. Apps do not install this directly. Use [`@mealio/react-native-cart`](https://www.npmjs.com/package/@mealio/react-native-cart), which depends on it.

Docs: https://developers.mealio.co

Use of this package is subject to the [Mealio Cart SDK License](./LICENSE).

## Testing your screens

`@mealio/sdk-core/testing` runs the real `MealioClient` and `CartSession` against a scripted fake Mealio, in Jest or Vitest, with no network:

```ts
import { createFakeMealio } from '@mealio/sdk-core/testing';
const fake = createFakeMealio({ items: [{ key: 'milk', options: [{ id: 'm1', name: 'Milk', unitPrice: 3 }], remembered: 'm1' }] });
const client = fake.client();          // or new MealioClient(fake.config({ getSessionToken }), fake.host)
```

Scripts are plain data: items (options, prices, remembered picks, `startUnchecked`, weight items, preferences), search results per query, sign-in, errors by code, warnings, and the add result or failure. It signs with the protocol test key, which a production build never trusts. It loads under plain Jest: no `transformIgnorePatterns` needed.
