// Native modules the provider loads only when it needs them. A require inside
// a function runs when the function does: under `testing` no WebView is
// rendered, so react-native-webview is never loaded and a partner's plain jest
// needs no mock for it. Metro still bundles both (the names are static).

import type * as WebViewModule from 'react-native-webview';
import type { ComponentType, ReactNode } from 'react';
import type { StyleProp, ViewStyle } from 'react-native';

let webview: typeof WebViewModule | null = null;

/** react-native-webview, loaded the first time a WebView is rendered. */
export function loadWebView(): typeof WebViewModule {
  // eslint-disable-next-line @typescript-eslint/no-var-requires
  if (!webview) webview = require('react-native-webview') as typeof WebViewModule;
  return webview;
}

export type InsetView = ComponentType<{ style?: StyleProp<ViewStyle>; edges?: ReadonlyArray<'top' | 'right' | 'bottom' | 'left'>; children?: ReactNode }>;

/**
 * react-native-safe-area-context's SafeAreaView, or null when the app does not
 * have it. It measures its own window, so it is right inside a Modal and edge
 * to edge on Android. In a try, so Metro treats it as optional.
 */
export function loadInsetView(): InsetView | null {
  try {
    // eslint-disable-next-line @typescript-eslint/no-var-requires
    const m = require('react-native-safe-area-context');
    return (m && m.SafeAreaView) || null;
  } catch {
    return null;
  }
}
