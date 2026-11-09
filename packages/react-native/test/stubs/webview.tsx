import React from 'react';
// Every mounted WebView reports here, so a test can act as the page.
export const views: any = { hidden: null, login: null, injected: [] as string[], mounts: 0 };
export const WebView = React.forwardRef((p: any, ref: any) => {
  const isLogin = !!p.onNavigationStateChange;
  React.useImperativeHandle(ref, () => ({
    injectJavaScript(s: string) { views.injected.push(s); },
    clearCache() {},
  }));
  if (isLogin) views.login = p; else { views.hidden = p; }
  return React.createElement('WebView', { uri: p.source?.uri });
});
