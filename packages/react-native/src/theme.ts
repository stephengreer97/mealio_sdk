// The drop-in's look, set once on <MealioProvider theme={...}>. Partners match
// their brand with a handful of values; everything else follows from them.

export interface MealioTheme {
  /** Buttons, checkmarks, selected rings. */
  accent: string;
  /** Text on the accent color. */
  onAccent: string;
  /** Sheet background. */
  background: string;
  /** Page behind cards, search box, thumbnails. */
  surface: string;
  text: string;
  /** Secondary text. Keep 4.5:1 against background. */
  muted: string;
  border: string;
  /** Corner radius of cards and buttons, in points. */
  radius: number;
  /** Font family for every text, or undefined for the system font. */
  fontFamily?: string;
  /** Out-of-stock warning colors. */
  warnBackground: string;
  warnText: string;
}

export const DEFAULT_THEME: MealioTheme = {
  accent: '#1F6B47',
  onAccent: '#FFFFFF',
  background: '#FFFFFF',
  surface: '#F2F1EE',
  text: '#1B1B1A',
  muted: '#5F5D58',
  border: '#E4E2DD',
  radius: 14,
  fontFamily: undefined,
  warnBackground: '#FFF4E5',
  warnText: '#7A4A06',
};

export function resolveTheme(t?: Partial<MealioTheme>): MealioTheme {
  return { ...DEFAULT_THEME, ...(t || {}) };
}

/** "$31.2" style money, two decimals. */
export function money(n: number): string {
  return '$' + n.toFixed(2);
}
