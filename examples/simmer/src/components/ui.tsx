import React from 'react';
import { Pressable, StyleSheet, Text, View, type StyleProp, type ViewStyle } from 'react-native';
import { Image } from 'expo-image';
import { Ionicons } from '@expo/vector-icons';
import { C, F, R } from '../theme';
import type { Recipe } from '../data/recipes';

export function Chip({ label, on, onPress }: { label: string; on: boolean; onPress: () => void }) {
  return (
    <Pressable onPress={onPress} accessibilityRole="button" accessibilityState={{ selected: on }}
      style={[s.chip, on && s.chipOn]} hitSlop={4}>
      <Text style={[s.chipText, on && s.chipTextOn]}>{label}</Text>
    </Pressable>
  );
}

export function Heart({ on, onPress, size = 20, style }: { on: boolean; onPress: () => void; size?: number; style?: StyleProp<ViewStyle> }) {
  return (
    <Pressable onPress={onPress} hitSlop={10} accessibilityRole="button" accessibilityLabel={on ? 'Remove from saved' : 'Save recipe'}
      style={[s.heart, style]}>
      <Ionicons name={on ? 'heart' : 'heart-outline'} size={size} color={on ? C.accent : C.text} />
    </Pressable>
  );
}

export function Meta({ recipe, style }: { recipe: Recipe; style?: StyleProp<ViewStyle> }) {
  return (
    <View style={[s.meta, style]}>
      <Ionicons name="time-outline" size={13} color={C.muted} />
      <Text style={s.metaText}>{recipe.minutes} min</Text>
      <Text style={s.dot}>·</Text>
      <Text style={s.metaText}>Serves {recipe.serves}</Text>
    </View>
  );
}

export function RecipeCard({ recipe, saved, onToggleSave, onPress, width }: {
  recipe: Recipe; saved: boolean; onToggleSave: () => void; onPress: () => void; width: number;
}) {
  return (
    <Pressable onPress={onPress} style={[s.card, { width }]} accessibilityRole="button" accessibilityLabel={recipe.title}>
      <View>
        <Image source={recipe.image} style={[s.cardImage, { height: width * 0.8 }]} contentFit="cover" transition={150} />
        <Heart on={saved} onPress={onToggleSave} size={18} style={s.cardHeart} />
      </View>
      <Text style={s.cardTitle} numberOfLines={2}>{recipe.title}</Text>
      <Meta recipe={recipe} style={{ marginTop: 4 }} />
    </Pressable>
  );
}

export function Button({ label, onPress, kind = 'primary', icon, style, disabled }: {
  label: string; onPress: () => void; kind?: 'primary' | 'quiet'; icon?: keyof typeof Ionicons.glyphMap; style?: StyleProp<ViewStyle>; disabled?: boolean;
}) {
  const primary = kind === 'primary';
  return (
    <Pressable onPress={onPress} disabled={disabled} accessibilityRole="button"
      style={({ pressed }) => [s.btn, primary ? s.btnPrimary : s.btnQuiet, pressed && { opacity: 0.85 }, disabled && { opacity: 0.5 }, style]}>
      {icon ? <Ionicons name={icon} size={18} color={primary ? '#FFFFFF' : C.text} /> : null}
      <Text style={[s.btnText, { color: primary ? '#FFFFFF' : C.text }]}>{label}</Text>
    </Pressable>
  );
}

export function PoweredByMealio({ style }: { style?: StyleProp<ViewStyle> }) {
  return (
    <View style={[s.powered, style]}>
      <Ionicons name="cart-outline" size={12} color={C.faint} />
      <Text style={s.poweredText}>Grocery cart by Mealio</Text>
    </View>
  );
}

const s = StyleSheet.create({
  chip: { paddingHorizontal: 14, height: 34, borderRadius: R.chip, backgroundColor: C.surface, borderWidth: 1, borderColor: C.border, justifyContent: 'center' },
  chipOn: { backgroundColor: C.text, borderColor: C.text },
  chipText: { fontFamily: F.medium, fontSize: 13, color: C.text },
  chipTextOn: { color: '#FFFFFF' },
  heart: { width: 36, height: 36, borderRadius: 18, backgroundColor: 'rgba(255,255,255,0.92)', alignItems: 'center', justifyContent: 'center' },
  meta: { flexDirection: 'row', alignItems: 'center', gap: 4 },
  metaText: { fontFamily: F.body, fontSize: 12, color: C.muted },
  dot: { color: C.faint, marginHorizontal: 2 },
  card: { marginBottom: 20 },
  cardImage: { width: '100%', borderRadius: R.card, backgroundColor: C.sunken },
  cardHeart: { position: 'absolute', top: 8, right: 8 },
  cardTitle: { fontFamily: F.displaySemi, fontSize: 16, lineHeight: 20, color: C.text, marginTop: 10 },
  btn: { minHeight: 52, borderRadius: R.button, flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 8, paddingHorizontal: 18 },
  btnPrimary: { backgroundColor: C.accent },
  btnQuiet: { backgroundColor: C.surface, borderWidth: 1, borderColor: C.border },
  btnText: { fontFamily: F.semi, fontSize: 15 },
  powered: { flexDirection: 'row', alignItems: 'center', justifyContent: 'center', gap: 4 },
  poweredText: { fontFamily: F.body, fontSize: 11, color: C.faint },
});
