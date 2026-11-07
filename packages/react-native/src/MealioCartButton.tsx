// The one-line integration: <MealioCartButton recipe={recipe} store="heb" />,
// or recipes={[...]} to fill one cart from several meals.
// It draws a themed button and runs the whole flow in one sheet.

import React, { useEffect, useState, type ReactNode } from 'react';
import { Pressable, StyleSheet, Text, type StyleProp, type ViewStyle } from 'react-native';
import type { AddResult, MealioError, Recipe } from '@mealio/sdk-core';
import { useMealio, useMealioInternal } from './MealioProvider';
import { MealioCartFlow } from './MealioCartFlow';
import type { MealioTheme } from './theme';

export type MealioButtonVariant = 'solid' | 'outline' | 'compact' | 'icon';

export interface MealioCartButtonProps {
  /** One recipe. Pass this or `recipes`. */
  recipe?: Recipe;
  /** Several recipes in one cart, at most 10. */
  recipes?: Recipe[];
  /** Optional. Without it the user's default store is used, or they pick one. */
  store?: string | null;
  zip?: string | null;
  /** Defaults to the `addToCart` string, or `addToCartShort` on a compact button. */
  label?: string;
  /** `solid` (the default), `outline`, `compact` for a recipe card, or `icon`, a round cart button. */
  variant?: MealioButtonVariant;
  /**
   * Draw your own button. It keeps the whole flow and the warm-up: call
   * `onPress` when it is tapped.
   */
  renderButton?: (button: { onPress: () => void; disabled: boolean; label: string }) => ReactNode;
  onAdded?: (result: AddResult) => void;
  onClose?: (result: AddResult | null) => void;
  onError?: (e: MealioError | Error) => void;
  /** A line of your own on the done screen. */
  doneMessage?: string;
  /** A button of your own on the done screen. Tapping it closes the sheet. */
  doneAction?: { label: string; onPress: (result: AddResult) => void };
  style?: StyleProp<ViewStyle>;
  disabled?: boolean;
  /**
   * Called on tap while the provider's `userId` is null. Send the user to your
   * sign-in. With neither this nor the provider's, the button is disabled.
   */
  onSignInRequired?: () => void;
}

export function MealioCartButton(props: MealioCartButtonProps) {
  const mealio = useMealio();
  const t = mealio.theme;
  const { ui } = mealio;
  const variant = props.variant ?? 'solid';
  const label = props.label || ui.tr(variant === 'compact' ? 'addToCartShort' : 'addToCart');
  const internal = useMealioInternal();
  const signIn = mealio.hasUser ? null : props.onSignInRequired ?? internal.onSignInRequired;
  const disabled = !!props.disabled || (!mealio.hasUser && !signIn);
  const onPress = () => { if (signIn) signIn(); else if (mealio.hasUser) setOpen(true); };
  const [open, setOpen] = useState(false);
  // WARM THE LOGIN CHECK while the user reads the recipe. Only for a known user
  // with a store on file: the server answers "nothing to warm" otherwise. The
  // client runs it at most once every few minutes however many buttons mount.
  useEffect(() => {
    if (!disabled && mealio.hasUser) void mealio.warm({ store: props.store ?? null });
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.store, disabled, mealio.userId]);
  return (
    <>
      {props.renderButton ? props.renderButton({ onPress, disabled, label }) : (
        <Pressable
          onPress={onPress}
          disabled={disabled}
          accessibilityRole="button"
          accessibilityLabel={label}
          style={[styles.btn, shapeOf(variant, t), { opacity: disabled ? 0.5 : 1 }, props.style]}
        >
          {variant === 'icon'
            ? <Text style={styles.icon} accessibilityElementsHidden importantForAccessibility="no">🛒</Text>
            : <Text style={[styles.text, variant === 'compact' && styles.compactText, { color: variant === 'outline' ? t.accent : t.onAccent, fontFamily: t.fontFamily }]}>{label}</Text>}
        </Pressable>
      )}
      <MealioCartFlow
        visible={open}
        recipe={props.recipe}
        recipes={props.recipes}
        store={props.store}
        zip={props.zip}
        onAdded={props.onAdded}
        onError={props.onError}
        doneMessage={props.doneMessage}
        doneAction={props.doneAction}
        onClose={(r) => { setOpen(false); props.onClose?.(r); }}
      />
    </>
  );
}

function shapeOf(variant: MealioButtonVariant, t: MealioTheme): ViewStyle {
  if (variant === 'outline') return { backgroundColor: 'transparent', borderWidth: 2, borderColor: t.accent, borderRadius: t.radius };
  if (variant === 'compact') return { backgroundColor: t.accent, borderRadius: t.radius, minHeight: 36, paddingHorizontal: 12, alignSelf: 'flex-start' };
  if (variant === 'icon') return { backgroundColor: t.accent, borderRadius: 24, minHeight: 48, width: 48, paddingHorizontal: 0, alignSelf: 'flex-start' };
  return { backgroundColor: t.accent, borderRadius: t.radius };
}

const styles = StyleSheet.create({
  btn: { minHeight: 52, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 20 },
  text: { fontSize: 16, fontWeight: '700' },
  compactText: { fontSize: 14 },
  icon: { fontSize: 22 },
});
