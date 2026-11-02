// 0.1 compatibility: the list screen on its own, with an add callback.
// New integrations use <MealioCartButton> or <MealioCartFlow>.

import React, { useState } from 'react';
import type { AddResult, CartSession } from '@mealio/sdk-core';
import { useMealio } from './MealioProvider';
import { CartList } from './MealioCartFlow';

export interface MealioCartSheetProps {
  cart: CartSession;
  onDone: (result: AddResult) => void;
  onError?: (e: unknown) => void;
  /** @deprecated set theme on MealioProvider */
  accentColor?: string;
}

export function MealioCartSheet({ cart, onDone, onError, accentColor }: MealioCartSheetProps) {
  const { theme } = useMealio();
  const t = accentColor ? { ...theme, accent: accentColor } : theme;
  const [busy, setBusy] = useState(false);
  const [, setV] = useState(0);
  return (
    <CartList t={t} cart={cart} storeName={cart.cart.storeName || cart.store} busy={busy} onChange={() => setV((v) => v + 1)}
      onAdd={async () => {
        setBusy(true);
        try { onDone(await cart.addToCart()); } catch (e) { onError?.(e); } finally { setBusy(false); }
      }} />
  );
}
