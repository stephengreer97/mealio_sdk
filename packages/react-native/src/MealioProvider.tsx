// The React Native host. Place <MealioProvider> once near the root of the app.
// It renders:
//   - a hidden 1x1 WebView: the store session the relay works in
//   - a login sheet (Modal + visible WebView) when a store asks the user to sign in
// Both WebViews share the platform's cookie store, so a login in the sheet is
// the session the hidden WebView uses.

import React, { createContext, useCallback, useContext, useMemo, useRef, useState } from 'react';
import { Modal, Platform, Pressable, SafeAreaView, StyleSheet, Text, View } from 'react-native';
import { WebView, type WebViewMessageEvent, type WebViewNavigation } from 'react-native-webview';
import {
  MealioClient, matchesAny, parseMessage,
  type CartSession, type Host, type JsonMessage, type Matcher, type Recipe,
} from '@mealio/sdk-core';

export const SDK_VERSION = '0.1.0';

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
  /** Accent color for the login sheet header. */
  accentColor?: string;
  children: React.ReactNode;
}

export interface MealioApi {
  prepareCart(input: { store: string; recipe: Recipe; zip?: string | null }): Promise<CartSession>;
  signOutOfAllStores(): Promise<void>;
}

const Ctx = createContext<MealioApi | null>(null);

export function useMealio(): MealioApi {
  const v = useContext(Ctx);
  if (!v) throw new Error('useMealio must be used inside <MealioProvider>');
  return v;
}

type Waiter = { until: Matcher[]; messages: JsonMessage[]; resolve: (timedOut: boolean) => void };

interface LoginState {
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
  const hidden = useRef<WebView>(null);
  const loginView = useRef<WebView>(null);
  const [hiddenUri, setHiddenUri] = useState<{ uri: string; n: number }>({ uri: 'about:blank', n: 0 });
  const pageWaiter = useRef<{ resolve: (r: { ok: boolean; finalUrl?: string; error?: string }) => void } | null>(null);
  const scriptWaiter = useRef<Waiter | null>(null);
  const [login, setLogin] = useState<LoginState | null>(null);
  const loginRef = useRef<LoginState | null>(null);
  const checkTimer = useRef<ReturnType<typeof setInterval> | null>(null);
  const epochStore = useMemo(() => props.epochStorage || memoryEpoch(), [props.epochStorage]);

  // ── hidden WebView ───────────────────────────────────────────────────

  const onHiddenLoadEnd = useCallback((e: { nativeEvent: { url: string; loading?: boolean } }) => {
    const w = pageWaiter.current;
    if (!w || e.nativeEvent.url === 'about:blank') return;
    pageWaiter.current = null;
    w.resolve({ ok: true, finalUrl: e.nativeEvent.url });
  }, []);

  const onHiddenError = useCallback(() => {
    const w = pageWaiter.current;
    if (!w) return;
    pageWaiter.current = null;
    w.resolve({ ok: false, error: 'load_failed' });
  }, []);

  const onHiddenMessage = useCallback((e: WebViewMessageEvent) => {
    const msg = parseMessage(e.nativeEvent.data);
    const w = scriptWaiter.current;
    if (!msg || !w) return;
    w.messages.push(msg);
    if (matchesAny(msg, w.until)) { scriptWaiter.current = null; w.resolve(false); }
  }, []);

  // ── login sheet ──────────────────────────────────────────────────────

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
    loginView.current?.injectJavaScript(l.guard);
    loginView.current?.injectJavaScript(l.check.script);
  }, []);

  const onLoginLoadEnd = useCallback(() => { injectCheck(); }, [injectCheck]);

  const onLoginMessage = useCallback((e: WebViewMessageEvent) => {
    const l = loginRef.current;
    const msg = parseMessage(e.nativeEvent.data);
    if (!l || !msg) return;
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
    // Android reports isTopFrame; iOS reports mainDocumentURL === url for a top-frame load.
    const top = req.isTopFrame ?? (Platform.OS === 'ios' ? (!req.mainDocumentURL || req.mainDocumentURL === req.url) : true);
    if (!top || req.url.startsWith('about:') || req.url.startsWith('blob:') || req.url.startsWith('data:')) return true;
    if (l.doneWhenUrl && l.doneWhenUrl.test(req.url)) { setTimeout(() => endLogin('signed_in'), 0); return true; }
    return l.allowNavigation(req.url);
  }, [endLogin]);

  // ── the Host the relay drives ───────────────────────────────────────

  const host: Host = useMemo(() => ({
    openPage(_store, url, timeoutMs) {
      return new Promise((resolve) => {
        const t = setTimeout(() => { if (pageWaiter.current) { pageWaiter.current = null; resolve({ ok: false, error: 'timeout' }); } }, timeoutMs);
        pageWaiter.current = { resolve: (r) => { clearTimeout(t); resolve(r); } };
        setHiddenUri((cur) => ({ uri: url, n: cur.n + 1 }));
      });
    },
    runScript(_store, guard, script, until, timeoutMs) {
      return new Promise((resolve) => {
        const waiter: Waiter = { until, messages: [], resolve: () => {} };
        const t = setTimeout(() => { if (scriptWaiter.current === waiter) { scriptWaiter.current = null; resolve({ messages: waiter.messages, timedOut: true }); } }, timeoutMs);
        waiter.resolve = (timedOut) => { clearTimeout(t); resolve({ messages: waiter.messages, timedOut }); };
        scriptWaiter.current = waiter;
        if (!hidden.current) { scriptWaiter.current = null; clearTimeout(t); resolve({ messages: [], timedOut: false, error: 'no_webview' }); return; }
        hidden.current.injectJavaScript(guard);
        hidden.current.injectJavaScript(script);
      });
    },
    showLogin(opts) {
      return new Promise((resolve) => {
        const state: LoginState = {
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
    async fetch(_store, req, timeoutMs, maxBytes) {
      // Runs from the native side with credentials. On Android React Native's
      // fetch shares the WebView cookie jar; on iOS it does not, which is why
      // the server sends page_script, not fetch, for every store today.
      const ctl = new AbortController();
      const t = setTimeout(() => ctl.abort(), timeoutMs);
      try {
        const res = await fetch(req.url, { method: req.method, headers: req.headers, body: req.body ?? undefined, credentials: 'include', signal: ctl.signal });
        const text = await res.text();
        const headers: Record<string, string> = {};
        res.headers.forEach((v: string, k: string) => { headers[k] = v; });
        return { ok: true, status: res.status, headers, body: text.slice(0, maxBytes), truncated: text.length > maxBytes };
      } catch (e) {
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

  const api: MealioApi = useMemo(() => ({
    prepareCart: (input) => client.prepareCart(input),
    async signOutOfAllStores() {
      await epochStore.set((await epochStore.get()) + 1);
      try {
        // Optional peer: @react-native-cookies/cookies clears both jars.
        // eslint-disable-next-line @typescript-eslint/no-var-requires
        const CookieManager = require('@react-native-cookies/cookies').default;
        await CookieManager.clearAll(true);
        await CookieManager.clearAll(false);
      } catch {
        hidden.current?.clearCache?.(true);
      }
    },
  }), [client, epochStore]);

  return (
    <Ctx.Provider value={api}>
      {props.children}
      <View pointerEvents="none" style={styles.hidden}>
        <WebView
          ref={hidden}
          // A new key per navigation remounts the WebView, so re-opening the
          // same URL really reloads it. Cookies and storage are shared, so
          // nothing a store needs is lost.
          key={`mealio-hidden-${hiddenUri.n}`}
          source={{ uri: hiddenUri.uri }}
          originWhitelist={['https://*', 'about:*']}
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
      <Modal visible={!!login} animationType="slide" onRequestClose={() => endLogin('cancelled')} presentationStyle="pageSheet">
        <SafeAreaView style={styles.sheet}>
          <View style={[styles.bar, { borderBottomColor: props.accentColor || '#e5e5e5' }]}>
            <Text style={styles.title} numberOfLines={1}>{login?.title}</Text>
            <Pressable accessibilityRole="button" onPress={() => endLogin('cancelled')} hitSlop={12}>
              <Text style={[styles.close, { color: props.accentColor || '#0a7' }]}>Close</Text>
            </Pressable>
          </View>
          {login && (
            <WebView
              ref={loginView}
              source={{ uri: login.url }}
              onLoadEnd={onLoginLoadEnd}
              onMessage={onLoginMessage}
              onNavigationStateChange={onLoginNav}
              onShouldStartLoadWithRequest={onLoginShouldStart}
              javaScriptEnabled
              domStorageEnabled
              sharedCookiesEnabled
              thirdPartyCookiesEnabled
              style={styles.sheetView}
            />
          )}
        </SafeAreaView>
      </Modal>
    </Ctx.Provider>
  );
}

const styles = StyleSheet.create({
  // A WebView with no size or a hidden parent can be throttled or never load,
  // so the session WebView is 1x1 and transparent rather than unmounted.
  hidden: { position: 'absolute', width: 1, height: 1, opacity: 0, left: 0, top: 0, overflow: 'hidden' },
  hiddenView: { width: 1, height: 1, backgroundColor: 'transparent' },
  sheet: { flex: 1, backgroundColor: '#fff' },
  bar: { flexDirection: 'row', alignItems: 'center', justifyContent: 'space-between', paddingHorizontal: 16, paddingVertical: 12, borderBottomWidth: 2 },
  title: { fontSize: 16, fontWeight: '600', flex: 1, marginRight: 12, color: '#111' },
  close: { fontSize: 16, fontWeight: '600' },
  sheetView: { flex: 1 },
});
