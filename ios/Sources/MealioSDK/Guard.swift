// GUARD_SCRIPT and BRIDGE_SHIM, byte for byte the same text as
// packages/core/src/guard.ts. The guard runs in the store page before any
// server script. It is defense in depth: the signature on every envelope is the
// primary control. It stops a request that names checkout, payment or an order
// from leaving the device, and caps the page at 240 requests a minute.
//
// Both scripts are plain ES5 so they run in every WebView. The test suite
// compares them with text generated from the TS reference.

import Foundation

public enum MealioScripts {
    /// GraphQL operation names the guard refuses (case-insensitive regex source).
    public static let blockedGraphQLOperation = "checkout|placeorder|submitorder|payment"

    /// Injected before every server script (page_script and the login check).
    public static let guardScript: String = #"""
(function(){
  if (window.__mealioGuard) return;
  window.__mealioGuard = true;
  var BLOCK = new RegExp(\#(MealioScripts.jsStringLiteral(Allowlist.blockedPatterns.joined(separator: "|"))), 'i');
  var OPS = new RegExp(\#(MealioScripts.jsStringLiteral(MealioScripts.blockedGraphQLOperation)), 'i');
  var stamps = [];
  function pathOf(u) {
    try { var a = new URL(String(u), location.href); return a.pathname + a.search; } catch (e) { return String(u || ''); }
  }
  function bodyBlocked(b) {
    if (typeof b !== 'string') return false;
    var m = /"operationName"\s*:\s*"([^"]+)"/.exec(b);
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
})(); true;
"""#

    /// Injected at document start so store scripts can post with the same call
    /// React Native's WebView provides. `__mealioNativePost` is defined by
    /// WebViewHost and forwards to the WKScriptMessageHandler named "mealio".
    public static let bridgeShim: String = #"""
(function(){
  if (window.ReactNativeWebView) return;
  window.ReactNativeWebView = { postMessage: function (s) { try { window.__mealioNativePost(String(s)); } catch (e) {} } };
})(); true;
"""#

    /// JSON.stringify for a string: the same quoting the TS template uses when
    /// it interpolates the regex sources into the guard.
    static func jsStringLiteral(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case "\u{08}": out += "\\b"
            case "\u{0C}": out += "\\f"
            default:
                if u.value < 0x20 {
                    out += String(format: "\\u%04x", u.value)
                } else {
                    out.unicodeScalars.append(u)
                }
            }
        }
        out += "\""
        return out
    }
}
