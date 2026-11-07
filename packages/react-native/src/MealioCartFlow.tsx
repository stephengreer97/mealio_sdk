// The drop-in: ONE sheet that runs the whole add-to-cart flow over the
// partner's app. Loading, store sign-in, the list, adding, done.
//
// The list shows EVERY item, every time. Remembered products come back
// pre-selected. Unchecking an item leaves it out of this run only: its
// remembered choice stays for next time. There is no skip button.

import React, { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import {
  ActivityIndicator, Image, KeyboardAvoidingView, Modal, Platform, Pressable, ScrollView, StyleSheet, Text, TextInput, View,
} from 'react-native';
import type { AddedItem, AddResult, CartItem, CartSession, MealioError, Product, Recipe, Step, StoreInfo, StoreLocation } from '@mealio/sdk-core';
import { useMealio, useMealioInternal, type MealioUi } from './MealioProvider';
import type { MealioTheme } from './theme';

export interface MealioCartFlowProps {
  visible: boolean;
  /** One recipe. Pass this or `recipes`. */
  recipe?: Recipe;
  /**
   * Several recipes in one cart (at most 10). Ingredients they share become one
   * item, each item says which recipes it is for, and a pick is remembered
   * under every one of them.
   */
  recipes?: Recipe[];
  /**
   * Store id from GET /api/v1/stores, e.g. "heb". Optional: without it the
   * user's default store is used, and the sheet asks them to pick one the
   * first time. The user can change store from the sheet either way.
   */
  store?: string | null;
  /**
   * 5-digit zip, if you know it. Fills the zip box when a Kroger family store
   * asks the user which store they shop at. Without it, they type it in.
   */
  zip?: string | null;
  /** Called when the sheet closes. `result` is null when nothing was added. */
  onClose: (result: AddResult | null) => void;
  /** Called after the cart is filled, before the user taps Done. */
  onAdded?: (result: AddResult) => void;
  onError?: (e: MealioError | Error) => void;
  /** A line of your own on the done screen, like "Enjoy your meal!". */
  doneMessage?: string;
  /** A button of your own on the done screen, like "Back to meal plan". Tapping it closes the sheet. */
  doneAction?: { label: string; onPress: (result: AddResult) => void };
}

type Phase = 'loading' | 'list' | 'adding' | 'done' | 'error' | 'stores' | 'location';

export function MealioCartFlow(props: MealioCartFlowProps) {
  const { visible } = props;
  const mealio = useMealio();
  const internal = useMealioInternal();
  const t = mealio.theme;
  const { ui } = mealio;
  const [phase, setPhase] = useState<Phase>('loading');
  const [step, setStep] = useState<Step>('connecting');
  const [cart, setCart] = useState<CartSession | null>(null);
  const [result, setResult] = useState<AddResult | null>(null);
  const [error, setError] = useState<{ code: string; message: string } | null>(null);
  const [, setVersion] = useState(0);
  const run = useRef(0);
  const [store, setStore] = useState<string | null>(props.store ?? null);
  const [stores, setStores] = useState<StoreInfo[] | null>(null);
  const backTo = useRef<Phase>('list');
  const bump = useCallback(() => setVersion((v) => v + 1), []);
  const recipes = useMemo(() => props.recipes ?? (props.recipe ? [props.recipe] : []), [props.recipes, props.recipe]);
  const kicker = recipes.length === 1 ? recipes[0].title : recipes.length > 1 ? ui.tr('meals', { count: recipes.length }) : undefined;
  const photos = useMemo(() => recipes.map((r) => r.photoUrl).filter((u): u is string => !!u && u.startsWith('https://')).slice(0, 3), [recipes]);
  const lineCount = useMemo(() => recipes.reduce((n, r) => n + r.ingredients.length, 0), [recipes]);

  useEffect(() => {
    if (!visible) return;
    internal.hostLogin(true);
    return () => internal.hostLogin(false);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [visible]);

  const openStores = useCallback(async (from: Phase) => {
    backTo.current = from;
    setPhase('stores');
    if (!stores) {
      try { setStores(await mealio.stores()); } catch { setStores([]); }
    }
  }, [stores, mealio]);

  const openLocation = useCallback((from: Phase) => { backTo.current = from; setPhase('location'); }, []);

  const start = useCallback(async (storeId: string | null) => {
    const id = ++run.current;
    setPhase('loading'); setStep('connecting'); setCart(null); setResult(null); setError(null);
    try {
      const c = await mealio.prepareCart({ store: storeId, recipes }, { onStep: (s) => run.current === id && setStep(s) });
      if (run.current !== id) return;
      setStore(c.store); setCart(c); setPhase('list');
    } catch (e: any) {
      if (run.current !== id) return;
      if (e?.code === 'store_required') { openStores('error'); return; }
      if (e?.code === 'location_required') {
        // Which store the user shops at is theirs to say. With no store named
        // there is nothing to look up, so they pick the chain first.
        if (storeId) { setStore(storeId); openLocation('error'); } else openStores('error');
        return;
      }
      setError({ code: e?.code || 'error', message: e?.message || ui.tr('somethingWrongSentence') });
      setPhase('error');
      props.onError?.(e);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [recipes]);

  useEffect(() => { if (visible) start(props.store ?? null); else run.current += 1; }, [visible]); // eslint-disable-line react-hooks/exhaustive-deps

  const add = useCallback(async () => {
    if (!cart) return;
    setPhase('adding');
    try {
      const r = await cart.addToCart();
      setResult(r); setPhase('done');
      props.onAdded?.(r);
    } catch (e: any) {
      setError({ code: e?.code || 'error', message: e?.message || ui.tr('couldNotAdd') });
      setPhase('error');
      props.onError?.(e);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [cart]);

  const close = useCallback(() => {
    run.current += 1;
    internal.login?.cancel();
    props.onClose(phase === 'done' ? result : null);
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [phase, result, internal.login]);

  const storeName = cart?.cart.storeName || (store ? storeLabel(store) : ui.tr('yourStore'));
  const named = !!(cart?.cart.storeName || store);
  const s = useMemo(() => styles(t), [t]);

  return (
    <Modal visible={visible} transparent animationType="slide" onRequestClose={close} statusBarTranslucent>
      <View style={s.scrim}>
        <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : undefined} style={[s.sheet, sheetHeight(ui.sheet.height)]}>
          <View style={s.grabber} />
          <Header t={t} recipeTitle={kicker} photos={photos} title={internal.login ? internal.login.title : headerTitle(phase, storeName, named, ui)} onClose={close} />
          {internal.login ? (
            <View style={s.flex}>
              <Text style={s.loginNote}>{ui.tr('loginNote', { store: storeName })}</Text>
              <View style={s.loginWeb}>{internal.login.webview}</View>
            </View>
          ) : phase === 'loading' ? (
            <Loading t={t} step={step} storeName={storeName} count={lineCount} />
          ) : phase === 'stores' ? (
            <StorePicker t={t} stores={stores} current={store} onPick={(id) => { setStore(id); start(id); }}
              onBack={cart && backTo.current === 'list' ? () => setPhase('list') : null} />
          ) : phase === 'location' && store ? (
            <LocationPicker t={t} store={store} storeName={storeName} zip={cart?.cart.location?.zip ?? props.zip ?? null} current={cart?.cart.location?.id ?? null}
              onPicked={() => start(store)}
              back={cart && backTo.current === 'list'
                ? { label: ui.tr('backToList'), onPress: () => setPhase('list') }
                : { label: ui.tr('differentStore'), onPress: () => openStores('error') }} />
          ) : (phase === 'list' || phase === 'adding') && cart ? (
            <CartList t={t} cart={cart} storeName={storeName} busy={phase === 'adding'} onChange={bump} onAdd={add}
              onChangeStore={() => openStores('list')} onChangeLocation={() => openLocation('list')} />
          ) : phase === 'done' && result && cart ? (
            <Done t={t} cart={cart} result={result} storeName={storeName} onDone={close} message={props.doneMessage}
              action={props.doneAction ? { label: props.doneAction.label, onPress: () => { close(); props.doneAction!.onPress(result); } } : null} />
          ) : (
            <ErrorView t={t} error={error} onRetry={() => start(store)} onClose={close} />
          )}
        </KeyboardAvoidingView>
      </View>
    </Modal>
  );
}

function headerTitle(phase: Phase, storeName: string, named: boolean, ui: MealioUi): string {
  const store = { store: storeName };
  if (phase === 'done') return named ? ui.tr('titleInCart', store) : ui.tr('titleInCartPlain');
  if (phase === 'loading') return named ? ui.tr('titleLoading', store) : ui.tr('titleLoadingPlain');
  if (phase === 'error') return ui.tr('somethingWrong');
  if (phase === 'stores') return ui.tr('titleStores');
  if (phase === 'location') return ui.tr('titleLocation', store);
  return ui.tr('titleList', store);
}

/** `auto` keeps the sheet's own height. */
export function sheetHeight(h: 'auto' | 'full' | number) {
  if (h === 'full') return { height: '100%' as const, borderTopLeftRadius: 0, borderTopRightRadius: 0 };
  if (typeof h === 'number') return { height: `${Math.round(Math.min(1, Math.max(0.5, h)) * 100)}%` as `${number}%` };
  return null;
}

function storeLabel(id: string): string {
  const known: Record<string, string> = { heb: 'H-E-B', aldi: 'ALDI', kroger: 'Kroger', safeway: 'Safeway', wegmans: 'Wegmans', qfc: "QFC", frys: "Fry's", smiths: "Smith's", bakers: "Baker's", marianos: "Mariano's", pick_n_save: "Pick 'n Save", pay_less: "Pay-Less" };
  return known[id] || id.replace(/_/g, ' ').replace(/\b\w/g, (m) => m.toUpperCase());
}

// ── pieces ─────────────────────────────────────────────────────────────

export function Header({ t, recipeTitle, title, onClose, photos }: { t: MealioTheme; recipeTitle?: string; title: string; onClose: () => void; photos?: string[] }) {
  const s = styles(t);
  const { ui } = useMealio();
  return (
    <View style={s.header}>
      {ui.sheet.logo ? <Image source={ui.sheet.logo} style={s.logo} resizeMode="contain" accessibilityIgnoresInvertColors /> : null}
      {photos?.length ? (
        <View style={s.photos} testID="mealio-recipe-photos" accessibilityElementsHidden importantForAccessibility="no-hide-descendants">
          {photos.map((uri, i) => <Image key={uri} source={{ uri }} style={[s.photo, i > 0 && s.photoStacked]} resizeMode="cover" accessibilityIgnoresInvertColors />)}
        </View>
      ) : null}
      <View style={s.flex}>
        {recipeTitle ? <Text style={s.kicker} numberOfLines={1}>{recipeTitle}</Text> : null}
        <Text style={s.h1} numberOfLines={2} accessibilityRole="header">{title}</Text>
      </View>
      <Pressable onPress={onClose} accessibilityRole="button" accessibilityLabel={ui.tr('close')} style={s.closeBtn} hitSlop={8}>
        <Text style={s.closeX}>✕</Text>
      </Pressable>
    </View>
  );
}

const STEPS: Array<{ key: Step[]; label: (ui: MealioUi, n: number, store: string) => string }> = [
  { key: ['connecting', 'checking_sign_in', 'signing_in'], label: (ui, _n, store) => ui.tr('stepSignIn', { store }) },
  { key: ['searching'], label: (ui, n) => ui.plural('stepFinding', n) },
];

function Loading({ t, step, storeName, count }: { t: MealioTheme; step: Step; storeName: string; count: number }) {
  const s = styles(t);
  const { ui } = useMealio();
  const at = STEPS.findIndex((x) => x.key.includes(step));
  return (
    <View style={s.body}>
      <Text style={s.muted}>{ui.tr('loadingNote', { store: storeName })}</Text>
      <View style={s.steps}>
        {STEPS.map((x, i) => (
          <View key={i} style={s.stepRow}>
            {i < at ? <View style={[s.dot, { backgroundColor: t.accent }]}><Text style={s.dotCheck}>✓</Text></View>
              : i === at ? <View style={s.dotSpin}><ActivityIndicator size="small" color={t.accent} /></View>
                : <View style={[s.dot, s.dotIdle]} />}
            <Text style={[s.stepText, i === at && s.bold, i > at && s.muted]}>{x.label(ui, count, storeName)}</Text>
          </View>
        ))}
      </View>
      {[0, 1, 2].map((i) => <View key={i} style={s.skeleton} />)}
    </View>
  );
}

export interface CartListProps {
  t: MealioTheme;
  cart: CartSession;
  storeName: string;
  busy: boolean;
  onChange: () => void;
  onAdd: () => void;
  /** Shows a tappable store chip. */
  onChangeStore?: (() => void) | null;
  /** Shows a Change link beside the exact store, on a Kroger family cart. */
  onChangeLocation?: (() => void) | null;
}

/** The list screen on its own, for partners who host it in their own sheet. */
export function CartList({ t, cart, storeName, busy, onChange, onAdd, onChangeStore, onChangeLocation }: CartListProps) {
  const s = styles(t);
  const { ui } = useMealio();
  const [open, setOpen] = useState<string | null>(() => cart.items.find((i) => !i.startUnchecked && (i.status === 'choose' || i.status === 'remembered_unavailable'))?.key ?? null);
  const est = cart.estimate();
  const selectable = cart.items.filter((i) => i.status !== 'unavailable');
  const location = cart.cart.location;
  return (
    <View style={s.flex}>
      {location ? (
        <View style={s.locationRow} testID="mealio-location">
          <Text style={[s.small, s.flex]} numberOfLines={2}>{location.name}, {location.address}</Text>
          {onChangeLocation ? (
            <Pressable onPress={onChangeLocation} disabled={busy} accessibilityRole="button" accessibilityLabel={ui.tr('a11yChangeLocation', { name: location.name })} hitSlop={8}>
              <Text style={[s.small, { color: t.accent }]}>{ui.tr('change')}</Text>
            </Pressable>
          ) : null}
        </View>
      ) : null}
      <View style={s.chipRow}>
        {onChangeStore ? (
          <Pressable onPress={onChangeStore} disabled={busy} accessibilityRole="button" accessibilityLabel={ui.tr('a11yChangeStore', { store: storeName })} style={s.chip}>
            <Text style={s.chipText}>{storeName}</Text>
            <Text style={[s.chipText, { color: t.accent }]}>{ui.tr('change')}</Text>
          </Pressable>
        ) : null}
        <Text style={s.muted}>{ui.tr('selectedCount', { count: est.count, total: selectable.length })}</Text>
      </View>
      {/* Said while any item has no saved product, which on a recipe's first
          cart is every item: the run where nothing on screen shows it yet. */}
      {cart.items.some((i) => i.status === 'choose' && !i.startUnchecked) ? (
        <View style={s.info} testID="mealio-remember-note">
          <Text style={s.infoText}>{ui.tr('rememberNote')}</Text>
        </View>
      ) : null}
      <ScrollView style={s.flex} contentContainerStyle={s.list} keyboardShouldPersistTaps="handled">
        {cart.items.map((it) => (
          <ItemRow key={it.key} t={t} cart={cart} item={it} storeName={storeName} open={open === it.key}
            onToggleOpen={() => setOpen(open === it.key ? null : it.key)} onChange={onChange} disabled={busy} />
        ))}
      </ScrollView>
      <View style={s.footer}>
        {cart.pendingPreferences().length ? (
          <Text style={[s.small, s.pendingNote]}>
            {ui.plural('pendingOptions', cart.pendingPreferences().length)}
          </Text>
        ) : null}
        {/* No partial totals: one unpriced item and there is no number to show. */}
        {ui.sheet.showTotal ? (
          <View style={s.totalRow}>
            <Text style={s.totalLabel}>{ui.tr(est.total != null && est.estimated ? 'estimatedTotal' : 'total')}</Text>
            {est.total != null
              ? <Text style={s.totalValue}>{amountText(ui, est.total, est.estimated)}</Text>
              : <Text style={s.totalNone}>{ui.tr('pricesAtCheckout')}</Text>}
          </View>
        ) : null}
        <Pressable onPress={onAdd} disabled={busy || est.count === 0} accessibilityRole="button"
          style={[s.cta, (busy || est.count === 0) && s.ctaOff]}>
          {busy ? <ActivityIndicator color={t.onAccent} />
            : <Text style={s.ctaText}>{est.count ? ui.plural('addItems', est.count, { store: storeName }) : ui.tr('selectItems')}</Text>}
        </Pressable>
      </View>
    </View>
  );
}

function ItemRow({ t, cart, item, storeName, open, onToggleOpen, onChange, disabled }: {
  t: MealioTheme; cart: CartSession; item: CartItem; storeName: string; open: boolean;
  onToggleOpen: () => void; onChange: () => void; disabled: boolean;
}) {
  const s = styles(t);
  const { ui } = useMealio();
  const [query, setQuery] = useState('');
  const [searching, setSearching] = useState(false);
  const [searchNote, setSearchNote] = useState<string | null>(null);
  const on = cart.isSelected(item.key);
  const picked = cart.selected(item.key);
  const options = cart.options(item.key);
  const shown = picked || (item.status === 'remembered' ? item.remembered : null);

  if (item.status === 'unavailable') {
    return (
      <View style={s.card}>
        <View style={s.rowInner}>
          <View style={s.checkSlot}><View style={[s.box, s.boxDisabled]} /></View>
          <View style={s.flex}>
            <Text style={s.ingredient} numberOfLines={1}>{item.ingredient}</Text>
            <Text style={[s.name, s.muted]}>{ui.tr('notFoundAt', { store: storeName })}</Text>
          </View>
        </View>
      </View>
    );
  }

  const toggle = () => {
    if (disabled) return;
    if (on) cart.deselect(item.key);
    else if (item.status === 'remembered' && item.selectedId) cart.select(item.key, item.selectedId, { preferenceId: item.rememberedPreferenceId ?? null });
    else { if (!open) onToggleOpen(); return; }
    onChange();
  };

  const pick = (p: Product, preferenceId: string | null = null) => {
    if (disabled) return;
    cart.select(item.key, p.id, { preferenceId });
    onChange();
  };

  const search = async () => {
    const q = query.trim();
    if (q.length < 2 || searching) return;
    setSearching(true); setSearchNote(null);
    try {
      const found = await cart.search(item.key, q);
      setSearchNote(found.length ? null : ui.tr('nothingFound', { query: q }));
      setQuery('');
      onChange();
    } catch (e: any) {
      setSearchNote(e?.message || ui.tr('searchFailed'));
    } finally {
      setSearching(false);
    }
  };

  const meta = picked
    ? [priceText(picked, ui), picked.id === item.remembered?.id ? ui.tr('yourUsual') : null].filter(Boolean).join(' · ')
    : item.startUnchecked ? ui.tr('pantryHint')
    : item.status === 'remembered' ? ui.tr('notAddingThisTime')
      : item.status === 'remembered_unavailable' ? ui.tr('usualOutOfStock')
        : ui.plural('options', options.length);

  return (
    <View style={[s.card, open && s.cardOpen]}>
      <View style={s.rowInner}>
        <Pressable onPress={toggle} accessibilityRole="checkbox" accessibilityState={{ checked: on, disabled }}
          accessibilityLabel={ui.tr(on ? 'a11yLeaveOut' : 'a11yAdd', { item: item.ingredient })} style={s.checkSlot}>
          <View style={[s.box, on ? { backgroundColor: t.accent, borderWidth: 0 } : null]}>{on ? <Text style={s.boxCheck}>✓</Text> : null}</View>
        </Pressable>
        <Thumb t={t} product={shown || options[0] || null} dim={!on} />
        <Pressable style={s.flex} onPress={onToggleOpen} accessibilityRole="button">
          <Text style={s.ingredient} numberOfLines={1}>{item.ingredient}</Text>
          {forRecipes(cart, item.key, ui) ? <Text style={s.forRecipes} numberOfLines={1}>{forRecipes(cart, item.key, ui)}</Text> : null}
          <Text style={[s.name, !on && (shown ? s.nameOff : s.namePlaceholder)]} numberOfLines={2}>{shown ? shown.name : ui.tr('chooseProduct')}</Text>
          <Text style={s.small}>{meta}</Text>
        </Pressable>
        <Pressable onPress={onToggleOpen} accessibilityRole="button" accessibilityState={{ expanded: open }} style={s.changeBtn}>
          <Text style={s.change}>{ui.tr(open ? 'done' : on || item.status === 'remembered' ? 'change' : 'choose')}</Text>
        </Pressable>
      </View>

      {on && picked && cart.needsPreference(item.key) ? (
        <Text style={[s.prefNeeded, { color: t.accent }]} accessibilityLiveRegion="polite">
          {ui.tr('chooseOne', { options: listOr((picked.preferences || []).map((p) => p.label), ui) })}
        </Text>
      ) : null}

      {on && picked ? (() => {
        // Sold by weight: the stepper is pounds, stepping through the store's
        // weights (else 0.25 lb). Otherwise a count, clamped to the store cap.
        const byWeight = !!picked.soldByWeight;
        const range = byWeight ? cart.weightRange(item.key) : null;
        const lb = byWeight ? cart.weight(item.key) : 0;
        const n = cart.quantity(item.key);
        const atMin = byWeight ? lb <= range!.min : n <= 1;
        const atMax = byWeight ? lb >= range!.max : n >= cart.maxQuantity(item.key);
        const step = (dir: 1 | -1) => {
          if (byWeight) cart.stepWeight(item.key, dir);
          else cart.setQuantity(item.key, n + dir);
          onChange();
        };
        return (
          <View style={s.qtyRow}>
            <Text style={s.small}>{ui.tr(byWeight ? 'weight' : 'quantity')}</Text>
            <View style={s.stepper}>
              <Pressable onPress={() => step(-1)} disabled={disabled || atMin}
                accessibilityRole="button" accessibilityLabel={ui.tr('a11yLess', { item: item.ingredient })} accessibilityState={{ disabled: disabled || atMin }}
                style={[s.stepBtn, atMin && s.stepOff]}>
                <Text style={s.qtyText}>−</Text>
              </Pressable>
              <Text style={[s.stepValue, byWeight && s.stepValueWide]} accessibilityLabel={`${ui.tr(byWeight ? 'weight' : 'quantity')} ${byWeight ? lbText(lb) : n}`}>
                {byWeight ? lbText(lb) : n}
              </Text>
              <Pressable onPress={() => step(1)} disabled={disabled || atMax}
                accessibilityRole="button" accessibilityLabel={ui.tr('a11yMore', { item: item.ingredient })} accessibilityState={{ disabled: disabled || atMax }}
                style={[s.stepBtn, atMax && s.stepOff]}>
                <Text style={s.qtyText}>+</Text>
              </Pressable>
            </View>
          </View>
        );
      })() : null}

      {item.status === 'remembered_unavailable' && !on ? (
        <View style={s.warn}>
          <Text style={s.warnText}>{item.remembered
            ? ui.tr(item.reason === 'not_found' ? 'usualNotAvailableNamed' : 'usualOutNamed', { name: item.remembered.name })
            : ui.tr(item.reason === 'not_found' ? 'usualNotAvailable' : 'usualOut')}</Text>
        </View>
      ) : null}

      {open ? (
        <View style={s.expand}>
          <ScrollView horizontal showsHorizontalScrollIndicator={false} contentContainerStyle={s.optRow}>
            {options.map((o) => {
              const sel = picked?.id === o.id;
              const usual = o.id === item.remembered?.id;
              return (
                <Pressable key={o.id} onPress={() => pick(o)} accessibilityRole="radio" accessibilityState={{ selected: sel }}
                  style={[s.opt, sel && { borderColor: t.accent, borderWidth: 2, margin: 0 }]}>
                  <Thumb t={t} product={o} big />
                  <Text style={[s.optName, o.outOfStock && s.muted]} numberOfLines={3}>{o.name}</Text>
                  <Text style={s.optPrice}>{o.outOfStock ? ui.tr('outOfStock') : priceText(o, ui)}</Text>
                  {usual ? <Text style={[s.tag, { color: t.accent }]}>{ui.tr('yourUsual')}</Text> : o.badge === 'popular' ? <Text style={s.tag}>{o.badgeLabel || ui.tr('crowdFavorite')}</Text> : null}
                </Pressable>
              );
            })}
          </ScrollView>
          {picked?.preferences?.length ? (
            <View style={s.prefs}>
              {picked.preferences.map((p) => {
                const selPref = cart.preferenceId(item.key) === p.id;
                return (
                  <Pressable key={p.id} onPress={() => pick(picked, p.id)} accessibilityRole="radio" accessibilityState={{ selected: selPref }}
                    style={[s.pref, selPref && { backgroundColor: t.accent }]}>
                    <Text style={[s.prefText, selPref && { color: t.onAccent }]}>{p.label}</Text>
                  </Pressable>
                );
              })}
            </View>
          ) : null}
          <View style={s.searchRow}>
            <TextInput value={query} onChangeText={setQuery} onSubmitEditing={search} returnKeyType="search"
              placeholder={ui.tr('searchPlaceholder', { store: storeName })} placeholderTextColor={t.muted}
              accessibilityLabel={ui.tr('searchPlaceholder', { store: storeName })} style={s.searchInput} editable={!disabled} />
            <Pressable onPress={search} accessibilityRole="button" style={s.searchBtn} disabled={searching}>
              {searching ? <ActivityIndicator color={t.onAccent} /> : <Text style={s.searchBtnText}>{ui.tr('search')}</Text>}
            </Pressable>
          </View>
          {searchNote ? <Text style={[s.small, s.pad12]}>{searchNote}</Text> : null}
        </View>
      ) : null}
    </View>
  );
}

function Thumb({ t, product, dim, big }: { t: MealioTheme; product: Product | null; dim?: boolean; big?: boolean }) {
  const s = styles(t);
  const st = [big ? s.thumbBig : s.thumb, dim ? { opacity: 0.45 } : null];
  return product?.imageUrl
    ? <Image source={{ uri: product.imageUrl }} style={[st, { backgroundColor: '#FFFFFF' }]} resizeMode="contain" accessibilityIgnoresInvertColors />
    : <View style={st} />;
}

/**
 * The finished run. What the store took, row by row (image, product, the
 * recipe line, amount, price), then what was left out. No total unless every
 * added item has a price. No open-cart button: the user's next step is the
 * store's own app or site, not ours.
 */
function Done({ t, cart, result, storeName, onDone, message, action }: {
  t: MealioTheme; cart: CartSession; result: AddResult; storeName: string; onDone: () => void;
  message?: string; action?: { label: string; onPress: () => void } | null;
}) {
  const s = styles(t);
  const { ui } = useMealio();
  const n = result.added.length;
  const sum = cart.addedTotal(result);
  const left = leftOut(cart, result, storeName, ui);
  const [open, setOpen] = useState(() => result.failed.length > 0);
  const subtitle = !ui.sheet.showTotal ? '' : sum.total != null ? amountText(ui, sum.total, sum.estimated) : ui.tr('pricesAtCheckout');
  const title = n ? ui.plural('itemsAdded', n) : ui.tr('nothingAdded');
  return (
    <View style={s.flex}>
      <ScrollView style={s.flex} contentContainerStyle={s.doneBody}>
        <View style={[s.banner, { backgroundColor: n ? soft(t.accent, t.surface) : t.warnBackground }]}
          accessible accessibilityLabel={[title, n ? subtitle : ui.tr('cartUnchanged')].filter(Boolean).join(', ')} accessibilityLiveRegion="polite">
          <View style={[s.bannerIcon, { backgroundColor: n ? t.accent : t.warnText }]}>
            <Text style={[s.bannerCheck, { color: t.onAccent }]}>{n ? '✓' : '!'}</Text>
          </View>
          <View style={s.flex}>
            <Text style={[s.bannerTitle, !n && { color: t.warnText }]}>{title}</Text>
            {(n ? subtitle : true) ? <Text style={[s.bannerSub, !n && { color: t.warnText }]}>{n ? subtitle : ui.tr('cartUnchanged')}</Text> : null}
          </View>
        </View>

        {message ? <Text style={[s.stepText, s.center]} testID="mealio-done-message">{message}</Text> : null}

        {n ? (
          <View style={s.addedCard}>
            {result.added.map((a, i) => <AddedRow key={a.key} t={t} cart={cart} item={a} first={i === 0} />)}
          </View>
        ) : null}

        {left.length ? (
          <View style={s.leftCard}>
            <Pressable onPress={() => setOpen(!open)} accessibilityRole="button" accessibilityState={{ expanded: open }}
              accessibilityLabel={`${ui.tr('leftOut')}: ${left.map((x) => x.label).join(', ')}`} style={s.leftHead}>
              <View style={s.flex}>
                <Text style={s.leftTitle}>{ui.tr('leftOut')}</Text>
                {!open ? <Text style={s.small} numberOfLines={2}>{sentence(left.map((x) => x.label).join(', '))}</Text> : null}
              </View>
              <Text style={s.chevron} accessibilityElementsHidden importantForAccessibility="no">{open ? '▴' : '▾'}</Text>
            </Pressable>
            {open ? left.map((x) => (
              <View key={x.key} style={s.leftRow} accessible accessibilityLabel={`${x.label}, ${x.why}`}>
                <Text style={s.leftName} numberOfLines={2}>{sentence(x.label)}</Text>
                <Text style={[s.small, x.failed && { color: t.warnText }]}>{x.why}</Text>
              </View>
            )) : null}
          </View>
        ) : null}
      </ScrollView>
      <View style={[s.footer, s.doneFooter]}>
        {action ? <Pressable onPress={action.onPress} accessibilityRole="button" testID="mealio-done-action" style={s.cta}><Text style={s.ctaText}>{action.label}</Text></Pressable> : null}
        <Pressable onPress={onDone} accessibilityRole="button" style={[s.cta, action && s.ctaQuiet]}><Text style={[s.ctaText, action && { color: t.text }]}>{ui.tr('done')}</Text></Pressable>
        <Text style={[s.small, s.center]}>Cart by Mealio</Text>
      </View>
    </View>
  );
}

function AddedRow({ t, cart, item, first }: { t: MealioTheme; cart: CartSession; item: AddedItem; first: boolean }) {
  const s = styles(t);
  const { ui } = useMealio();
  const product = cart.selected(item.key);
  const image = item.imageUrl || product?.imageUrl || null;
  const line = item.ingredient || cart.items.find((i) => i.key === item.key)?.ingredient || '';
  const byWeight = typeof item.weightLb === 'number';
  const amount = byWeight ? lbText(item.weightLb as number) : `×${item.quantity}`;
  const p = cart.addedPrice(item);
  const price = p && ui.sheet.showTotal ? amountText(ui, p.amount, p.estimated) : '';
  const spoken = [item.name, line ? ui.tr('forRecipes', { recipes: line }) : null,
    `${ui.tr(byWeight ? 'weight' : 'quantity')} ${byWeight ? amount : item.quantity}`, price || null].filter(Boolean).join(', ');
  return (
    <View style={[s.addedRow, !first && s.addedRule]} accessible accessibilityLabel={spoken}>
      {image
        ? <Image source={{ uri: image }} style={[s.addedThumb, { backgroundColor: '#FFFFFF' }]} resizeMode="contain" accessibilityIgnoresInvertColors />
        : <View style={s.addedThumb}><Text style={s.mono}>{monogram(item.name)}</Text></View>}
      <View style={s.flex}>
        <Text style={s.addedName} numberOfLines={1}>{item.name}</Text>
        {line ? <Text style={s.small} numberOfLines={1}>{line}</Text> : null}
      </View>
      <View style={s.addedEnd}>
        <Text style={s.pill}>{amount}</Text>
        {price ? <Text style={s.small}>{price}</Text> : null}
      </View>
    </View>
  );
}

interface LeftOut { key: string; label: string; why: string; failed: boolean }

/** Everything the store did not take this run: unchecked, skipped, or failed (with its reason). */
function leftOut(cart: CartSession, result: AddResult, storeName: string, ui: MealioUi): LeftOut[] {
  const item = (key: string) => cart.items.find((i) => i.key === key);
  const out: LeftOut[] = [];
  for (const f of result.failed) {
    out.push({ key: f.key, label: item(f.key)?.ingredient || f.name, why: sentence(`${f.name}: ${reasonText(f.reason, ui)}`), failed: true });
  }
  for (const x of result.skipped) {
    const it = item(x.key);
    const why = it?.status === 'unavailable' ? ui.tr('notFoundAt', { store: storeName })
      : ui.tr(x.reason === 'preference_required' ? 'neededOption' : x.reason === 'deselected' ? 'uncheckedThisTime' : 'notChosen');
    out.push({ key: x.key, label: it?.ingredient || x.key, why, failed: false });
  }
  return out;
}

/** First letter up: "Corn tortillas, chipotle peppers". */
function sentence(x: string): string {
  return x ? x[0].toUpperCase() + x.slice(1) : x;
}

/** Two letters for an image-less product tile: "Fresh Yellow Onion" -> "FY". */
function monogram(name: string): string {
  const w = name.replace(/[^A-Za-z0-9 ]+/g, ' ').trim().split(/\s+/).filter(Boolean);
  return ((w[0]?.[0] || '') + (w[1]?.[0] || '')).toUpperCase();
}

/** The accent at 10% for the banner, when it is a hex color; else the surface. */
function soft(color: string, fallback: string): string {
  const m = /^#([0-9a-f]{3}|[0-9a-f]{6})$/i.exec(color.trim());
  if (!m) return fallback;
  const hex = m[1].length === 3 ? m[1].split('').map((c) => c + c).join('') : m[1];
  return `#${hex}1A`;
}

/** "0.75 lb", "1 lb". */
function lbText(lb: number): string {
  return `${+lb.toFixed(2)} lb`;
}

/** The price as a row shows it. Sold by the pound: "$9.99/lb est.". */
/** "A, B or C". */
/** "For Tacos and Pasta", on a cart made from more than one recipe. Null otherwise. */
export function forRecipes(cart: CartSession, key: string, ui?: MealioUi): string | null {
  if (cart.recipes.length < 2) return null;
  const names = cart.recipesFor(key).map((r) => r.title || '').filter(Boolean);
  if (!names.length) return null;
  return ui ? ui.tr('forRecipes', { recipes: listAnd(names, ui) }) : `For ${listAnd(names)}`;
}

function listAnd(xs: string[], ui?: MealioUi): string {
  if (xs.length <= 1) return xs[0] || '';
  const and = ui ? ui.tr('and') : 'and';
  if (xs.length === 2) return `${xs[0]} ${and} ${xs[1]}`;
  return `${xs.slice(0, -1).join(', ')} ${and} ${xs[xs.length - 1]}`;
}

function listOr(xs: string[], ui: MealioUi): string {
  if (xs.length <= 1) return xs[0] || '';
  return `${xs.slice(0, -1).join(', ')} ${ui.tr('or')} ${xs[xs.length - 1]}`;
}

/** "$12.50", or "about $12.50" when the store's own price is an estimate. */
function amountText(ui: MealioUi, amount: number, estimated: boolean): string {
  const price = ui.money(amount);
  return estimated ? ui.tr('aboutPrice', { price }) : price;
}

function priceText(p: Product, ui: MealioUi): string {
  if (p.soldByWeight && typeof p.pricePerLb === 'number') return ui.tr('pricePerLb', { price: ui.money(p.pricePerLb) });
  // The store's own text, unless the partner set how prices read.
  const price = ui.customMoney && typeof p.unitPrice === 'number' ? ui.money(p.unitPrice) : p.price || '';
  return p.estimated && price ? ui.tr('priceEstimate', { price }) : price;
}

function reasonText(r: string, ui: MealioUi): string {
  if (r === 'not_confirmed') return ui.tr('reasonNotConfirmed');
  if (r === 'weight_not_supported') return ui.tr('reasonWeight');
  if (/stock/.test(r)) return ui.tr('reasonOutOfStock');
  if (/timeout|no_answer/.test(r)) return ui.tr('reasonNoAnswer');
  return ui.tr('reasonRefused');
}

const isZip = (z: string) => /^\d{5}$/.test(z);

/**
 * Which Kroger family store the user shops at: a zip box, then that chain's
 * nearby stores. A zip the partner or an earlier pick supplied fills the box
 * and searches at once, and the user still taps the store they want. Used in
 * the cart sheet and in store settings.
 */
export function LocationPicker({ t, store, storeName, zip: startZip, current, onPicked, back }: {
  t: MealioTheme; store: string; storeName: string; zip: string | null; current: string | null;
  onPicked: (location: StoreLocation) => void;
  back: { label: string; onPress: () => void };
}) {
  const s = styles(t);
  const mealio = useMealio();
  const { ui } = mealio;
  const [zip, setZip] = useState(startZip ?? '');
  const [found, setFound] = useState<{ zip: string; locations: StoreLocation[] } | null>(null);
  const [busy, setBusy] = useState(false);
  const [saving, setSaving] = useState<string | null>(null);
  const [problem, setProblem] = useState<string | null>(null);
  const ask = useRef(0);
  const mounted = useRef(true);
  useEffect(() => { mounted.current = true; return () => { mounted.current = false; }; }, []);

  const find = useCallback(async (z: string) => {
    const id = ++ask.current;
    setBusy(true); setProblem(null); setFound(null);
    try {
      const locations = await mealio.storeLocations(store, z);
      if (ask.current === id) setFound({ zip: z, locations });
    } catch (e: any) {
      if (ask.current === id) setProblem(e?.message || ui.tr('couldNotLookUp'));
    } finally {
      if (ask.current === id) setBusy(false);
    }
  }, [mealio, store]);

  useEffect(() => { if (startZip && isZip(startZip)) find(startZip); }, []); // eslint-disable-line react-hooks/exhaustive-deps

  const pick = useCallback(async (l: StoreLocation) => {
    setSaving(l.id); setProblem(null);
    try {
      await mealio.setStore(store, l.id);
      // Closed while saving: the store is saved, and no cart should start.
      if (mounted.current) onPicked(l);
    } catch (e: any) {
      if (!mounted.current) return;
      setProblem(e?.message || ui.tr('couldNotSaveStore'));
      setSaving(null);
    }
  }, [mealio, store, onPicked]);

  return (
    <View style={s.flex}>
      <ScrollView style={s.flex} contentContainerStyle={s.list} keyboardShouldPersistTaps="handled">
        <Text style={s.muted}>{ui.tr('zipPrompt', { store: storeName })}</Text>
        <View style={s.zipRow}>
          <TextInput value={zip} onChangeText={(v) => setZip(v.replace(/\D/g, '').slice(0, 5))} onSubmitEditing={() => isZip(zip) && find(zip)}
            keyboardType="number-pad" returnKeyType="search" maxLength={5} placeholder={ui.tr('zipCode')} placeholderTextColor={t.muted}
            accessibilityLabel={ui.tr('zipCode')} testID="mealio-zip" style={s.zipInput} />
          <Pressable onPress={() => find(zip)} disabled={!isZip(zip) || busy} accessibilityRole="button" testID="mealio-find-stores"
            style={[s.zipBtn, (!isZip(zip) || busy) && { opacity: 0.5 }]}>
            <Text style={s.ctaText}>{ui.tr('findStores')}</Text>
          </Pressable>
        </View>
        {busy ? <ActivityIndicator color={t.accent} /> : null}
        {problem ? <Text style={s.stepText}>{problem}</Text> : null}
        {found && found.locations.length === 0 ? <Text style={s.muted}>{ui.tr('noStoresNear', { store: storeName, zip: found.zip })}</Text> : null}
        {found?.locations.map((l) => (
          <Pressable key={l.id} onPress={() => pick(l)} disabled={saving !== null} accessibilityRole="radio" accessibilityState={{ selected: l.id === current }}
            testID={`mealio-location-${l.id}`} style={[s.locationOption, l.id === current && { borderColor: t.accent, borderWidth: 2 }]}>
            <View style={s.flex}>
              <Text style={s.name}>{l.name}</Text>
              <Text style={s.small}>{l.address}</Text>
            </View>
            {saving === l.id ? <ActivityIndicator size="small" color={t.accent} />
              : l.id === current ? <Text style={[s.small, { color: t.accent }]}>{ui.tr('current')}</Text> : null}
          </Pressable>
        ))}
      </ScrollView>
      <View style={s.footer}>
        <Pressable onPress={back.onPress} accessibilityRole="button" style={[s.cta, s.ctaQuiet]}><Text style={[s.ctaText, { color: t.text }]}>{back.label}</Text></Pressable>
      </View>
    </View>
  );
}

export function StorePicker({ t, stores, current, onPick, onBack }: {
  t: MealioTheme; stores: StoreInfo[] | null; current: string | null; onPick: (id: string) => void; onBack: (() => void) | null;
}) {
  const s = styles(t);
  const { ui } = useMealio();
  if (!stores) return <View style={s.body}><ActivityIndicator color={t.accent} /></View>;
  return (
    <View style={s.flex}>
      <ScrollView style={s.flex} contentContainerStyle={s.list}>
        {stores.length === 0 ? <Text style={s.muted}>{ui.tr('couldNotLoadStores')}</Text> : null}
        {stores.map((st) => (
          <Pressable key={st.id} onPress={() => onPick(st.id)} accessibilityRole="radio" accessibilityState={{ selected: st.id === current }}
            style={[s.storeRow, st.id === current && { borderColor: t.accent, borderWidth: 2 }]}>
            <Text style={s.name}>{st.name}</Text>
            {st.id === current ? <Text style={[s.small, { color: t.accent }]}>{ui.tr('current')}</Text> : null}
          </Pressable>
        ))}
      </ScrollView>
      {onBack ? (
        <View style={s.footer}>
          <Pressable onPress={onBack} accessibilityRole="button" style={[s.cta, s.ctaQuiet]}><Text style={[s.ctaText, { color: t.text }]}>{ui.tr('backToList')}</Text></Pressable>
        </View>
      ) : null}
    </View>
  );
}

function ErrorView({ t, error, onRetry, onClose }: { t: MealioTheme; error: { code: string; message: string } | null; onRetry: () => void; onClose: () => void }) {
  const s = styles(t);
  const { ui } = useMealio();
  const msg = error?.code === 'login_cancelled' ? ui.tr('signInClosed') : error?.message || ui.tr('somethingWrongSentence');
  return (
    <View style={[s.body, s.flex]}>
      <Text style={s.stepText}>{msg}</Text>
      <View style={s.flex} />
      <Pressable onPress={onRetry} accessibilityRole="button" style={s.cta}><Text style={s.ctaText}>{ui.tr('tryAgain')}</Text></Pressable>
      <Pressable onPress={onClose} accessibilityRole="button" style={[s.cta, s.ctaQuiet]}><Text style={[s.ctaText, { color: t.text }]}>{ui.tr('close')}</Text></Pressable>
    </View>
  );
}

/** The sheet's styles, for the other screens built from these pieces. */
export const sheetStyles = (t: MealioTheme) => styles(t);

// ── styles ─────────────────────────────────────────────────────────────

const cache = new WeakMap<MealioTheme, ReturnType<typeof make>>();
function styles(t: MealioTheme) {
  let v = cache.get(t);
  if (!v) { v = make(t); cache.set(t, v); }
  return v;
}

function make(t: MealioTheme) {
  const f = t.fontFamily ? { fontFamily: t.fontFamily } : {};
  return StyleSheet.create({
    flex: { flex: 1 },
    scrim: { flex: 1, backgroundColor: 'rgba(0,0,0,0.35)', justifyContent: 'flex-end' },
    sheet: { height: '94%', backgroundColor: t.background, borderTopLeftRadius: 20, borderTopRightRadius: 20, overflow: 'hidden' },
    photos: { flexDirection: 'row' },
    photo: { width: 44, height: 44, borderRadius: t.radius / 2, backgroundColor: t.surface, borderWidth: 2, borderColor: t.background },
    photoStacked: { marginLeft: -18 },
    logo: { width: 36, height: 36, borderRadius: 8 },
    grabber: { alignSelf: 'center', width: 36, height: 5, borderRadius: 3, backgroundColor: t.border, marginTop: 8 },
    header: { flexDirection: 'row', alignItems: 'flex-start', gap: 12, paddingHorizontal: 20, paddingTop: 12, paddingBottom: 8 },
    kicker: { ...f, fontSize: 13, fontWeight: '500', color: t.muted },
    h1: { ...f, fontSize: 22, lineHeight: 28, fontWeight: '700', color: t.text },
    h2: { ...f, fontSize: 22, lineHeight: 28, fontWeight: '700', color: t.text, textAlign: 'center' },
    closeBtn: { width: 44, height: 44, borderRadius: 22, backgroundColor: t.surface, alignItems: 'center', justifyContent: 'center' },
    closeX: { fontSize: 16, color: t.text },
    body: { padding: 20, gap: 12 },
    pad: { paddingHorizontal: 20, paddingBottom: 8 },
    chipRow: { flexDirection: 'row', alignItems: 'center', gap: 10, paddingHorizontal: 20, paddingBottom: 10 },
    chip: { flexDirection: 'row', alignItems: 'center', gap: 8, minHeight: 36, paddingHorizontal: 12, borderRadius: 18, backgroundColor: t.surface },
    chipText: { ...f, fontSize: 13, fontWeight: '600', color: t.text },
    locationRow: { flexDirection: 'row', alignItems: 'center', gap: 10, paddingHorizontal: 20, paddingBottom: 8 },
    locationOption: { minHeight: 56, paddingHorizontal: 16, paddingVertical: 10, gap: 10, borderRadius: t.radius, borderWidth: 1, borderColor: t.border, flexDirection: 'row', alignItems: 'center', margin: 1 },
    zipRow: { flexDirection: 'row', gap: 8, alignItems: 'center' },
    zipInput: { ...f, flex: 1, minHeight: 48, paddingHorizontal: 12, borderRadius: t.radius - 2, backgroundColor: t.surface, color: t.text, fontSize: 16 },
    zipBtn: { minHeight: 48, paddingHorizontal: 16, borderRadius: t.radius - 2, backgroundColor: t.accent, alignItems: 'center', justifyContent: 'center' },
    storeRow: { minHeight: 56, paddingHorizontal: 16, borderRadius: t.radius, borderWidth: 1, borderColor: t.border, flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', margin: 1 },
    pad12: { paddingHorizontal: 12 },
    muted: { ...f, color: t.muted, fontSize: 14 },
    small: { ...f, color: t.muted, fontSize: 12, lineHeight: 17 },
    bold: { ...f, fontWeight: '700', color: t.text },
    center: { textAlign: 'center' },
    loginNote: { ...f, fontSize: 13, color: t.muted, paddingHorizontal: 20, paddingBottom: 8 },
    loginWeb: { flex: 1, borderTopWidth: StyleSheet.hairlineWidth, borderTopColor: t.border },
    steps: { gap: 18, marginVertical: 12 },
    stepRow: { flexDirection: 'row', alignItems: 'center', gap: 12 },
    dot: { width: 24, height: 24, borderRadius: 12, alignItems: 'center', justifyContent: 'center' },
    dotIdle: { borderWidth: 2, borderColor: t.border },
    dotSpin: { width: 24, height: 24, alignItems: 'center', justifyContent: 'center', transform: [{ scale: 1.1 }] },
    dotCheck: { color: t.onAccent, fontSize: 13, fontWeight: '800' },
    stepText: { ...f, fontSize: 15, color: t.text },
    skeleton: { height: 72, borderRadius: t.radius + 2, backgroundColor: t.surface },
    list: { paddingHorizontal: 16, paddingBottom: 24, gap: 10 },
    card: { borderRadius: t.radius + 2, backgroundColor: t.background, borderWidth: 1, borderColor: t.border, overflow: 'hidden' },
    cardOpen: { borderColor: t.muted },
    rowInner: { flexDirection: 'row', alignItems: 'center', gap: 10, paddingVertical: 10, paddingRight: 6 },
    checkSlot: { width: 48, height: 48, alignItems: 'center', justifyContent: 'center' },
    box: { width: 24, height: 24, borderRadius: 7, borderWidth: 2, borderColor: t.muted, alignItems: 'center', justifyContent: 'center' },
    boxDisabled: { borderColor: t.border },
    boxCheck: { color: t.onAccent, fontSize: 14, fontWeight: '800' },
    thumb: { width: 48, height: 48, borderRadius: 10, backgroundColor: t.surface },
    thumbBig: { width: '100%', height: 72, borderRadius: 10, backgroundColor: t.surface },
    ingredient: { ...f, fontSize: 12, fontWeight: '500', color: t.muted },
    forRecipes: { ...f, fontSize: 11, color: t.muted, marginTop: 1 },
    name: { ...f, fontSize: 15, lineHeight: 20, fontWeight: '600', color: t.text },
    nameOff: { color: t.muted, textDecorationLine: 'line-through' },
    namePlaceholder: { color: t.muted },
    changeBtn: { minHeight: 44, paddingHorizontal: 10, justifyContent: 'center' },
    change: { ...f, fontSize: 14, fontWeight: '600', color: t.accent },
    warn: { marginHorizontal: 12, marginBottom: 12, padding: 12, borderRadius: 10, backgroundColor: t.warnBackground },
    qtyRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingLeft: 58, paddingRight: 12, paddingBottom: 10 },
    stepper: { flexDirection: 'row', alignItems: 'center', gap: 4 },
    stepBtn: { width: 44, height: 44, borderRadius: 10, backgroundColor: t.surface, alignItems: 'center', justifyContent: 'center' },
    stepOff: { opacity: 0.4 },
    qtyText: { ...f, fontSize: 20, fontWeight: '600', color: t.text },
    stepValue: { ...f, minWidth: 28, textAlign: 'center', fontSize: 16, fontWeight: '700', color: t.text },
    stepValueWide: { minWidth: 64 },
    warnText: { ...f, fontSize: 13, lineHeight: 18, color: t.warnText },
    prefNeeded: { ...f, fontSize: 13, lineHeight: 18, fontWeight: '600', paddingLeft: 12, paddingRight: 12, paddingBottom: 8 },
    pendingNote: { color: t.warnText, paddingBottom: 6 },
    expand: { borderTopWidth: 1, borderTopColor: t.border, paddingVertical: 12, gap: 12 },
    optRow: { paddingHorizontal: 12, gap: 10 },
    opt: { width: 136, padding: 10, gap: 6, borderRadius: t.radius, borderWidth: 1, borderColor: t.border, margin: 1, backgroundColor: t.background },
    optName: { ...f, fontSize: 13, lineHeight: 17, fontWeight: '500', color: t.text },
    optPrice: { ...f, fontSize: 13, fontWeight: '600', color: t.text },
    tag: { ...f, fontSize: 11, fontWeight: '700', color: t.muted },
    prefs: { flexDirection: 'row', flexWrap: 'wrap', gap: 8, paddingHorizontal: 12 },
    pref: { minHeight: 36, paddingHorizontal: 12, borderRadius: 18, backgroundColor: t.surface, justifyContent: 'center' },
    prefText: { ...f, fontSize: 13, color: t.text },
    searchRow: { flexDirection: 'row', gap: 8, paddingHorizontal: 12 },
    searchInput: { ...f, flex: 1, minHeight: 44, paddingHorizontal: 12, borderRadius: t.radius - 2, backgroundColor: t.surface, color: t.text, fontSize: 14 },
    searchBtn: { minHeight: 44, minWidth: 76, paddingHorizontal: 14, borderRadius: t.radius - 2, backgroundColor: t.text, alignItems: 'center', justifyContent: 'center' },
    searchBtnText: { ...f, color: t.onAccent, fontSize: 14, fontWeight: '600' },
    info: { marginHorizontal: 12, marginBottom: 10, padding: 12, borderRadius: 10, backgroundColor: t.surface, borderWidth: 1, borderColor: t.border },
    infoText: { ...f, fontSize: 13, lineHeight: 18, color: t.text },
    footer: { paddingHorizontal: 16, paddingTop: 12, paddingBottom: 28, gap: 8, borderTopWidth: 1, borderTopColor: t.border, backgroundColor: t.background },
    totalRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'baseline' },
    totalLabel: { ...f, fontSize: 14, color: t.muted },
    totalValue: { ...f, fontSize: 18, fontWeight: '700', color: t.text },
    cta: { minHeight: 52, borderRadius: t.radius, backgroundColor: t.accent, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 16 },
    ctaOff: { opacity: 0.5 },
    ctaQuiet: { backgroundColor: t.surface },
    ctaText: { ...f, color: t.onAccent, fontSize: 16, fontWeight: '700' },
    totalNone: { ...f, fontSize: 15, fontWeight: '600', color: t.muted },
    doneBody: { paddingHorizontal: 20, paddingTop: 8, paddingBottom: 24, gap: 16 },
    banner: { flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 14, paddingHorizontal: 16, borderRadius: t.radius + 2 },
    bannerIcon: { width: 36, height: 36, borderRadius: 18, alignItems: 'center', justifyContent: 'center' },
    bannerCheck: { fontSize: 18, fontWeight: '800' },
    bannerTitle: { ...f, fontSize: 15, fontWeight: '700', color: t.text },
    bannerSub: { ...f, fontSize: 13, lineHeight: 18, color: t.text, opacity: 0.85 },
    addedCard: { borderRadius: t.radius + 2, borderWidth: 1, borderColor: t.border, backgroundColor: t.background, overflow: 'hidden' },
    addedRow: { flexDirection: 'row', alignItems: 'center', gap: 12, paddingVertical: 12, paddingHorizontal: 14, minHeight: 68 },
    addedRule: { borderTopWidth: 1, borderTopColor: t.border },
    addedThumb: { width: 44, height: 44, borderRadius: 10, backgroundColor: t.surface, alignItems: 'center', justifyContent: 'center' },
    mono: { ...f, fontSize: 13, fontWeight: '700', color: t.muted },
    addedName: { ...f, fontSize: 14, lineHeight: 19, fontWeight: '600', color: t.text },
    addedEnd: { alignItems: 'flex-end', gap: 4 },
    pill: { ...f, fontSize: 12, fontWeight: '700', color: t.text, paddingVertical: 3, paddingHorizontal: 8, borderRadius: 999, backgroundColor: t.surface, overflow: 'hidden' },
    leftCard: { borderRadius: t.radius + 2, borderWidth: 1, borderColor: t.border, backgroundColor: t.background, overflow: 'hidden' },
    leftHead: { flexDirection: 'row', alignItems: 'center', gap: 12, minHeight: 56, paddingVertical: 10, paddingHorizontal: 16 },
    leftTitle: { ...f, fontSize: 14, fontWeight: '600', color: t.text },
    chevron: { ...f, fontSize: 18, color: t.muted },
    leftRow: { gap: 2, paddingVertical: 10, paddingHorizontal: 16, borderTopWidth: 1, borderTopColor: t.border },
    leftName: { ...f, fontSize: 14, fontWeight: '500', color: t.text },
    doneFooter: { borderTopWidth: 0, gap: 10 },
  });
}
