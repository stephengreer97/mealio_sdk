// The React Native host. Place <MealioProvider> once near the root of the app.
// It renders:
//   - a hidden 1x1 WebView: the store session the relay works in
//   - the store sign-in WebView when a store asks the user to sign in. Inside
//     an open MealioCartFlow sheet it renders in that sheet (one sheet for the
//     whole flow); otherwise in a sheet of its own.
// Both WebViews share the platform's cookie store, so a sign-in is the session
// the hidden WebView uses.

import React, { createContext, useCallback, useContext, useMemo, useRef, useState } from 'react';
import { Modal, Platform, Pressable, SafeAreaView, StyleSheet, Text, useColorScheme, View, type ImageSourcePropType } from 'react-native';
import { WebView, type WebViewMessageEvent, type WebViewNavigation } from 'react-native-webview';
import {
  MealioClient, MealioError, matchesAny, parseMessage, safeListener, textTools,
  type MealioEventListener, type MealioStrings, type TextTools,
  type CartSession, type Host, type JsonMessage, type Matcher, type PrepareCartInput, type StepListener, type StoreInfo, type StoreLocation, type StorePreferences,
} from '@mealio/sdk-core';
import { money, resolveTheme, type MealioColorScheme, type MealioTheme } from './theme';
import { MealioStoreSettings } from './MealioStoreSettings';

export const SDK_VERSION = '0.5.0';

export interface MealioSheetOptions {
  /** Show the total and the done screen prices. Defaults to true. Options keep their own prices. */
  showTotal?: boolean;
  /** `auto` fits a tall sheet, `full` fills the screen, or a share of the screen from 0.5 to 1. Defaults to `auto`. */
  height?: 'auto' | 'full' | number;
  /** Your logo, shown at the top of the sheet. */
  logo?: ImageSourcePropType;
}

/** The drop-in's words and prices, resolved once on the provider. */
export interface MealioUi extends TextTools {
  money: (amount: number) => string;
  emit: MealioEventListener;
  /** True when the partner set formatMoney, so prices are built from numbers, not the store's text. */
  customMoney: boolean;
  sheet: { showTotal: boolean; height: 'auto' | 'full' | number; logo: ImageSourcePropType | null };
}

export interface EpochStorage {
  get(): Promise<number>;
  set(n: number): Promise<void>;
}

export interface MealioProviderProps {
  publishableKey: string;
  /** Ask your server for a session (POST https://mealio.co/api/v1/sessions with your secret key). */
  getSessionToken: () => Promise<string>;
  baseUrl?: string;
  /** Persist the store sign-out epoch. Without it, sign-out still clears cookies but the rails' small caches survive a restart. */
  epochStorage?: EpochStorage;
  /** Your brand: accent color, radius, font. */
  theme?: Partial<MealioTheme>;
  /** Colors for dark mode. Only used when `colorScheme` is `dark`, or `auto` on a phone set to dark. */
  darkTheme?: Partial<MealioTheme>;
  /** `auto` follows the phone. Defaults to `light`. */
  colorScheme?: MealioColorScheme;
  /** Change or translate any word the drop-in shows. See DEFAULT_STRINGS for the keys. */
  strings?: Partial<MealioStrings>;
  /** How prices read. Defaults to "$12.50". */
  formatMoney?: (amount: number) => string;
  /** How the sheet looks and behaves. */
  sheet?: MealioSheetOptions;
  /** Every step of the sheet, for your analytics. Nothing is sent to Mealio. */
  onEvent?: MealioEventListener;
  /** @deprecated use theme.accent */
  accentColor?: string;
  children: React.ReactNode;
}

export interface MealioApi {
  /** `recipe` for one, or `recipes` for up to 10 in one cart. */
  prepareCart(input: PrepareCartInput, opts?: { onStep?: StepListener }): Promise<CartSession>;
  stores(): Promise<StoreInfo[]>;
  signOutOfAllStores(): Promise<void>;
  /**
   * Run the login check for the user's store ahead of time, so the next cart
   * starts at search. MealioCartButton does this when it appears. Call it
   * yourself if you start carts another way. Never shows sign-in, never throws.
   */
  warm(opts?: { store?: string | null }): Promise<void>;
  /** A Kroger family chain's stores near a zip, for your own store screen. */
  storeLocations(store: string, zip: string): Promise<StoreLocation[]>;
  /** The user's default store, and their exact store if it is in the Kroger family. */
  storePreferences(): Promise<StorePreferences>;
  /** Make a store the user's default. Kroger family stores need `locationId` the first time. */
  setStore(store: string, locationId?: string | null): Promise<StorePreferences>;
  /** Open the sheet where the user changes their store or zip. Put it on your settings screen. */
  openStoreSettings(): void;
  theme: MealioTheme;
  ui: MealioUi;
}

export interface LoginView {
  title: string;
  /** The sign-in WebView, ready to place in a sheet. */
  webview: React.ReactElement;
  cancel: () => void;
}

interface Internal {
  login: LoginView | null;
  /** A cart flow sheet is open and will show the sign-in itself. */
  hostLogin: (on: boolean) => void;
}

const ApiCtx = createContext<MealioApi | null>(null);
const InternalCtx = createContext<Internal | null>(null);

export function useMealio(): MealioApi {
  const v = useContext(ApiCtx);
  if (!v) throw new Error('useMealio must be used inside <MealioProvider>');
  return v;
}

/** For MealioCartFlow: the sign-in view to show inside its sheet. */
export function useMealioInternal(): Internal {
  const v = useContext(InternalCtx);
  if (!v) throw new Error('Mealio components must be used inside <MealioProvider>');
  return v;
}

type Waiter = { until: Matcher[]; messages: JsonMessage[]; resolve: (timedOut: boolean) => void; tag: Tagged };

// ── which frame is talking ────────────────────────────────────────────────
//
// react-native-webview hands every frame's postMessage to onMessage with no
// frame in it, so an ad iframe on a store page could post a SEARCH_RESULT or a
// signed-in answer that ends a script early. Before each script the host
// replaces the MAIN frame's ReactNativeWebView with a wrapper that stamps
// every message with a one-run secret and says hello through it. A sub-frame
// cannot read the main frame's secret, so once the hello arrives, unstamped or
// wrongly stamped messages are dropped. If the wrapper cannot be installed (the
// hello never comes) messages are accepted as before rather than lost.

interface Tagged { nonce: string; strict: boolean }

const newNonce = () => `${Date.now().toString(36)}${Math.random().toString(36).slice(2)}${Math.random().toString(36).slice(2)}`;

const tagScript = (nonce: string) => `(function(){try{
  var cur = window.ReactNativeWebView; if (!cur) return;
  var base = cur.__mealioBase || cur;
  var w = { __mealioBase: base, postMessage: function (m) { base.postMessage(JSON.stringify({ __mealio: ${JSON.stringify(nonce)}, m: String(m) })); } };
  window.ReactNativeWebView = w;
  if (window.ReactNativeWebView === w) base.postMessage(JSON.stringify({ __mealio: ${JSON.stringify(nonce)}, hello: 1 }));
}catch(e){}})(); true;`;

/** The message a frame posted, or null if it must be dropped. Flips `tag.strict` on the hello. */
function untag(data: string, tag: Tagged | null): string | null {
  let o: any = null;
  try { o = JSON.parse(data); } catch { /* a plain message */ }
  if (o && typeof o === 'object' && typeof o.__mealio === 'string') {
    if (!tag || o.__mealio !== tag.nonce) return null;
    if (o.hello) { tag.strict = true; return null; }
    return typeof o.m === 'string' ? o.m : null;
  }
  return tag && tag.strict ? null : data;
}

// ── signing out of the stores ─────────────────────────────────────────────

/** The cookie manager the docs recommend: maintained, New Architecture. */
export const COOKIE_MANAGER = '@preeternal/react-native-cookie-manager';

interface CookieManagerLike {
  clearAllStores?: () => Promise<unknown>;
  clearAll?: (useWebKit?: boolean) => Promise<unknown>;
}

/**
 * The app's cookie manager, or null. An optional peer: an app that never signs
 * out of stores need not install one. The maintained package first (its
 * clearAllStores clears the Foundation and WebKit stores in one call), then
 * @react-native-cookies/cookies, which it succeeded, for apps still on the old
 * architecture. Each require sits in its own try: Metro treats a require inside
 * try/catch as optional, so a missing package is not a bundling error.
 */
function loadCookieManager(): CookieManagerLike | null {
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const m = require('@preeternal/react-native-cookie-manager');
    if (m) return (m.default ?? m) as CookieManagerLike;
  } catch { /* not installed */ }
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const m = require('@react-native-cookies/cookies');
    if (m) return (m.default ?? m) as CookieManagerLike;
  } catch { /* not installed */ }
  return null;
}

/** Response headers a store must never hand to Mealio: its session cookies. */
const PRIVATE_HEADERS = new Set(['set-cookie', 'set-cookie2']);

interface LoginState {
  tag: Tagged;
  url: string;
  title: string;
  guard: string;
  check: { script: string; intervalMs: number } | null;
  doneWhen: Matcher[];
  doneWhenUrl: RegExp | null;
  allowNavigation: (url: string) => boolean;
  finish: (outcome: 'signed_in' | 'cancelled' | 'timeout') => void;
  messages: JsonMessage[];
}

function memoryEpoch(): EpochStorage {
  let n = 0;
  return { get: async () => n, set: async (v) => { n = v; } };
}

export function MealioProvider(props: MealioProviderProps) {
  const phone = useColorScheme();
  const theme = useMemo(
    () => resolveTheme({ ...(props.accentColor ? { accent: props.accentColor } : {}), ...(props.theme || {}) }, props.darkTheme, props.colorScheme, phone),
    [props.theme, props.accentColor, props.darkTheme, props.colorScheme, phone],
  );
  // A ref, so an inline onEvent does not rebuild everything on each render.
  const onEventRef = useRef(props.onEvent);
  onEventRef.current = props.onEvent;
  const ui = useMemo<MealioUi>(() => ({
    ...textTools(props.strings),
    money: props.formatMoney ?? money,
    emit: safeListener((e) => onEventRef.current?.(e)),
    customMoney: !!props.formatMoney,
    sheet: { showTotal: props.sheet?.showTotal ?? true, height: props.sheet?.height ?? 'auto', logo: props.sheet?.logo ?? null },
  }), [props.strings, props.formatMoney, props.sheet?.showTotal, props.sheet?.height, props.sheet?.logo]);
  const hidden = useRef<WebView>(null);
  /** The store the hidden page was last opened for, and the allowlist to hold it to. */
  const hiddenStore = useRef<string | null>(null);
  const allowRef = useRef<MealioClient['allowlist'] | null>(null);
  const loginView = useRef<WebView>(null);
  const [hiddenUri, setHiddenUri] = useState<{ uri: string; n: number }>({ uri: 'about:blank', n: 0 });
  const pageWaiter = useRef<{ resolve: (r: { ok: boolean; finalUrl?: string; error?: string }) => void } | null>(null);
  const scriptWaiter = useRef<Waiter | null>(null);
  const [login, setLogin] = useState<LoginState | null>(null);
  const loginRef = useRef<LoginState | null>(null);
  const checkTimer = useRef<ReturnType<typeof setInterval> | null>(null);
  const [hosts, setHosts] = useState(0);
  const [settingsOpen, setSettingsOpen] = useState(false);
  const epochStore = useMemo(() => props.epochStorage || memoryEpoch(), [props.epochStorage]);

  // ── hidden WebView ───────────────────────────────────────────────────

  const onHiddenLoadEnd = useCallback((e: { nativeEvent: { url: string } }) => {
    const w = pageWaiter.current;
    if (!w || e.nativeEvent.url === 'about:blank') return;
    pageWaiter.current = null;
    w.resolve({ ok: true, finalUrl: e.nativeEvent.url });
  }, []);

  /**
   * The hidden page stays on its store. Every top-frame navigation must pass
   * the store's allowlist (its own hosts, or the identity hosts its sign-in
   * bounces through). Anything else, a redirect or a script sending the page
   * to another site, or a non-https scheme the OS would otherwise open, is
   * refused, and a page_open waiting on it fails as blocked.
   */
  const onHiddenShouldStart = useCallback((req: { url: string; isTopFrame?: boolean }) => {
    const url = req.url || '';
    if (url.startsWith('about:')) return true;
    if (req.isTopFrame === false) return true;
    const store = hiddenStore.current;
    const a = allowRef.current;
    const ok = !!store && !!a && (a.check(store, url, 'page').ok || a.check(store, url, 'login').ok);
    if (!ok) {
      const w = pageWaiter.current;
      if (w) { pageWaiter.current = null; w.resolve({ ok: false, finalUrl: url, error: 'blocked' }); }
    }
    return ok;
  }, []);

  const onHiddenError = useCallback(() => {
    const w = pageWaiter.current;
    if (!w) return;
    pageWaiter.current = null;
    w.resolve({ ok: false, error: 'load_failed' });
  }, []);

  const onHiddenMessage = useCallback((e: WebViewMessageEvent) => {
    const w = scriptWaiter.current;
    if (!w) return;
    const data = untag(e.nativeEvent.data, w.tag);
    const msg = data == null ? null : parseMessage(data);
    if (!msg) return;
    w.messages.push(msg);
    if (matchesAny(msg, w.until)) { scriptWaiter.current = null; w.resolve(false); }
  }, []);

  // ── sign-in ──────────────────────────────────────────────────────────

  const endLogin = useCallback((outcome: 'signed_in' | 'cancelled' | 'timeout') => {
    const l = loginRef.current;
    if (!l) return;
    loginRef.current = null;
    if (checkTimer.current) { clearInterval(checkTimer.current); checkTimer.current = null; }
    setLogin(null);
    l.finish(outcome);
  }, []);

  const injectCheck = useCallback(() => {
    const l = loginRef.current;
    if (!l || !l.check) return;
    loginView.current?.injectJavaScript(tagScript(l.tag.nonce));
    loginView.current?.injectJavaScript(l.guard);
    loginView.current?.injectJavaScript(l.check.script);
  }, []);

  const onLoginMessage = useCallback((e: WebViewMessageEvent) => {
    const l = loginRef.current;
    if (!l) return;
    const data = untag(e.nativeEvent.data, l.tag);
    const msg = data == null ? null : parseMessage(data);
    if (!msg) return;
    l.messages.push(msg);
    if (matchesAny(msg, l.doneWhen)) endLogin('signed_in');
  }, [endLogin]);

  const onLoginNav = useCallback((nav: WebViewNavigation) => {
    const l = loginRef.current;
    if (l?.doneWhenUrl && l.doneWhenUrl.test(nav.url)) endLogin('signed_in');
  }, [endLogin]);

  const onLoginShouldStart = useCallback((req: { url: string; isTopFrame?: boolean; mainDocumentURL?: string }) => {
    const l = loginRef.current;
    if (!l) return true;
    const top = req.isTopFrame ?? (Platform.OS === 'ios' ? (!req.mainDocumentURL || req.mainDocumentURL === req.url) : true);
    if (!top || req.url.startsWith('about:')) return true;
    // A data: or blob: page in the TOP frame is a page with no address under
    // the store's title: refused, as on iOS. allowNavigation refuses it below.
    if (l.doneWhenUrl && l.doneWhenUrl.test(req.url)) { setTimeout(() => endLogin('signed_in'), 0); return true; }
    return l.allowNavigation(req.url);
  }, [endLogin]);

  const loginWebView = login ? (
    <WebView
      ref={loginView}
      source={{ uri: login.url }}
      onLoadEnd={injectCheck}
      onMessage={onLoginMessage}
      onNavigationStateChange={onLoginNav}
      onShouldStartLoadWithRequest={onLoginShouldStart}
      originWhitelist={['*']}
      javaScriptEnabled
      domStorageEnabled
      sharedCookiesEnabled
      thirdPartyCookiesEnabled
      style={styles.flex}
    />
  ) : null;

  // ── the Host the relay drives ───────────────────────────────────────

  const host: Host = useMemo(() => ({
    openPage(store, url, timeoutMs) {
      hiddenStore.current = store;
      return new Promise((resolve) => {
        const t = setTimeout(() => { if (pageWaiter.current) { pageWaiter.current = null; resolve({ ok: false, error: 'timeout' }); } }, timeoutMs);
        pageWaiter.current = { resolve: (r) => { clearTimeout(t); resolve(r); } };
        setHiddenUri((cur) => ({ uri: url, n: cur.n + 1 }));
      });
    },
    runScript(_store, guard, script, until, timeoutMs) {
      return new Promise((resolve) => {
        const waiter: Waiter = { until, messages: [], resolve: () => {}, tag: { nonce: newNonce(), strict: false } };
        const t = setTimeout(() => { if (scriptWaiter.current === waiter) { scriptWaiter.current = null; resolve({ messages: waiter.messages, timedOut: true }); } }, timeoutMs);
        waiter.resolve = (timedOut) => { clearTimeout(t); resolve({ messages: waiter.messages, timedOut }); };
        scriptWaiter.current = waiter;
        if (!hidden.current) { scriptWaiter.current = null; clearTimeout(t); resolve({ messages: [], timedOut: false, error: 'no_webview' }); return; }
        hidden.current.injectJavaScript(tagScript(waiter.tag.nonce));
        hidden.current.injectJavaScript(guard);
        hidden.current.injectJavaScript(script);
      });
    },
    showLogin(opts) {
      return new Promise((resolve) => {
        const state: LoginState = {
          tag: { nonce: newNonce(), strict: false },
          url: opts.url, title: opts.title, guard: opts.guard, check: opts.check ?? null, doneWhen: opts.doneWhen,
          doneWhenUrl: opts.doneWhenUrl ? new RegExp(opts.doneWhenUrl) : null, allowNavigation: opts.allowNavigation,
          messages: [], finish: (outcome) => { clearTimeout(t); resolve({ outcome, messages: state.messages }); },
        };
        const t = setTimeout(() => endLogin('timeout'), opts.timeoutMs);
        loginRef.current = state;
        setLogin(state);
        if (state.check) checkTimer.current = setInterval(injectCheck, Math.max(1000, state.check.intervalMs));
      });
    },
    async fetch(store, req, timeoutMs, maxBytes) {
      const ctl = new AbortController();
      const t = setTimeout(() => ctl.abort(), timeoutMs);
      try {
        const res = await fetch(req.url, { method: req.method, headers: req.headers, body: req.body ?? undefined, credentials: 'include', signal: ctl.signal });
        // React Native follows redirects itself and cannot be told not to. A
        // response that ended up off the store's allowlist is not handed back.
        const finalUrl = (res as { url?: string }).url;
        const a = allowRef.current;
        if (finalUrl && finalUrl !== req.url && (!a || !a.check(store, finalUrl, 'fetch').ok)) {
          return { ok: false, error: 'redirect_blocked' };
        }
        const text = await res.text();
        const headers: Record<string, string> = {};
        res.headers.forEach((v: string, k: string) => { if (!PRIVATE_HEADERS.has(k.toLowerCase())) headers[k] = v; });
        return { ok: true, status: res.status, headers, body: text.slice(0, maxBytes), truncated: text.length > maxBytes };
      } catch {
        return { ok: false, error: ctl.signal.aborted ? 'timeout' : 'no_response' };
      } finally {
        clearTimeout(t);
      }
    },
  }), [endLogin, injectCheck]);

  const client = useMemo(() => new MealioClient({
    publishableKey: props.publishableKey,
    getSessionToken: props.getSessionToken,
    platform: 'react-native',
    sdkVersion: SDK_VERSION,
    baseUrl: props.baseUrl,
    getEpoch: () => epochStore.get(),
  }, host), [props.publishableKey, props.getSessionToken, props.baseUrl, host, epochStore]);
  allowRef.current = client.allowlist;

  const api: MealioApi = useMemo(() => ({
    theme,
    ui,
    prepareCart: (input, opts) => client.prepareCart(input, opts),
    stores: () => client.stores(),
    warm: (opts) => client.warm(opts),
    storeLocations: (store, zip) => client.storeLocations(store, zip),
    storePreferences: () => client.storePreferences(),
    setStore: (store, locationId) => client.setStore(store, locationId),
    openStoreSettings: () => setSettingsOpen(true),
    async signOutOfAllStores() {
      client.clearWarm();
      await epochStore.set((await epochStore.get()) + 1);
      // Nothing may keep running in, or remember, the old session's page.
      hiddenStore.current = null;
      setHiddenUri((cur) => ({ uri: 'about:blank', n: cur.n + 1 }));
      hidden.current?.clearCache?.(true);
      // Without a cookie manager there is no way to delete a WebView cookie
      // from React Native, so the stores' logins would survive. Saying so beats
      // a sign-out that only looks like it worked.
      const cookies = loadCookieManager();
      if (!cookies) {
        throw new MealioError('unsupported', `Install ${COOKIE_MANAGER} to sign out of stores.`);
      }
      if (typeof cookies.clearAllStores === 'function') {
        await cookies.clearAllStores();
      } else {
        await cookies.clearAll?.(true);
        await cookies.clearAll?.(false);
      }
    },
  }), [client, epochStore, theme, ui]);

  const internal: Internal = useMemo(() => ({
    login: login && loginWebView ? { title: login.title, webview: loginWebView, cancel: () => endLogin('cancelled') } : null,
    hostLogin: (on) => setHosts((n) => Math.max(0, n + (on ? 1 : -1))),
  }), [login, loginWebView, endLogin]);

  return (
    <ApiCtx.Provider value={api}>
      <InternalCtx.Provider value={internal}>
        {props.children}
        {settingsOpen ? <MealioStoreSettings visible onClose={() => setSettingsOpen(false)} /> : null}
        <View pointerEvents="none" style={styles.hidden}>
          <WebView
            ref={hidden}
            // A new key per navigation remounts the WebView, so re-opening the
            // same URL really reloads it. Cookies and storage are shared.
            key={`mealio-hidden-${hiddenUri.n}`}
            // On iOS, idle is a tiny page, not the address about:blank.
            // react-native-webview sends any address with no host to
            // loadFileURL, which throws on about:blank and kills the app at
            // launch. The page's baseUrl keeps its url about:blank. The html
            // must not be '' (the new architecture drops an empty string).
            source={Platform.OS === 'ios' && hiddenUri.uri === 'about:blank' ? IOS_IDLE : { uri: hiddenUri.uri }}
            // Every URL reaches onShouldStartLoadWithRequest: one that missed
            // originWhitelist would be handed to the OS (Linking.openURL)
            // instead of refused.
            originWhitelist={['*']}
            onShouldStartLoadWithRequest={onHiddenShouldStart}
            onLoadEnd={onHiddenLoadEnd}
            onError={onHiddenError}
            onMessage={onHiddenMessage}
            javaScriptEnabled
            domStorageEnabled
            sharedCookiesEnabled
            thirdPartyCookiesEnabled
            setSupportMultipleWindows={false}
            style={styles.hiddenView}
          />
        </View>
        <Modal visible={!!login && hosts === 0} animationType="slide" onRequestClose={() => endLogin('cancelled')} presentationStyle="pageSheet">
          <SafeAreaView style={[styles.flex, { backgroundColor: theme.background }]}>
            <View style={[styles.bar, { borderBottomColor: theme.border }]}>
              <Text style={[styles.title, { color: theme.text, fontFamily: theme.fontFamily }]} numberOfLines={1}>{login?.title}</Text>
              <Pressable accessibilityRole="button" onPress={() => endLogin('cancelled')} hitSlop={12}>
                <Text style={[styles.close, { color: theme.accent, fontFamily: theme.fontFamily }]}>{ui.tr('close')}</Text>
              </Pressable>
            </View>
            {hosts === 0 ? loginWebView : null}
          </SafeAreaView>
        </Modal>
      </InternalCtx.Provider>
    </ApiCtx.Provider>
  );
}

const IOS_IDLE = { html: '<html><body></body></html>', baseUrl: 'about:blank' };

const styles = StyleSheet.create({
  flex: { flex: 1 },
  // A WebView with no size or a hidden parent can be throttled or never load,
  // so the session WebView is 1x1 and transparent rather than unmounted.
  hidden: { position: 'absolute', width: 1, height: 1, opacity: 0, left: 0, top: 0, overflow: 'hidden' },
  hiddenView: { width: 1, height: 1, backgroundColor: 'transparent' },
  bar: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 16, paddingVertical: 12, borderBottomWidth: StyleSheet.hairlineWidth },
  title: { fontSize: 16, fontWeight: '600', flex: 1, marginRight: 12 },
  close: { fontSize: 16, fontWeight: '600' },
});
