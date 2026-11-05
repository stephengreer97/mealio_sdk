// Every published package must carry the same version, and a release tag must
// name it. Run in CI and by the release workflow: `node scripts/check-versions.mjs [v0.4.0]`.
import fs from 'node:fs';

const read = (p) => fs.readFileSync(new URL(`../${p}`, import.meta.url), 'utf8');
const found = {
  '@mealio/sdk-core': JSON.parse(read('packages/core/package.json')).version,
  '@mealio/react-native-cart': JSON.parse(read('packages/react-native/package.json')).version,
  'react-native-cart -> sdk-core dependency': JSON.parse(read('packages/react-native/package.json')).dependencies['@mealio/sdk-core'],
  'react-native SDK_VERSION': /SDK_VERSION = '([^']+)'/.exec(read('packages/react-native/src/MealioProvider.tsx'))?.[1],
  'pub.dev mealio_sdk': /^version: (\S+)/m.exec(read('flutter/pubspec.yaml'))?.[1],
  'flutter mealioSdkVersion': /mealioSdkVersion = '([^']+)'/.exec(read('flutter/lib/src/client.dart'))?.[1],
  'maven mealioVersion': /^mealioVersion=(\S+)/m.exec(read('android/gradle.properties'))?.[1],
  'android SDK_VERSION': /SDK_VERSION = "([^"]+)"/.exec(read('android/mealio-sdk/src/main/kotlin/co/mealio/sdk/MealioCart.kt'))?.[1],
  'cocoapods MealioSDK': /s\.version\s*=\s*'([^']+)'/.exec(read('MealioSDK.podspec'))?.[1],
  'ios MEALIO_SDK_VERSION': /MEALIO_SDK_VERSION = "([^"]+)"/.exec(read('ios/Sources/MealioSDK/MealioClient.swift'))?.[1],
};
const want = process.argv[2] ? process.argv[2].replace(/^v/, '') : found['@mealio/sdk-core'];
const bad = Object.entries(found).filter(([, v]) => v !== want);
for (const [k, v] of Object.entries(found)) console.log(`${v === want ? 'ok ' : 'BAD'} ${k}: ${v}`);
if (bad.length) {
  console.error(`\n${bad.length} version(s) differ from ${want}. Bump them all together.`);
  process.exit(1);
}
