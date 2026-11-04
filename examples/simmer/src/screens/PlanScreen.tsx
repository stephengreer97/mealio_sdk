// This week. Plan meals by day, tick the ones to shop for, and fill ONE grocery
// cart from all of them. Mealio merges what they share: two recipes that each
// need an onion become one line of two onions.

import React, { useMemo, useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView, useSafeAreaInsets } from 'react-native-safe-area-context';
import { Image } from 'expo-image';
import { Ionicons } from '@expo/vector-icons';
import { useNavigation } from '@react-navigation/native';
import type { NativeStackNavigationProp } from '@react-navigation/native-stack';
import { MealioCartButton, MAX_RECIPES } from '@mealio/react-native-cart';
import { recipeById, toMealioRecipe, type Recipe } from '../data/recipes';
import { cookedKey, DAYS, DAY_NAMES, useSimmer, type Day } from '../state';
import { C, F, R } from '../theme';
import { Button, PoweredByMealio } from '../components/ui';
import type { RootStack } from '../nav';

interface Planned { day: Day; recipe: Recipe; key: string; cooked: boolean }

export default function PlanScreen() {
  const nav = useNavigation<NativeStackNavigationProp<RootStack>>();
  const simmer = useSimmer();
  const insets = useSafeAreaInsets();

  const planned = useMemo<Planned[]>(() => DAYS.flatMap((day) => simmer.plan[day]
    .map((id) => recipeById(id)).filter((r): r is Recipe => !!r)
    .map((recipe) => ({ day, recipe, key: cookedKey(day, recipe.id), cooked: !!simmer.cooked[cookedKey(day, recipe.id)] }))), [simmer.plan, simmer.cooked]);

  // What to shop for: every meal not cooked yet, unless unticked; a cooked meal
  // only when ticked. Kept as the user's exceptions, so a meal planned later is
  // in by default.
  const [flipped, setFlipped] = useState<Set<string>>(new Set());
  const isPicked = (p: Planned) => (p.cooked ? flipped.has(p.key) : !flipped.has(p.key));
  const toggle = (k: string) => setFlipped((prev) => { const n = new Set(prev); if (n.has(k)) n.delete(k); else n.add(k); return n; });

  // The same recipe on two days is one recipe in the cart.
  const recipes = useMemo(() => {
    const seen = new Set<string>();
    return planned.filter(isPicked).map((p) => p.recipe).filter((r) => (seen.has(r.id) ? false : (seen.add(r.id), true)));
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [planned, flipped]);
  const tooMany = recipes.length > MAX_RECIPES;

  if (planned.length === 0) {
    return (
      <SafeAreaView style={s.root} edges={['top']}>
        <Text style={s.title}>This week</Text>
        <View style={s.emptyBox}>
          <Ionicons name="calendar-outline" size={40} color={C.faint} />
          <Text style={s.emptyTitle}>Plan your week</Text>
          <Text style={s.emptyText}>Add recipes to days, then fill one grocery cart with everything you need.</Text>
          <Button label="Plan a sample week" icon="sparkles-outline" onPress={() => { setFlipped(new Set()); simmer.planSampleWeek(); }} style={{ marginTop: 20, alignSelf: 'stretch' }} />
          <Button label="Browse recipes" kind="quiet" onPress={() => nav.navigate('Tabs')} style={{ marginTop: 10, alignSelf: 'stretch' }} />
        </View>
      </SafeAreaView>
    );
  }

  return (
    <SafeAreaView style={s.root} edges={['top']}>
      <ScrollView contentContainerStyle={{ paddingBottom: 170 + insets.bottom }}>
        <View style={s.head}>
          <Text style={s.title}>This week</Text>
          <Pressable onPress={() => { setFlipped(new Set()); simmer.clearPlan(); }} hitSlop={10} accessibilityRole="button">
            <Text style={s.clear}>Clear</Text>
          </Pressable>
        </View>
        <Text style={s.sub}>Tick the meals to shop for. One cart, everything they need.</Text>

        {DAYS.map((day) => {
          const rows = planned.filter((p) => p.day === day);
          return (
            <View key={day} style={s.day}>
              <Text style={s.dayName}>{DAY_NAMES[day]}</Text>
              {rows.length === 0 ? <Text style={s.nothing}>Nothing planned</Text> : rows.map((p) => {
                const on = isPicked(p);
                return (
                  <View key={p.key} style={[s.row, p.cooked && s.rowCooked]}>
                    <Pressable onPress={() => toggle(p.key)} hitSlop={8} accessibilityRole="checkbox"
                      accessibilityState={{ checked: on }} accessibilityLabel={`Shop for ${p.recipe.title}`} style={s.checkSlot}>
                      <View style={[s.box, on && s.boxOn]}>{on ? <Ionicons name="checkmark" size={16} color="#FFFFFF" /> : null}</View>
                    </Pressable>
                    <Pressable style={s.rowMain} onPress={() => nav.navigate('Recipe', { id: p.recipe.id })} accessibilityRole="button">
                      <Image source={p.recipe.image} style={s.thumb} contentFit="cover" />
                      <View style={{ flex: 1 }}>
                        <Text style={[s.rowTitle, p.cooked && s.rowTitleCooked]} numberOfLines={1}>{p.recipe.title}</Text>
                        <Text style={s.rowMeta}>{p.cooked ? 'Cooked' : `${p.recipe.minutes} min · ${p.recipe.ingredients.length} ingredients`}</Text>
                      </View>
                    </Pressable>
                    <Pressable onPress={() => simmer.toggleCooked(p.day, p.recipe.id)} hitSlop={8} accessibilityRole="button"
                      accessibilityLabel={p.cooked ? 'Mark not cooked' : 'Mark cooked'} style={s.icon}>
                      <Ionicons name={p.cooked ? 'checkmark-circle' : 'checkmark-circle-outline'} size={24} color={p.cooked ? C.sage : C.faint} />
                    </Pressable>
                    <Pressable onPress={() => simmer.removeFromPlan(p.day, p.recipe.id)} hitSlop={8} accessibilityRole="button"
                      accessibilityLabel={`Remove ${p.recipe.title}`} style={s.icon}>
                      <Ionicons name="close" size={20} color={C.faint} />
                    </Pressable>
                  </View>
                );
              })}
            </View>
          );
        })}
      </ScrollView>

      <View style={[s.footer, { paddingBottom: 12 + insets.bottom }]}>
        {tooMany ? <Text style={s.warn}>Pick up to {MAX_RECIPES} meals for one cart.</Text> : null}
        <MealioCartButton
          recipes={recipes.map(toMealioRecipe)}
          disabled={recipes.length === 0 || tooMany}
          label={recipes.length === 0 ? 'Tick meals to shop for' : `Add ${recipes.length} meal${recipes.length === 1 ? '' : 's'} to my cart`}
          zip={simmer.zip || null}
          onAdded={(r) => simmer.recordCart(recipes.length, r.added.length)}
          style={{ borderRadius: R.button }}
        />
        <PoweredByMealio style={{ marginTop: 8 }} />
      </View>
    </SafeAreaView>
  );
}

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: C.bg },
  head: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingRight: 20 },
  title: { fontFamily: F.display, fontSize: 28, color: C.text, paddingHorizontal: 20, paddingTop: 12 },
  clear: { fontFamily: F.medium, fontSize: 14, color: C.muted, paddingTop: 12 },
  sub: { fontFamily: F.body, fontSize: 14, color: C.muted, paddingHorizontal: 20, marginTop: 6, marginBottom: 8 },
  day: { paddingHorizontal: 20, marginTop: 16 },
  dayName: { fontFamily: F.semi, fontSize: 13, color: C.muted, textTransform: 'uppercase', letterSpacing: 0.6, marginBottom: 8 },
  nothing: { fontFamily: F.body, fontSize: 14, color: C.faint, paddingVertical: 6 },
  row: {
    flexDirection: 'row', alignItems: 'center', backgroundColor: C.surface, borderRadius: R.card, borderWidth: 1,
    borderColor: C.border, paddingVertical: 8, paddingRight: 6, marginBottom: 8,
  },
  rowCooked: { opacity: 0.65 },
  checkSlot: { width: 46, alignItems: 'center', justifyContent: 'center', alignSelf: 'stretch' },
  box: { width: 24, height: 24, borderRadius: 7, borderWidth: 2, borderColor: C.faint, alignItems: 'center', justifyContent: 'center' },
  boxOn: { backgroundColor: C.accent, borderColor: C.accent },
  rowMain: { flex: 1, flexDirection: 'row', alignItems: 'center', gap: 12 },
  thumb: { width: 52, height: 52, borderRadius: 10, backgroundColor: C.sunken },
  rowTitle: { fontFamily: F.displaySemi, fontSize: 15, color: C.text },
  rowTitleCooked: { textDecorationLine: 'line-through' },
  rowMeta: { fontFamily: F.body, fontSize: 12, color: C.muted, marginTop: 2 },
  icon: { width: 36, height: 44, alignItems: 'center', justifyContent: 'center' },
  emptyBox: { flex: 1, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 32, paddingBottom: 60 },
  emptyTitle: { fontFamily: F.display, fontSize: 22, color: C.text, marginTop: 14 },
  emptyText: { fontFamily: F.body, fontSize: 15, lineHeight: 22, color: C.muted, textAlign: 'center', marginTop: 8 },
  footer: {
    position: 'absolute', left: 0, right: 0, bottom: 0, paddingHorizontal: 20, paddingTop: 12,
    backgroundColor: C.bg, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: C.border,
  },
  warn: { fontFamily: F.medium, fontSize: 13, color: C.accentDark, textAlign: 'center', marginBottom: 8 },
});
