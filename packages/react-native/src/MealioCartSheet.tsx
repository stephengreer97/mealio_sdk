// A ready-made choice screen. Partners who want their own UI read
// cart.needsChoice and call cart.choose() themselves instead.

import React, { useMemo, useState } from 'react';
import { ActivityIndicator, Image, Pressable, ScrollView, StyleSheet, Text, View } from 'react-native';
import type { AddResult, CartItem, CartSession, Product } from '@mealio/sdk-core';

export interface MealioCartSheetProps {
  cart: CartSession;
  onDone: (result: AddResult) => void;
  onError?: (e: unknown) => void;
  accentColor?: string;
}

const BADGE: Record<string, string> = { picked_before: 'You picked this before', popular: 'Popular', partner_pick: 'Recommended' };

export function MealioCartSheet({ cart, onDone, onError, accentColor = '#0a7' }: MealioCartSheetProps) {
  const [picked, setPicked] = useState<Record<string, { productId: string | null; preferenceId?: string | null }>>(() => {
    const init: Record<string, { productId: string | null }> = {};
    for (const it of cart.ready) if (it.chosen) init[it.key] = { productId: it.chosen.id };
    return init;
  });
  const [busy, setBusy] = useState(false);

  const missing = useMemo(() => cart.needsChoice.filter((it) => {
    const p = picked[it.key];
    if (!p) return true;
    if (!p.productId) return false;
    const prod = it.options?.find((o) => o.id === p.productId);
    return !!prod?.preferences?.length && !p.preferenceId;
  }).length, [cart.needsChoice, picked]);

  async function add() {
    setBusy(true);
    try {
      for (const [key, p] of Object.entries(picked)) {
        if (p.productId) cart.choose(key, p.productId, { preferenceId: p.preferenceId ?? null });
        else cart.skip(key);
      }
      onDone(await cart.addToCart());
    } catch (e) {
      onError?.(e);
    } finally {
      setBusy(false);
    }
  }

  const choose = (key: string, productId: string | null, preferenceId?: string | null) =>
    setPicked((cur) => ({ ...cur, [key]: { productId, preferenceId } }));

  return (
    <View style={s.root}>
      <ScrollView contentContainerStyle={s.list}>
        {cart.needsChoice.length > 0 && <Text style={s.h}>Choose products</Text>}
        {cart.needsChoice.map((it) => (
          <ChoiceRow key={it.key} item={it} value={picked[it.key]} onChange={choose} accent={accentColor} />
        ))}
        {cart.ready.length > 0 && <Text style={s.h}>Ready</Text>}
        {cart.ready.map((it) => (
          <View key={it.key} style={s.row}>
            <Text style={s.ing}>{it.ingredient}</Text>
            <Text style={s.prod}>{it.chosen?.name}</Text>
          </View>
        ))}
        {cart.unavailable.length > 0 && <Text style={s.h}>Not found at this store</Text>}
        {cart.unavailable.map((it) => (
          <View key={it.key} style={s.row}><Text style={s.dim}>{it.ingredient}</Text></View>
        ))}
      </ScrollView>
      <Pressable
        accessibilityRole="button"
        disabled={busy || missing > 0}
        onPress={add}
        style={[s.button, { backgroundColor: accentColor, opacity: busy || missing > 0 ? 0.5 : 1 }]}
      >
        {busy ? <ActivityIndicator color="#fff" /> : (
          <Text style={s.buttonText}>{missing > 0 ? `Choose ${missing} more` : 'Add to cart'}</Text>
        )}
      </Pressable>
    </View>
  );
}

function ChoiceRow({ item, value, onChange, accent }: {
  item: CartItem; value?: { productId: string | null; preferenceId?: string | null };
  onChange: (key: string, productId: string | null, preferenceId?: string | null) => void; accent: string;
}) {
  const sel = item.options?.find((o) => o.id === value?.productId);
  return (
    <View style={s.block}>
      <Text style={s.ing}>{item.ingredient}</Text>
      {(item.options || []).map((o: Product) => {
        const on = value?.productId === o.id;
        return (
          <Pressable key={o.id} onPress={() => onChange(item.key, o.id, null)} style={[s.opt, on && { borderColor: accent }]}>
            {o.imageUrl ? <Image source={{ uri: o.imageUrl }} style={s.img} /> : <View style={s.img} />}
            <View style={{ flex: 1 }}>
              <Text style={[s.prod, o.outOfStock && s.dim]}>{o.name}</Text>
              <Text style={s.meta}>{[o.price, o.size, o.outOfStock ? 'Out of stock' : null, o.badge ? BADGE[o.badge] : null].filter(Boolean).join(' · ')}</Text>
            </View>
          </Pressable>
        );
      })}
      {sel?.preferences?.length ? (
        <View style={s.prefs}>
          {sel.preferences.map((p) => (
            <Pressable key={p.id} onPress={() => onChange(item.key, sel.id, p.id)}
              style={[s.pref, value?.preferenceId === p.id && { backgroundColor: accent }]}>
              <Text style={[s.prefText, value?.preferenceId === p.id && { color: '#fff' }]}>{p.label}</Text>
            </Pressable>
          ))}
        </View>
      ) : null}
      <Pressable onPress={() => onChange(item.key, null)}><Text style={s.skip}>{value && value.productId === null ? 'Skipped' : 'Skip this item'}</Text></Pressable>
    </View>
  );
}

const s = StyleSheet.create({
  root: { flex: 1, backgroundColor: '#fff' },
  list: { padding: 16, paddingBottom: 96 },
  h: { fontSize: 13, fontWeight: '700', color: '#666', marginTop: 16, marginBottom: 8, textTransform: 'uppercase' },
  row: { paddingVertical: 10, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: '#ddd' },
  block: { marginBottom: 20 },
  ing: { fontSize: 15, fontWeight: '600', color: '#111', marginBottom: 6 },
  prod: { fontSize: 14, color: '#222' },
  meta: { fontSize: 12, color: '#777', marginTop: 2 },
  dim: { color: '#999' },
  opt: { flexDirection: 'row', alignItems: 'center', gap: 10, padding: 10, borderWidth: 2, borderColor: '#eee', borderRadius: 10, marginBottom: 6 },
  img: { width: 40, height: 40, borderRadius: 6, backgroundColor: '#f2f2f2' },
  prefs: { flexDirection: 'row', flexWrap: 'wrap', gap: 6, marginTop: 4 },
  pref: { paddingHorizontal: 10, paddingVertical: 6, borderRadius: 14, backgroundColor: '#f0f0f0' },
  prefText: { fontSize: 13, color: '#333' },
  skip: { fontSize: 13, color: '#888', marginTop: 4 },
  button: { position: 'absolute', left: 16, right: 16, bottom: 24, height: 52, borderRadius: 12, alignItems: 'center', justifyContent: 'center' },
  buttonText: { color: '#fff', fontSize: 16, fontWeight: '700' },
});
