// GUARD_SCRIPT runs in the store page before any server script. It is defense
// in depth: the signature on every envelope is the primary control. It stops a
// request that names checkout, payment or an order from leaving the device,
// and caps the page at 240 requests a minute.
//
// It must stay plain ES5 with no dependencies, because it is injected as text
// into WebViews on four platforms.

import { BLOCKED_PATTERNS } from './allowlist';

export const BLOCKED_GRAPHQL_OPERATION = 'checkout|placeorder|submitorder|payment';

export const GUARD_SCRIPT = `(function(){
  if (window.__mealioGuard) return;
  window.__mealioGuard = true;
  var BLOCK = new RegExp(${JSON.stringify(BLOCKED_PATTERNS.join('|'))}, 'i');
  var OPS = new RegExp(${JSON.stringify(BLOCKED_GRAPHQL_OPERATION)}, 'i');
  var stamps = [];
  function pathOf(u) {
    try { var a = new URL(String(u), location.href); return a.pathname + a.search; } catch (e) { return String(u || ''); }
  }
  function bodyBlocked(b) {
    if (typeof b !== 'string') return false;
    var m = /"operationName"\\s*:\\s*"([^"]+)"/.exec(b);
    return !!(m && OPS.test(m[1]));
  }
  function overRate() {
    var now = Date.now();
    while (stamps.length && now - stamps[0] > 60000) stamps.shift();
    if (stamps.length >= 240) return true;
    stamps.push(now);
    return false;
  }
  function refuse(why) {
    try { window.ReactNativeWebView && window.ReactNativeWebView.postMessage(JSON.stringify({ type: 'MEALIO_GUARD_BLOCKED', why: why })); } catch (e) {}
    return new Error('mealio guard: ' + why);
  }
  var f = window.fetch;
  if (f) {
    window.fetch = function (input, init) {
      var url = (input && typeof input === 'object' && input.url) ? input.url : input;
      var body = init && init.body;
      if (BLOCK.test(pathOf(url))) return Promise.reject(refuse('blocked_path'));
      if (bodyBlocked(body)) return Promise.reject(refuse('blocked_operation'));
      if (overRate()) return Promise.reject(refuse('rate'));
      return f.apply(this, arguments);
    };
  }
  var X = window.XMLHttpRequest;
  if (X && X.prototype) {
    var open = X.prototype.open, send = X.prototype.send;
    X.prototype.open = function (m, u) { this.__mealioUrl = u; return open.apply(this, arguments); };
    X.prototype.send = function (b) {
      if (BLOCK.test(pathOf(this.__mealioUrl))) throw refuse('blocked_path');
      if (bodyBlocked(b)) throw refuse('blocked_operation');
      if (overRate()) throw refuse('rate');
      return send.apply(this, arguments);
    };
  }
})(); true;`;

/**
 * Native SDKs (iOS, Android, Flutter) inject this at document start so the
 * store scripts can post with the same call React Native's WebView provides.
 * `__mealioNativePost` is the platform's own bridge (a WKScriptMessageHandler,
 * an Android JavascriptInterface, or a Flutter JavaScriptChannel).
 */
export const BRIDGE_SHIM = `(function(){
  if (window.ReactNativeWebView) return;
  window.ReactNativeWebView = { postMessage: function (s) { try { window.__mealioNativePost(String(s)); } catch (e) {} } };
})(); true;`;
