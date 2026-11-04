// The one-line integration: <MealioCartButton recipe={recipe} store="heb" />,
// or recipes={[...]} to fill one cart from several meals.
// It draws a themed button and runs the whole flow in one sheet.

import React, { useState } from 'react';
import { Pressable, StyleSheet, Text, type StyleProp, type ViewStyle } from 'react-native';
import type { AddResult, MealioError, Recipe } from '@mealio/sdk-core';
import { useMealio } from './MealioProvider';
import { MealioCartFlow } from './MealioCartFlow';

export interface MealioCartButtonProps {
  /** One recipe. Pass this or `recipes`. */
  recipe?: Recipe;
  /** Several recipes in one cart, at most 10. */
  recipes?: Recipe[];
  /** Optional. Without it the user's default store is used, or they pick one. */
  store?: string | null;
  zip?: string | null;
  /** Defaults to "Add to my grocery cart". */
  label?: string;
  onAdded?: (result: AddResult) => void;
  onClose?: (result: AddResult | null) => void;
  onError?: (e: MealioError | Error) => void;
  style?: StyleProp<ViewStyle>;
  disabled?: boolean;
}

export function MealioCartButton(props: MealioCartButtonProps) {
  const { theme: t } = useMealio();
  const [open, setOpen] = useState(false);
  return (
    <>
      <Pressable
        onPress={() => setOpen(true)}
        disabled={props.disabled}
        accessibilityRole="button"
        style={[styles.btn, { backgroundColor: t.accent, borderRadius: t.radius, opacity: props.disabled ? 0.5 : 1 }, props.style]}
      >
        <Text style={[styles.text, { color: t.onAccent, fontFamily: t.fontFamily }]}>{props.label || 'Add to my grocery cart'}</Text>
      </Pressable>
      <MealioCartFlow
        visible={open}
        recipe={props.recipe}
        recipes={props.recipes}
        store={props.store}
        zip={props.zip}
        onAdded={props.onAdded}
        onError={props.onError}
        onClose={(r) => { setOpen(false); props.onClose?.(r); }}
      />
    </>
  );
}

const styles = StyleSheet.create({
  btn: { minHeight: 52, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 20 },
  text: { fontSize: 16, fontWeight: '700' },
});
