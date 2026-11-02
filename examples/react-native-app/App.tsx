// A recipe app with one button. Run the partner server first, then a dev build:
//   MEALIO_SECRET_KEY=sk_test_... node ../partner-server/server.mjs
//   npx expo run:android
import React, { useState } from 'react';
import { Button, SafeAreaView, Text, View } from 'react-native';
import { MealioProvider, MealioCartSheet, useMealio, type CartSession } from '@mealio/react-native-cart';

const PARTNER_SERVER = 'http://10.0.2.2:8787'; // Android emulator -> your machine
const PUBLISHABLE_KEY = 'pk_test_replace_me';

const RECIPE = {
  id: 'chicken-tinga',
  title: 'Chicken Tinga',
  ingredients: [
    { name: '1.5 lb boneless chicken thighs' },
    { name: '1 yellow onion, sliced' },
    { name: '3 cloves garlic, minced' },
    { name: '1 can chipotle peppers in adobo' },
    { name: '1 can fire roasted tomatoes' },
    { name: 'corn tortillas' },
  ],
};

function Recipe() {
  const mealio = useMealio();
  const [cart, setCart] = useState<CartSession | null>(null);
  const [status, setStatus] = useState('');

  if (cart) {
    return <MealioCartSheet cart={cart} accentColor="#DD0031"
      onDone={(r) => { setCart(null); setStatus(`Added ${r.added.length}, skipped ${r.skipped.length}, failed ${r.failed.length}`); }}
      onError={(e) => setStatus(String(e))} />;
  }
  return (
    <View style={{ padding: 24, gap: 12 }}>
      <Text style={{ fontSize: 24, fontWeight: '700' }}>{RECIPE.title}</Text>
      {RECIPE.ingredients.map((i) => <Text key={i.name}>{i.name}</Text>)}
      <Button title="Add to my H-E-B cart" onPress={async () => {
        setStatus('Getting your cart ready…');
        try { setCart(await mealio.prepareCart({ store: 'heb', zip: '78704', recipe: RECIPE })); setStatus(''); }
        catch (e) { setStatus(String(e)); }
      }} />
      <Text>{status}</Text>
    </View>
  );
}

export default function App() {
  return (
    <SafeAreaView style={{ flex: 1 }}>
      <MealioProvider
        publishableKey={PUBLISHABLE_KEY}
        getSessionToken={async () => {
          const r = await fetch(`${PARTNER_SERVER}/mealio/session`, { method: 'POST' });
          return (await r.json()).sessionToken;
        }}
      >
        <Recipe />
      </MealioProvider>
    </SafeAreaView>
  );
}
