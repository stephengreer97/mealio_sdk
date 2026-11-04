// The whole Mealio integration, on Simmer's side. A partner writes about this
// much code: the provider with its publishable key, and one function that asks
// the partner's own server for a session. The secret key stays on that server
// (examples/simmer-server).

import React, { useCallback, useRef } from 'react';
import AsyncStorage from '@react-native-async-storage/async-storage';
import { MealioProvider, type EpochStorage } from '@mealio/react-native-cart';
import { useSimmer } from './state';
import { C, R } from './theme';

const PUBLISHABLE_KEY = process.env.EXPO_PUBLIC_MEALIO_PK || '';
const SERVER = process.env.EXPO_PUBLIC_SIMMER_SERVER || 'https://simmer-demo-server.vercel.app';
const DEMO_TOKEN = process.env.EXPO_PUBLIC_SIMMER_DEMO_TOKEN || '';

/** Simmer's colors on the Mealio sheet, so the integration looks like part of the app. */
const MEALIO_THEME = { accent: C.accent, onAccent: '#FFFFFF', background: C.bg, surface: C.sunken, text: C.text, muted: C.muted, border: C.border, radius: R.button };

/** Lets "sign out of grocery stores" survive an app restart. */
const epochStorage: EpochStorage = {
  async get() { return Number(await AsyncStorage.getItem('simmer:mealio-epoch').catch(() => null)) || 0; },
  async set(n) { await AsyncStorage.setItem('simmer:mealio-epoch', String(n)).catch(() => {}); },
};

export function SimmerMealio({ children }: { children: React.ReactNode }) {
  const { deviceId } = useSimmer();
  const idRef = useRef(deviceId);
  idRef.current = deviceId;

  const getSessionToken = useCallback(async () => {
    // The device id stands in for Simmer's signed-in user.
    for (let i = 0; i < 20 && !idRef.current; i += 1) await new Promise((r) => setTimeout(r, 100));
    const r = await fetch(`${SERVER}/api/session`, {
      method: 'POST',
      headers: { 'x-simmer-demo-token': DEMO_TOKEN, 'x-simmer-user': idRef.current || 'unknown-device' },
    });
    const body = await r.json().catch(() => ({}));
    if (!r.ok || !body.sessionToken) throw new Error(body.error || body.message || `Simmer's server answered ${r.status}`);
    return body.sessionToken as string;
  }, []);

  return (
    <MealioProvider
      publishableKey={PUBLISHABLE_KEY}
      getSessionToken={getSessionToken}
      epochStorage={epochStorage}
      theme={MEALIO_THEME}
    >
      {children}
    </MealioProvider>
  );
}

export const MEALIO_CONFIGURED = PUBLISHABLE_KEY.startsWith('pk_') && DEMO_TOKEN.length > 0;
