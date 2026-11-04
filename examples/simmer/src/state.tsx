// Everything Simmer remembers lives on the phone: favorites, the week's plan,
// what was cooked, a few numbers for the About screen, and a random device id
// that stands in for a signed-in user. No Simmer backend, no database.
//
// The products a user picks are remembered by Mealio, on Mealio's side, under
// that device id. That is the SDK's job, not the app's.

import React, { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState } from 'react';
import AsyncStorage from '@react-native-async-storage/async-storage';
import * as Crypto from 'expo-crypto';
import { RECIPES } from './data/recipes';

export const DAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'] as const;
export type Day = (typeof DAYS)[number];
export const DAY_NAMES: Record<Day, string> = { Mon: 'Monday', Tue: 'Tuesday', Wed: 'Wednesday', Thu: 'Thursday', Fri: 'Friday', Sat: 'Saturday', Sun: 'Sunday' };

export interface Stats { carts: number; meals: number; items: number }

interface Saved {
  favorites: string[];
  plan: Record<Day, string[]>;
  cooked: Record<string, true>;
  zip: string;
  stats: Stats;
}

const EMPTY_PLAN = (): Record<Day, string[]> => ({ Mon: [], Tue: [], Wed: [], Thu: [], Fri: [], Sat: [], Sun: [] });
const EMPTY: Saved = { favorites: [], plan: EMPTY_PLAN(), cooked: {}, zip: '', stats: { carts: 0, meals: 0, items: 0 } };
const KEY = 'simmer:v1';
const DEVICE_KEY = 'simmer:device';

/** A week that shows off a multi-meal cart: shared onion, garlic, rice and limes. */
export const SAMPLE_WEEK: Partial<Record<Day, string>> = {
  Mon: 'taco-salad', Tue: 'beef-broccoli', Wed: 'pesto-pasta', Thu: 'coconut-curry', Fri: 'margherita-flatbread',
};

export const cookedKey = (day: Day, id: string) => `${day}:${id}`;

interface Api extends Saved {
  ready: boolean;
  deviceId: string | null;
  isFavorite(id: string): boolean;
  toggleFavorite(id: string): void;
  addToPlan(day: Day, id: string): void;
  removeFromPlan(day: Day, id: string): void;
  toggleCooked(day: Day, id: string): void;
  planSampleWeek(): void;
  clearPlan(): void;
  setZip(zip: string): void;
  recordCart(meals: number, items: number): void;
  resetAll(): Promise<void>;
}

const Ctx = createContext<Api | null>(null);

export function SimmerProvider({ children }: { children: React.ReactNode }) {
  const [saved, setSaved] = useState<Saved>(EMPTY);
  const [ready, setReady] = useState(false);
  const [deviceId, setDeviceId] = useState<string | null>(null);
  const loaded = useRef(false);

  useEffect(() => {
    (async () => {
      try {
        const raw = await AsyncStorage.getItem(KEY);
        if (raw) {
          const s = JSON.parse(raw) as Partial<Saved>;
          const known = new Set(RECIPES.map((r) => r.id));
          const plan = EMPTY_PLAN();
          for (const d of DAYS) plan[d] = (s.plan?.[d] || []).filter((id) => known.has(id));
          setSaved({ ...EMPTY, ...s, plan, favorites: (s.favorites || []).filter((id) => known.has(id)) });
        }
        let id = await AsyncStorage.getItem(DEVICE_KEY);
        if (!id) {
          id = Crypto.randomUUID().replace(/-/g, '');
          await AsyncStorage.setItem(DEVICE_KEY, id);
        }
        setDeviceId(id);
      } catch {
        // A storage failure is an empty app, not a crash.
      } finally {
        loaded.current = true;
        setReady(true);
      }
    })();
  }, []);

  useEffect(() => {
    if (!loaded.current) return;
    AsyncStorage.setItem(KEY, JSON.stringify(saved)).catch(() => {});
  }, [saved]);

  const update = useCallback((fn: (s: Saved) => Saved) => setSaved((s) => fn(s)), []);

  const api = useMemo<Api>(() => ({
    ...saved,
    ready,
    deviceId,
    isFavorite: (id) => saved.favorites.includes(id),
    toggleFavorite: (id) => update((s) => ({
      ...s, favorites: s.favorites.includes(id) ? s.favorites.filter((x) => x !== id) : [...s.favorites, id],
    })),
    addToPlan: (day, id) => update((s) => (s.plan[day].includes(id) ? s : { ...s, plan: { ...s.plan, [day]: [...s.plan[day], id] } })),
    removeFromPlan: (day, id) => update((s) => {
      const cooked = { ...s.cooked };
      delete cooked[cookedKey(day, id)];
      return { ...s, cooked, plan: { ...s.plan, [day]: s.plan[day].filter((x) => x !== id) } };
    }),
    toggleCooked: (day, id) => update((s) => {
      const cooked = { ...s.cooked };
      const k = cookedKey(day, id);
      if (cooked[k]) delete cooked[k]; else cooked[k] = true;
      return { ...s, cooked };
    }),
    planSampleWeek: () => update((s) => {
      const plan = EMPTY_PLAN();
      for (const d of DAYS) if (SAMPLE_WEEK[d]) plan[d] = [SAMPLE_WEEK[d]!];
      return { ...s, plan, cooked: {} };
    }),
    clearPlan: () => update((s) => ({ ...s, plan: EMPTY_PLAN(), cooked: {} })),
    setZip: (zip) => update((s) => ({ ...s, zip })),
    recordCart: (meals, items) => update((s) => ({
      ...s, stats: { carts: s.stats.carts + 1, meals: s.stats.meals + meals, items: s.stats.items + items },
    })),
    resetAll: async () => {
      setSaved({ ...EMPTY, plan: EMPTY_PLAN() });
      await AsyncStorage.removeItem(KEY).catch(() => {});
    },
  }), [saved, ready, deviceId, update]);

  return <Ctx.Provider value={api}>{children}</Ctx.Provider>;
}

export function useSimmer(): Api {
  const v = useContext(Ctx);
  if (!v) throw new Error('useSimmer outside SimmerProvider');
  return v;
}
