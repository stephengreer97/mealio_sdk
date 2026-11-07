// About this demo: what Simmer is, what Mealio did, and the knobs a demo needs.

import React, { useState } from 'react';
import { Alert, Pressable, ScrollView, StyleSheet, Text, TextInput, View } from 'react-native';
import { SafeAreaView } from 'react-native-safe-area-context';
import { Ionicons } from '@expo/vector-icons';
import { useMealio } from '@mealio/react-native-cart';
import { useSimmer } from '../state';
import { MEALIO_CONFIGURED } from '../mealio';
import { C, F, R } from '../theme';
import { Button } from '../components/ui';

export default function AboutScreen({ navigation }: { navigation: { goBack(): void } }) {
  const simmer = useSimmer();
  const mealio = useMealio();
  const [zip, setZip] = useState(simmer.zip);

  const signOut = async () => {
    await mealio.signOutOfAllStores().catch(() => {});
    Alert.alert('Signed out', 'This phone is signed out of every grocery store.');
  };
  const reset = () => Alert.alert('Reset the demo?', 'Clears saved recipes, the plan and the numbers on this screen.', [
    { text: 'Cancel', style: 'cancel' },
    { text: 'Reset', style: 'destructive', onPress: () => { simmer.resetAll(); } },
  ]);

  return (
    <SafeAreaView style={s.root} edges={['top', 'bottom']}>
      <View style={s.bar}>
        <Text style={s.barTitle}>About this demo</Text>
        <Pressable onPress={() => navigation.goBack()} hitSlop={10} accessibilityRole="button" accessibilityLabel="Close">
          <Ionicons name="close" size={26} color={C.text} />
        </Pressable>
      </View>
      <ScrollView contentContainerStyle={s.body}>
        <Text style={s.lead}>
          Simmer is a made-up recipe app. The grocery cart is the real thing: the Mealio Cart SDK, added with one provider and one button.
        </Text>

        <View style={s.stats}>
          <Stat n={simmer.stats.carts} label={simmer.stats.carts === 1 ? 'cart filled' : 'carts filled'} />
          <Stat n={simmer.stats.meals} label={simmer.stats.meals === 1 ? 'meal' : 'meals'} />
          <Stat n={simmer.stats.items} label="items added" />
        </View>

        <Text style={s.h2}>What Mealio does here</Text>
        {[
          ['cart-outline', 'Fills your real grocery cart from any recipe, or a whole week of them.'],
          ['git-merge-outline', 'Merges what meals share. Two recipes with an onion become one line of two onions.'],
          ['bookmark-outline', 'Remembers each product you pick, per recipe, so next time it is already checked.'],
          ['lock-closed-outline', 'You sign in on the store’s own page. Mealio never sees your password and never checks out.'],
        ].map(([icon, text]) => (
          <View key={text} style={s.point}>
            <Ionicons name={icon as any} size={20} color={C.accent} />
            <Text style={s.pointText}>{text}</Text>
          </View>
        ))}

        <Text style={s.h2}>Settings</Text>
        <Text style={s.label}>ZIP code (fills in the Kroger store search)</Text>
        <TextInput value={zip} onChangeText={(t) => setZip(t.replace(/\D/g, '').slice(0, 5))} onEndEditing={() => simmer.setZip(zip)}
          keyboardType="number-pad" placeholder="78704" placeholderTextColor={C.faint} style={s.input} />
        <Button label="Sign out of grocery stores" kind="quiet" icon="log-out-outline" onPress={signOut} style={{ marginTop: 16 }} />
        <Button label="Reset the demo" kind="quiet" icon="refresh-outline" onPress={reset} style={{ marginTop: 10 }} />

        <Text style={s.fine}>
          {MEALIO_CONFIGURED ? 'Mealio sandbox app: Simmer demo' : 'Mealio keys are missing. Copy .env.example to .env.local.'}
          {'\n'}Device id {simmer.deviceId ? simmer.deviceId.slice(0, 8) : '…'} · Photos from Pixabay
        </Text>
      </ScrollView>
    </SafeAreaView>
  );
}

function Stat({ n, label }: { n: number; label: string }) {
  return (
    <View style={s.stat}>
      <Text style={s.statN}>{n}</Text>
      <Text style={s.statLabel}>{label}</Text>
    </View>
  );
}

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: C.bg },
  bar: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 20, paddingVertical: 12 },
  barTitle: { fontFamily: F.display, fontSize: 22, color: C.text },
  body: { paddingHorizontal: 20, paddingBottom: 40 },
  lead: { fontFamily: F.body, fontSize: 16, lineHeight: 24, color: C.text },
  stats: { flexDirection: 'row', gap: 10, marginTop: 20 },
  stat: { flex: 1, backgroundColor: C.surface, borderRadius: R.card, borderWidth: 1, borderColor: C.border, padding: 14 },
  statN: { fontFamily: F.display, fontSize: 28, color: C.accent },
  statLabel: { fontFamily: F.body, fontSize: 12, color: C.muted, marginTop: 2 },
  h2: { fontFamily: F.displaySemi, fontSize: 19, color: C.text, marginTop: 28, marginBottom: 12 },
  point: { flexDirection: 'row', gap: 12, marginBottom: 14 },
  pointText: { flex: 1, fontFamily: F.body, fontSize: 15, lineHeight: 22, color: C.text },
  label: { fontFamily: F.medium, fontSize: 13, color: C.muted, marginBottom: 6 },
  input: {
    height: 48, borderRadius: R.button, borderWidth: 1, borderColor: C.border, backgroundColor: C.surface,
    paddingHorizontal: 14, fontFamily: F.body, fontSize: 16, color: C.text,
  },
  fine: { fontFamily: F.body, fontSize: 12, lineHeight: 18, color: C.faint, marginTop: 28, textAlign: 'center' },
});
