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

export const DEFAULT_DARK_THEME: MealioTheme = {
  accent: '#5FBF8F',
  onAccent: '#0E1A14',
  background: '#1B1B1A',
  surface: '#2A2A28',
  text: '#F2F1EE',
  muted: '#B4B2AC',
  border: '#3A3A37',
  radius: 14,
  fontFamily: undefined,
  warnBackground: '#3B2A10',
  warnText: '#F5C27A',
};

export type MealioColorScheme = 'light' | 'dark' | 'auto';

/**
 * The colors in force. `auto` follows the phone. Partner values lay over the
 * default for that mode, and a dark sheet takes the shared shape (radius, font)
 * from `light` unless `dark` says otherwise.
 */
export function resolveTheme(light?: Partial<MealioTheme>, dark?: Partial<MealioTheme>, scheme: MealioColorScheme = 'light', phone?: string | null): MealioTheme {
  const isDark = scheme === 'dark' || (scheme === 'auto' && phone === 'dark');
  if (!isDark) return { ...DEFAULT_THEME, ...(light || {}) };
  const shape = { ...(light?.radius != null ? { radius: light.radius } : {}), ...(light?.fontFamily ? { fontFamily: light.fontFamily } : {}) };
  return { ...DEFAULT_DARK_THEME, ...shape, ...(dark || {}) };
}

/** "$31.20". Partners replace it with `formatMoney` on the provider. */
export function money(n: number): string {
  return '$' + n.toFixed(2);
}
