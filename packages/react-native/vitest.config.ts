import { defineConfig } from 'vitest/config';
import path from 'node:path';

const here = path.dirname(new URL(import.meta.url).pathname);

// React Native itself cannot load under Node: the screens render against small
// stubs, and the core runs from source so no build is needed first.
export default defineConfig({
  esbuild: { jsx: 'transform', jsxFactory: 'React.createElement', jsxFragment: 'React.Fragment' },
  resolve: {
    alias: [
      { find: /^@mealio\/sdk-core\/testing$/, replacement: path.join(here, '../core/src/testing.ts') },
      { find: /^@mealio\/sdk-core$/, replacement: path.join(here, '../core/src/index.ts') },
      { find: /^react-native$/, replacement: path.join(here, 'test/stubs/rn.tsx') },
      { find: /^react-native-webview$/, replacement: path.join(here, 'test/stubs/webview.tsx') },
    ],
  },
  test: { include: ['test/**/*.test.{ts,tsx}'], testTimeout: 15000, server: { deps: { inline: [/react-test-renderer/] } } },
});
