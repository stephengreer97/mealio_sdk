// Simmer uses the Mealio SDK straight from this repo's source, the way a fix to
// the SDK shows up in the demo on the next reload. Two aliases point the
// package names at packages/*/src, and React, React Native and the rest
// always resolve from Simmer's own node_modules: the SDK packages pin older
// dev copies that must never be bundled next to the app's.
const path = require('path');
const { getDefaultConfig } = require('expo/metro-config');

const projectRoot = __dirname;
const repoRoot = path.resolve(projectRoot, '../..');
const config = getDefaultConfig(projectRoot);

const SDK = {
  '@mealio/react-native-cart': path.join(repoRoot, 'packages/react-native/src/index.ts'),
  '@mealio/sdk-core': path.join(repoRoot, 'packages/core/src/index.ts'),
};

config.watchFolders = [path.join(repoRoot, 'packages')];
config.resolver.nodeModulesPaths = [path.join(projectRoot, 'node_modules')];
// Never pick up a node_modules folder inside the repo outside Simmer.
const escape = (p) => p.replace(/[/\\^$.*+?()[\]{}|-]/g, '\\$&');
config.resolver.blockList = [
  new RegExp(`^${escape(path.join(repoRoot, 'node_modules'))}/.*`),
  new RegExp(`^${escape(path.join(repoRoot, 'packages'))}/[^/]+/node_modules/.*`),
];
const upstream = config.resolver.resolveRequest;
config.resolver.resolveRequest = (context, moduleName, platform) => {
  if (SDK[moduleName]) return { type: 'sourceFile', filePath: SDK[moduleName] };
  return (upstream || context.resolveRequest)(context, moduleName, platform);
};

module.exports = config;
