# Simmer

A made-up recipe and meal-planning app with the Mealio Cart SDK built in. It is
for showing prospective partners what a Mealio integration looks like and does.

- **Discover**: 12 recipes with photos, search and tags.
- **Recipe**: ingredients, method, add to a day of the week, and
  **Add N ingredients to my cart** (`MealioCartButton recipe={...}`).
- **This week**: plan meals by day, mark them cooked, tick the ones to shop
  for, and fill one cart from all of them (`MealioCartButton recipes={[...]}`).
  Mealio merges what the meals share.
- **Saved**: favorites.
- **About this demo** (the (i) on Discover): what Mealio did, carts and items
  added so far, ZIP for Kroger stores, sign out of stores, reset.

Everything Simmer keeps (plan, favorites, numbers) is on the phone. There is no
Simmer database. The products a user picks are remembered by Mealio under a
random device id that stands in for a signed-in user.

## How it is wired

```
Simmer app ── pk_test (publishable) ──► Mealio SDK ──► mealio.co relay
     │
     └── POST /api/session ──► simmer-demo-server.vercel.app (holds sk_test)
                                 └── POST mealio.co/api/v1/sessions
```

- `src/mealio.tsx` is the whole integration on the app's side.
- `../simmer-server` is the partner endpoint, deployed as the Vercel project
  `simmer-demo-server`. The secret key never ships in the app.
- Mealio app: **Simmer demo** (sandbox) under the "Mealio (internal test)"
  partner. See developers.mealio.co/dashboard.
- The SDK comes straight from `../../packages` through `metro.config.js`, so a
  change to the SDK shows up on the next reload.

## Run it

Run it as a development build, the same way as the Mealio app. One time:

```bash
cd examples/simmer
cp .env.example .env.local      # fill in from ../simmer-server/.env.local
npm install
eas init                        # once: creates the EAS project
eas device:create               # register the iPhone first
eas build -p ios --profile development
eas build -p android --profile development
```

Day to day:

```bash
npx expo start --dev-client
```

## Demo script

1. Open **This week**, tap **Plan a sample week**. Five meals land on Monday to
   Friday.
2. Tap **Add 5 meals to my cart**. Sign in to a store the first time. The list
   shows each item once, with "For Chicken Taco Salad and Thai Green Coconut
   Curry" under the shared ones.
3. Pick products, add. Run it again: every pick is already checked.
4. Open one recipe on its own: its products are remembered there too.

Photos from Pixabay (see `assets/recipes/CREDITS.txt`).
