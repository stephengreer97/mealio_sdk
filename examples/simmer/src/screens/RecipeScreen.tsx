import React, { useState } from 'react';
import { Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import { SafeAreaView, useSafeAreaInsets } from 'react-native-safe-area-context';
import { Image } from 'expo-image';
import { Ionicons } from '@expo/vector-icons';
import { MealioCartButton } from '@mealio/react-native-cart';
import { recipeById, toMealioRecipe } from '../data/recipes';
import { DAYS, DAY_NAMES, useSimmer, type Day } from '../state';
import { C, F, R } from '../theme';
import { Chip, Heart, Meta, PoweredByMealio } from '../components/ui';
import type { RecipeProps } from '../nav';

export default function RecipeScreen({ route, navigation }: RecipeProps) {
  const recipe = recipeById(route.params.id);
  const simmer = useSimmer();
  const insets = useSafeAreaInsets();
  const [picking, setPicking] = useState(false);
  const [note, setNote] = useState<string | null>(null);
  if (!recipe) return null;

  const plannedOn = DAYS.filter((d) => simmer.plan[d].includes(recipe.id));
  const plan = (d: Day) => {
    simmer.addToPlan(d, recipe.id);
    setPicking(false);
    setNote(`Added to ${DAY_NAMES[d]}`);
  };

  return (
    <View style={s.root}>
      <ScrollView contentContainerStyle={{ paddingBottom: 140 + insets.bottom }}>
        <View>
          <Image source={recipe.image} style={s.hero} contentFit="cover" />
          <SafeAreaView edges={['top']} style={s.heroBar}>
            <Pressable onPress={() => navigation.goBack()} style={s.round} accessibilityRole="button" accessibilityLabel="Back">
              <Ionicons name="chevron-back" size={22} color={C.text} />
            </Pressable>
            <Heart on={simmer.isFavorite(recipe.id)} onPress={() => simmer.toggleFavorite(recipe.id)} />
          </SafeAreaView>
        </View>

        <View style={s.body}>
          <Text style={s.title}>{recipe.title}</Text>
          <Meta recipe={recipe} style={{ marginTop: 8 }} />
          <Text style={s.blurb}>{recipe.blurb}</Text>

          <Pressable onPress={() => setPicking((v) => !v)} style={s.planBtn} accessibilityRole="button">
            <Ionicons name="calendar-outline" size={18} color={C.text} />
            <Text style={s.planText}>
              {plannedOn.length ? `On your plan: ${plannedOn.map((d) => DAY_NAMES[d]).join(', ')}` : 'Add to this week'}
            </Text>
            <Ionicons name={picking ? 'chevron-up' : 'chevron-down'} size={18} color={C.muted} />
          </Pressable>
          {picking ? (
            <View style={s.days}>
              {DAYS.map((d) => <Chip key={d} label={d} on={plannedOn.includes(d)} onPress={() => plan(d)} />)}
            </View>
          ) : null}
          {note ? <Text style={s.note}>{note}</Text> : null}

          <Text style={s.h2}>Ingredients</Text>
          {recipe.ingredients.map((i) => (
            <View key={i.name} style={s.ing}>
              <View style={s.bullet} />
              <Text style={s.ingText}>{i.name}</Text>
            </View>
          ))}

          <Text style={s.h2}>Method</Text>
          {recipe.steps.map((step, n) => (
            <View key={n} style={s.step}>
              <Text style={s.stepNum}>{n + 1}</Text>
              <Text style={s.stepText}>{step}</Text>
            </View>
          ))}
        </View>
      </ScrollView>

      <View style={[s.footer, { paddingBottom: 12 + insets.bottom }]}>
        <MealioCartButton
          recipe={toMealioRecipe(recipe)}
          label={`Add ${recipe.ingredients.length} ingredients to my cart`}
          zip={simmer.zip || null}
          onAdded={(r) => simmer.recordCart(1, r.added.length)}
          style={{ borderRadius: R.button }}
        />
        <PoweredByMealio style={{ marginTop: 8 }} />
      </View>
    </View>
  );
}

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: C.bg },
  hero: { width: '100%', aspectRatio: 1.15, backgroundColor: C.sunken },
  heroBar: { position: 'absolute', left: 0, right: 0, top: 0, flexDirection: 'row', justifyContent: 'space-between', paddingHorizontal: 16, paddingTop: 8 },
  round: { width: 36, height: 36, borderRadius: 18, backgroundColor: 'rgba(255,255,255,0.92)', alignItems: 'center', justifyContent: 'center' },
  body: { paddingHorizontal: 20, paddingTop: 20 },
  title: { fontFamily: F.display, fontSize: 28, lineHeight: 33, color: C.text, letterSpacing: -0.3 },
  blurb: { fontFamily: F.body, fontSize: 15, lineHeight: 22, color: C.muted, marginTop: 12 },
  planBtn: {
    flexDirection: 'row', alignItems: 'center', gap: 10, marginTop: 18, minHeight: 48, paddingHorizontal: 14,
    borderRadius: R.button, backgroundColor: C.surface, borderWidth: 1, borderColor: C.border,
  },
  planText: { flex: 1, fontFamily: F.medium, fontSize: 14, color: C.text },
  days: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, marginTop: 10 },
  note: { fontFamily: F.medium, fontSize: 13, color: C.sage, marginTop: 8 },
  h2: { fontFamily: F.displaySemi, fontSize: 20, color: C.text, marginTop: 28, marginBottom: 10 },
  ing: { flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 9, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: C.border },
  bullet: { width: 6, height: 6, borderRadius: 3, backgroundColor: C.accent },
  ingText: { flex: 1, fontFamily: F.body, fontSize: 15, color: C.text },
  step: { flexDirection: 'row', gap: 14, marginBottom: 14 },
  stepNum: { fontFamily: F.display, fontSize: 18, color: C.accent, width: 20 },
  stepText: { flex: 1, fontFamily: F.body, fontSize: 15, lineHeight: 22, color: C.text },
  footer: {
    position: 'absolute', left: 0, right: 0, bottom: 0, paddingHorizontal: 20, paddingTop: 12,
    backgroundColor: C.bg, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: C.border,
  },
});
