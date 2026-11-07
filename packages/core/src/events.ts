// What happens in the drop-in sheet, for a partner's analytics. Set `onEvent`
// once and every step arrives here. Nothing is sent to Mealio.

export type MealioEvent =
  | { type: 'sheet_opened'; recipes: number }
  | { type: 'store_picked'; store: string }
  | { type: 'location_asked'; store: string }
  | { type: 'signin_shown'; store: string | null }
  | { type: 'list_shown'; store: string; items: number }
  | { type: 'item_unchecked'; key: string }
  | { type: 'item_checked'; key: string }
  | { type: 'add_started'; items: number }
  | { type: 'cart_added'; store: string; added: number; failed: number }
  | { type: 'error'; code: string; step: MealioSheetStep }
  /** `step` is where they left, so a count per step shows where people drop off. */
  | { type: 'sheet_closed'; step: MealioSheetStep; added: number };

export type MealioSheetStep = 'loading' | 'stores' | 'location' | 'signin' | 'list' | 'adding' | 'done' | 'error';

export type MealioEventListener = (event: MealioEvent) => void;

/** A partner's listener never breaks the sheet. */
export function safeListener(fn?: MealioEventListener | null): MealioEventListener {
  return (e) => {
    if (!fn) return;
    try { fn(e); } catch { /* their code, their log */ }
  };
}
