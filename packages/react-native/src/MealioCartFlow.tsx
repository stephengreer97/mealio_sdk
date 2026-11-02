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
import type { AddResult, CartItem, CartSession, MealioError, Product, Recipe, Step, StoreInfo } from '@mealio/sdk-core';
import { useMealio, useMealioInternal } from './MealioProvider';
import { money, type MealioTheme } from './theme';

export interface MealioCartFlowProps {
  visible: boolean;
  recipe: Recipe;
  /**
   * Store id from GET /api/v1/stores, e.g. "heb". Optional: without it the
   * user's default store is used, and the sheet asks them to pick one the
   * first time. The user can change store from the sheet either way.
   */
  store?: string | null;
  /** 5-digit zip. Needed for Kroger family stores. */
  zip?: string | null;
  /** Called when the sheet closes. `result` is null when nothing was added. */
  onClose: (result: AddResult | null) => void;
  /** Called after the cart is filled, before the user taps Done. */
  onAdded?: (result: AddResult) => void;
  onError?: (e: MealioError | Error) => void;
}

type Phase = 'loading' | 'list' | 'adding' | 'done' | 'error' | 'stores';

export function MealioCartFlow(props: MealioCartFlowProps) {
  const { visible } = props;
  const mealio = useMealio();
  const internal = useMealioInternal();
  const t = mealio.theme;
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

  const start = useCallback(async (storeId: string | null) => {
    const id = ++run.current;
    setPhase('loading'); setStep('connecting'); setCart(null); setResult(null); setError(null);
    try {
      const c = await mealio.prepareCart({ store: storeId, recipe: props.recipe, zip: props.zip }, { onStep: (s) => run.current === id && setStep(s) });
      if (run.current !== id) return;
      setStore(c.store); setCart(c); setPhase('list');
    } catch (e: any) {
      if (run.current !== id) return;
      if (e?.code === 'store_required') { openStores('error'); return; }
      setError({ code: e?.code || 'error', message: e?.message || 'Something went wrong.' });
      setPhase('error');
      props.onError?.(e);
    }
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, [props.zip, props.recipe]);

  useEffect(() => { if (visible) start(props.store ?? null); else run.current += 1; }, [visible]); // eslint-disable-line react-hooks/exhaustive-deps

  const add = useCallback(async () => {
    if (!cart) return;
    setPhase('adding');
    try {
      const r = await cart.addToCart();
      setResult(r); setPhase('done');
      props.onAdded?.(r);
    } catch (e: any) {
      setError({ code: e?.code || 'error', message: e?.message || 'Could not add to your cart.' });
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

  const storeName = cart?.cart.storeName || (store ? storeLabel(store) : 'your store');
  const s = useMemo(() => styles(t), [t]);

  return (
    <Modal visible={visible} transparent animationType="slide" onRequestClose={close} statusBarTranslucent>
      <View style={s.scrim}>
        <KeyboardAvoidingView behavior={Platform.OS === 'ios' ? 'padding' : undefined} style={s.sheet}>
          <View style={s.grabber} />
          <Header t={t} recipeTitle={props.recipe.title} title={internal.login ? internal.login.title : headerTitle(phase, storeName)} onClose={close} />
          {internal.login ? (
            <View style={s.flex}>
              <Text style={s.loginNote}>Sign in on {storeName}&apos;s own page. Mealio never sees your password.</Text>
              <View style={s.loginWeb}>{internal.login.webview}</View>
            </View>
          ) : phase === 'loading' ? (
            <Loading t={t} step={step} storeName={storeName} count={props.recipe.ingredients.length} />
          ) : phase === 'stores' ? (
            <StorePicker t={t} stores={stores} current={store} onPick={(id) => { setStore(id); start(id); }}
              onBack={cart && backTo.current === 'list' ? () => setPhase('list') : null} />
          ) : (phase === 'list' || phase === 'adding') && cart ? (
            <CartList t={t} cart={cart} storeName={storeName} busy={phase === 'adding'} onChange={bump} onAdd={add}
              onChangeStore={() => openStores('list')} />
          ) : phase === 'done' && result && cart ? (
            <Done t={t} cart={cart} result={result} storeName={storeName} onDone={close} />
          ) : (
            <ErrorView t={t} error={error} onRetry={() => start(store)} onClose={close} />
          )}
        </KeyboardAvoidingView>
      </View>
    </Modal>
  );
}

function headerTitle(phase: Phase, storeName: string): string {
  if (phase === 'done') return 'All set';
  if (phase === 'loading') return storeName === 'your store' ? 'Getting your cart ready' : `Getting your ${storeName} cart ready`;
  if (phase === 'error') return 'Something went wrong';
  if (phase === 'stores') return 'Choose your store';
  return `Your ${storeName} list`;
}

function storeLabel(id: string): string {
  const known: Record<string, string> = { heb: 'H-E-B', aldi: 'ALDI', kroger: 'Kroger', safeway: 'Safeway', wegmans: 'Wegmans' };
  return known[id] || id.replace(/_/g, ' ').replace(/\b\w/g, (m) => m.toUpperCase());
}

// ── pieces ─────────────────────────────────────────────────────────────

function Header({ t, recipeTitle, title, onClose }: { t: MealioTheme; recipeTitle?: string; title: string; onClose: () => void }) {
  const s = styles(t);
  return (
    <View style={s.header}>
      <View style={s.flex}>
        {recipeTitle ? <Text style={s.kicker} numberOfLines={1}>{recipeTitle}</Text> : null}
        <Text style={s.h1} numberOfLines={2} accessibilityRole="header">{title}</Text>
      </View>
      <Pressable onPress={onClose} accessibilityRole="button" accessibilityLabel="Close" style={s.closeBtn} hitSlop={8}>
        <Text style={s.closeX}>✕</Text>
      </Pressable>
    </View>
  );
}

const STEPS: Array<{ key: Step[]; label: (n: number, store: string) => string }> = [
  { key: ['connecting', 'checking_sign_in', 'signing_in'], label: (_n, store) => `Checking your ${store} sign-in` },
  { key: ['searching'], label: (n) => `Finding your ${n} ingredient${n === 1 ? '' : 's'}` },
];

function Loading({ t, step, storeName, count }: { t: MealioTheme; step: Step; storeName: string; count: number }) {
  const s = styles(t);
  const at = STEPS.findIndex((x) => x.key.includes(step));
  return (
    <View style={s.body}>
      <Text style={s.muted}>Checking prices and stock at {storeName}.</Text>
      <View style={s.steps}>
        {STEPS.map((x, i) => (
          <View key={i} style={s.stepRow}>
            {i < at ? <View style={[s.dot, { backgroundColor: t.accent }]}><Text style={s.dotCheck}>✓</Text></View>
              : i === at ? <View style={s.dotSpin}><ActivityIndicator size="small" color={t.accent} /></View>
                : <View style={[s.dot, s.dotIdle]} />}
            <Text style={[s.stepText, i === at && s.bold, i > at && s.muted]}>{x.label(count, storeName)}</Text>
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
}

/** The list screen on its own, for partners who host it in their own sheet. */
export function CartList({ t, cart, storeName, busy, onChange, onAdd, onChangeStore }: CartListProps) {
  const s = styles(t);
  const [open, setOpen] = useState<string | null>(() => cart.items.find((i) => i.status === 'choose' || i.status === 'remembered_unavailable')?.key ?? null);
  const est = cart.estimate();
  const selectable = cart.items.filter((i) => i.status !== 'unavailable');
  return (
    <View style={s.flex}>
      <View style={s.chipRow}>
        {onChangeStore ? (
          <Pressable onPress={onChangeStore} disabled={busy} accessibilityRole="button" accessibilityLabel={`Store: ${storeName}. Change store`} style={s.chip}>
            <Text style={s.chipText}>{storeName}</Text>
            <Text style={[s.chipText, { color: t.accent }]}>Change</Text>
          </Pressable>
        ) : null}
        <Text style={s.muted}>{est.count} of {selectable.length} selected</Text>
      </View>
      <ScrollView style={s.flex} contentContainerStyle={s.list} keyboardShouldPersistTaps="handled">
        {cart.items.map((it) => (
          <ItemRow key={it.key} t={t} cart={cart} item={it} storeName={storeName} open={open === it.key}
            onToggleOpen={() => setOpen(open === it.key ? null : it.key)} onChange={onChange} disabled={busy} />
        ))}
        <Text style={[s.small, s.footnote]}>Unchecked items are left out this time only. Your usual picks stay saved for next time. Prices from {storeName}.</Text>
      </ScrollView>
      <View style={s.footer}>
        <View style={s.totalRow}>
          <Text style={s.totalLabel}>{est.estimated ? 'Estimated total' : 'Total'}</Text>
          <Text style={s.totalValue}>{est.estimated ? 'about ' : ''}{money(est.total)}</Text>
        </View>
        <Pressable onPress={onAdd} disabled={busy || est.count === 0} accessibilityRole="button"
          style={[s.cta, (busy || est.count === 0) && s.ctaOff]}>
          {busy ? <ActivityIndicator color={t.onAccent} />
            : <Text style={s.ctaText}>{est.count ? `Add ${est.count} item${est.count === 1 ? '' : 's'} to ${storeName}` : 'Select items to add'}</Text>}
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
            <Text style={[s.name, s.muted]}>Not found at {storeName}</Text>
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
      setSearchNote(found.length ? null : `Nothing found for "${q}".`);
      setQuery('');
      onChange();
    } catch (e: any) {
      setSearchNote(e?.message || 'Search failed. Try again.');
    } finally {
      setSearching(false);
    }
  };

  const meta = picked
    ? [picked.price, picked.estimated ? 'est.' : null, picked.id === item.remembered?.id ? 'Your usual' : null].filter(Boolean).join(' · ')
    : item.status === 'remembered' ? 'Not adding this time'
      : item.status === 'remembered_unavailable' ? 'Your usual is out of stock'
        : `${options.length} option${options.length === 1 ? '' : 's'}`;

  return (
    <View style={[s.card, open && s.cardOpen]}>
      <View style={s.rowInner}>
        <Pressable onPress={toggle} accessibilityRole="checkbox" accessibilityState={{ checked: on, disabled }}
          accessibilityLabel={(on ? 'Leave out ' : 'Add ') + item.ingredient} style={s.checkSlot}>
          <View style={[s.box, on ? { backgroundColor: t.accent, borderWidth: 0 } : null]}>{on ? <Text style={s.boxCheck}>✓</Text> : null}</View>
        </Pressable>
        <Thumb t={t} product={shown || options[0] || null} dim={!on} />
        <Pressable style={s.flex} onPress={onToggleOpen} accessibilityRole="button" accessibilityHint="Shows the options">
          <Text style={s.ingredient} numberOfLines={1}>{item.ingredient}</Text>
          <Text style={[s.name, !on && (shown ? s.nameOff : s.namePlaceholder)]} numberOfLines={2}>{shown ? shown.name : 'Choose a product'}</Text>
          <Text style={s.small}>{meta}</Text>
        </Pressable>
        <Pressable onPress={onToggleOpen} accessibilityRole="button" accessibilityState={{ expanded: open }} style={s.changeBtn}>
          <Text style={s.change}>{open ? 'Done' : on || item.status === 'remembered' ? 'Change' : 'Choose'}</Text>
        </Pressable>
      </View>

      {on && picked ? (
        <View style={s.qtyRow}>
          <Text style={s.small}>{picked.soldByWeight ? 'Sold by weight' : 'Quantity'}</Text>
          <View style={s.stepper}>
            <Pressable onPress={() => { cart.setQuantity(item.key, cart.quantity(item.key) - 1); onChange(); }} disabled={disabled || cart.quantity(item.key) <= 1}
              accessibilityRole="button" accessibilityLabel={`Fewer ${item.ingredient}`} style={[s.stepBtn, cart.quantity(item.key) <= 1 && s.stepOff]}>
              <Text style={s.qtyText}>−</Text>
            </Pressable>
            <Text style={s.stepValue} accessibilityLabel={`Quantity ${cart.quantity(item.key)}`}>{cart.quantity(item.key)}</Text>
            <Pressable onPress={() => { cart.setQuantity(item.key, cart.quantity(item.key) + 1); onChange(); }} disabled={disabled || cart.quantity(item.key) >= cart.maxQuantity(item.key)}
              accessibilityRole="button" accessibilityLabel={`More ${item.ingredient}`} style={[s.stepBtn, cart.quantity(item.key) >= cart.maxQuantity(item.key) && s.stepOff]}>
              <Text style={s.qtyText}>+</Text>
            </Pressable>
          </View>
        </View>
      ) : null}

      {item.status === 'remembered_unavailable' && !on ? (
        <View style={s.warn}>
          <Text style={s.warnText}>Your usual{item.remembered ? `, ${item.remembered.name},` : ''} is {item.reason === 'not_found' ? 'not available' : 'out of stock'} today. Pick another for this run. It stays your usual.</Text>
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
                  <Text style={s.optPrice}>{o.outOfStock ? 'Out of stock' : `${o.price || ''}${o.estimated ? ' est.' : ''}`}</Text>
                  {usual ? <Text style={[s.tag, { color: t.accent }]}>Your usual</Text> : o.badge === 'popular' ? <Text style={s.tag}>Popular</Text> : null}
                </Pressable>
              );
            })}
          </ScrollView>
          {picked?.preferences?.length ? (
            <View style={s.prefs}>
              {picked.preferences.map((p) => {
                const selPref = cart.selections().find((x) => x.key === item.key)?.preferenceId === p.id;
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
              placeholder={`Search ${storeName} for something else`} placeholderTextColor={t.muted}
              accessibilityLabel={`Search ${storeName} for something else`} style={s.searchInput} editable={!disabled} />
            <Pressable onPress={search} accessibilityRole="button" style={s.searchBtn} disabled={searching}>
              {searching ? <ActivityIndicator color="#FFFFFF" /> : <Text style={s.searchBtnText}>Search</Text>}
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

function Done({ t, cart, result, storeName, onDone }: { t: MealioTheme; cart: CartSession; result: AddResult; storeName: string; onDone: () => void }) {
  const s = styles(t);
  const price = (key: string) => cart.selected(key)?.price || '';
  return (
    <View style={s.flex}>
      <ScrollView style={s.flex} contentContainerStyle={s.body}>
        <View style={s.doneTop}>
          <View style={[s.doneIcon, { backgroundColor: t.surface }]}><Text style={[s.doneCheck, { color: t.accent }]}>✓</Text></View>
          <Text style={s.h2}>{result.added.length ? `Added ${result.added.length} item${result.added.length === 1 ? '' : 's'} to ${storeName}` : `Nothing was added to ${storeName}`}</Text>
        </View>
        {result.failed.length ? (
          <View style={s.warn}>
            <Text style={s.warnText}>{result.failed.length} item{result.failed.length === 1 ? '' : 's'} could not be added: {result.failed.map((f) => `${f.name} (${reasonText(f.reason)})`).join(', ')}.</Text>
          </View>
        ) : null}
        {result.added.map((a) => (
          <View key={a.key} style={s.doneRow}><Text style={[s.flex, s.doneName]} numberOfLines={2}>{a.name}</Text><Text style={s.bold}>{price(a.key)}</Text></View>
        ))}
        {result.skipped.filter((x) => x.reason === 'deselected').map((x) => (
          <View key={x.key} style={s.doneRow}><Text style={[s.flex, s.muted]}>{cart.items.find((i) => i.key === x.key)?.ingredient}</Text><Text style={s.muted}>Left out</Text></View>
        ))}
      </ScrollView>
      <View style={s.footer}>
        <Pressable onPress={onDone} accessibilityRole="button" style={s.cta}><Text style={s.ctaText}>Done</Text></Pressable>
      </View>
    </View>
  );
}

function reasonText(r: string): string {
  if (r === 'not_confirmed') return 'not confirmed in your cart';
  if (/stock/.test(r)) return 'out of stock';
  if (/timeout|no_answer/.test(r)) return 'the store did not answer';
  return 'the store refused it';
}

function StorePicker({ t, stores, current, onPick, onBack }: {
  t: MealioTheme; stores: StoreInfo[] | null; current: string | null; onPick: (id: string) => void; onBack: (() => void) | null;
}) {
  const s = styles(t);
  if (!stores) return <View style={s.body}><ActivityIndicator color={t.accent} /></View>;
  return (
    <View style={s.flex}>
      <ScrollView style={s.flex} contentContainerStyle={s.list}>
        {stores.length === 0 ? <Text style={s.muted}>Could not load stores. Close and try again.</Text> : null}
        {stores.map((st) => (
          <Pressable key={st.id} onPress={() => onPick(st.id)} accessibilityRole="radio" accessibilityState={{ selected: st.id === current }}
            style={[s.storeRow, st.id === current && { borderColor: t.accent, borderWidth: 2 }]}>
            <Text style={s.name}>{st.name}</Text>
            {st.id === current ? <Text style={[s.small, { color: t.accent }]}>Current</Text> : null}
          </Pressable>
        ))}
      </ScrollView>
      {onBack ? (
        <View style={s.footer}>
          <Pressable onPress={onBack} accessibilityRole="button" style={[s.cta, s.ctaQuiet]}><Text style={[s.ctaText, { color: t.text }]}>Back to your list</Text></Pressable>
        </View>
      ) : null}
    </View>
  );
}

function ErrorView({ t, error, onRetry, onClose }: { t: MealioTheme; error: { code: string; message: string } | null; onRetry: () => void; onClose: () => void }) {
  const s = styles(t);
  const msg = error?.code === 'login_cancelled' ? 'Sign-in was closed before it finished.' : error?.message || 'Something went wrong.';
  return (
    <View style={[s.body, s.flex]}>
      <Text style={s.stepText}>{msg}</Text>
      <View style={s.flex} />
      <Pressable onPress={onRetry} accessibilityRole="button" style={s.cta}><Text style={s.ctaText}>Try again</Text></Pressable>
      <Pressable onPress={onClose} accessibilityRole="button" style={[s.cta, s.ctaQuiet]}><Text style={[s.ctaText, { color: t.text }]}>Close</Text></Pressable>
    </View>
  );
}

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
    name: { ...f, fontSize: 15, lineHeight: 20, fontWeight: '600', color: t.text },
    nameOff: { color: t.muted, textDecorationLine: 'line-through' },
    namePlaceholder: { color: t.muted },
    changeBtn: { minHeight: 44, paddingHorizontal: 10, justifyContent: 'center' },
    change: { ...f, fontSize: 14, fontWeight: '600', color: t.accent },
    warn: { marginHorizontal: 12, marginBottom: 12, padding: 12, borderRadius: 10, backgroundColor: t.warnBackground },
    qtyRow: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingLeft: 58, paddingRight: 12, paddingBottom: 10 },
    stepper: { flexDirection: 'row', alignItems: 'center', gap: 4 },
    stepBtn: { width: 44, height: 36, borderRadius: 10, backgroundColor: t.surface, alignItems: 'center', justifyContent: 'center' },
    stepOff: { opacity: 0.4 },
    qtyText: { ...f, fontSize: 20, fontWeight: '600', color: t.text },
    stepValue: { ...f, minWidth: 28, textAlign: 'center', fontSize: 16, fontWeight: '700', color: t.text },
    warnText: { ...f, fontSize: 13, lineHeight: 18, color: t.warnText },
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
    searchBtnText: { ...f, color: '#FFFFFF', fontSize: 14, fontWeight: '600' },
    footnote: { paddingHorizontal: 4, paddingTop: 4 },
    footer: { paddingHorizontal: 16, paddingTop: 12, paddingBottom: 28, gap: 8, borderTopWidth: 1, borderTopColor: t.border, backgroundColor: t.background },
    totalRow: { flexDirection: 'row', justifyContent: 'space-between', alignItems: 'baseline' },
    totalLabel: { ...f, fontSize: 14, color: t.muted },
    totalValue: { ...f, fontSize: 18, fontWeight: '700', color: t.text },
    cta: { minHeight: 52, borderRadius: t.radius, backgroundColor: t.accent, alignItems: 'center', justifyContent: 'center', paddingHorizontal: 16 },
    ctaOff: { opacity: 0.5 },
    ctaQuiet: { backgroundColor: t.surface },
    ctaText: { ...f, color: t.onAccent, fontSize: 16, fontWeight: '700' },
    doneTop: { alignItems: 'center', gap: 12, marginVertical: 16 },
    doneIcon: { width: 64, height: 64, borderRadius: 32, alignItems: 'center', justifyContent: 'center' },
    doneCheck: { fontSize: 28, fontWeight: '800' },
    doneRow: { flexDirection: 'row', gap: 12, paddingVertical: 12, borderBottomWidth: StyleSheet.hairlineWidth, borderBottomColor: t.border },
    doneName: { ...f, fontSize: 14, color: t.text },
  });
}
