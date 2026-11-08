// The provider loads react-native-webview and react-native-safe-area-context
// with require(), only when it renders them. Aliases cover imports, not
// require, so require gets the stubs here. `globalThis.__mealioRequire`
// counts what was required; `__noSafeArea` makes safe-area-context missing.
import Module from 'node:module';
import React from 'react';
import * as webview from 'react-native-webview';

const safeArea = {
  SafeAreaView: React.forwardRef((p: any, r: any) => React.createElement('SafeAreaContextView', { ...p, ref: r })),
};
const g = globalThis as any;
g.__mealioRequire = [] as string[];
const M = Module as unknown as { _load: (req: string, ...rest: unknown[]) => unknown };
const load = M._load;
M._load = function (req: string, ...rest: unknown[]) {
  if (req === 'react-native-webview') { g.__mealioRequire.push(req); return webview; }
  if (req === 'react-native-safe-area-context') {
    g.__mealioRequire.push(req);
    if (g.__noSafeArea) throw Object.assign(new Error(`Cannot find module '${req}'`), { code: 'MODULE_NOT_FOUND' });
    return safeArea;
  }
  return load.call(this, req, ...rest);
};
