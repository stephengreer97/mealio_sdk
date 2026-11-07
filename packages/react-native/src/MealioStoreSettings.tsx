// Change the user's store outside a cart: the same store list and the same zip
// and location screens as the cart sheet. Opens with useMealio().openStoreSettings(),
// or render it yourself.

import React, { useCallback, useEffect, useMemo, useState } from 'react';
import { ActivityIndicator, Modal, Platform, KeyboardAvoidingView, Pressable, ScrollView, Text, View } from 'react-native';
import type { StoreInfo, StorePreferences } from '@mealio/sdk-core';
import { useMealio } from './MealioProvider';
import { Header, LocationPicker, sheetStyles } from './MealioCartFlow';

export interface MealioStoreSettingsProps {
  visible: boolean;
  onClose: () => void;
  /** Called each time the user's store changes. */
  onChange?: (preferences: StorePreferences) => void;
}

export function MealioStoreSettings({ visible, onClose, onChange }: MealioStoreSettingsProps) {
  const mealio = useMealio();
  const t = mealio.theme;
  const s = useMemo(() => sheetStyles(t), [t]);
  const [stores, setStores] = useState<StoreInfo[] | null>(null);
  const [prefs, setPrefs] = useState<StorePreferences | null>(null);
  const [picking, setPicking] = useState<StoreInfo | null>(null);
  const [saving, setSaving] = useState<string | null>(null);
  const [problem, setProblem] = useState<string | null>(null);

  const load = useCallback(async () => {
    setProblem(null);
    try {
      const [list, current] = await Promise.all([mealio.stores(), mealio.storePreferences()]);
      setStores(list); setPrefs(current);
    } catch (e: any) {
      setStores([]); setProblem(e?.message || 'Could not load your stores.');
    }
  }, [mealio]);

  useEffect(() => {
    if (!visible) return;
    setPicking(null); setStores(null); setPrefs(null);
    load();
  }, [visible, load]);

  const changed = useCallback((next: StorePreferences) => { setPrefs(next); onChange?.(next); }, [onChange]);

  const choose = useCallback(async (store: StoreInfo) => {
    // A Kroger family store is a chain: the user still has to say which one.
    if (store.via === 'kroger_api') { setPicking(store); return; }
    setSaving(store.id); setProblem(null);
    try {
      changed(await mealio.setStore(store.id));
    } catch (e: any) {
      setProblem(e?.message || 'Could not save that store. Try again.');
    } finally {
      setSaving(null);
    }
  }, [mealio, changed]);

  const samePick = picking && prefs?.defaultStore === picking.id ? prefs.location : null;

  return (
    <Modal visible={visible} transparent animationType="slide" onRequestClose={onClose} statusBarTranslucent>
      <View style={s.scrim}>
        <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : undefined} style={s.sheet}>
          <View style={s.grabber} />
          <Header t={t} title={picking ? `Find your ${picking.name}` : 'Your grocery store'} onClose={onClose} />
          {picking ? (
            <LocationPicker t={t} store={picking.id} storeName={picking.name} zip={samePick?.zip ?? null} current={samePick?.id ?? null}
              onPicked={(location) => { changed({ defaultStore: picking.id, location }); setPicking(null); }}
              back={{ label: 'Back to your stores', onPress: () => setPicking(null) }} />
          ) : !stores ? (
            <View style={s.body}><ActivityIndicator color={t.accent} /></View>
          ) : (
            <View style={s.flex}>
              <ScrollView style={s.flex} contentContainerStyle={s.list}>
                {problem ? <Text style={s.stepText}>{problem}</Text> : null}
                {stores.map((st) => {
                  const current = st.id === prefs?.defaultStore;
                  return (
                    <Pressable key={st.id} onPress={() => choose(st)} disabled={saving !== null} accessibilityRole="radio" accessibilityState={{ selected: current }}
                      testID={`mealio-store-${st.id}`} style={[s.locationOption, current && { borderColor: t.accent, borderWidth: 2 }]}>
                      <View style={s.flex}>
                        <Text style={s.name}>{st.name}</Text>
                        {current && prefs?.location ? <Text style={s.small}>{prefs.location.name}, {prefs.location.address}</Text> : null}
                      </View>
                      {saving === st.id ? <ActivityIndicator size="small" color={t.accent} />
                        : current ? <Text style={[s.small, { color: t.accent }]}>{prefs?.location ? 'Change' : 'Current'}</Text> : null}
                    </Pressable>
                  );
                })}
              </ScrollView>
              <View style={s.footer}>
                <Pressable onPress={onClose} accessibilityRole="button" style={s.cta}><Text style={s.ctaText}>Done</Text></Pressable>
              </View>
            </View>
          )}
        </KeyboardAvoidingView>
      </View>
    </Modal>
  );
}
