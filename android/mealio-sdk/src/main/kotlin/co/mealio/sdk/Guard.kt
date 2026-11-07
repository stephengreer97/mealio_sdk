package co.mealio.sdk

// GUARD_SCRIPT runs in the store page before any server script. It is defense
// in depth: the signature on every envelope is the primary control. It stops a
// request that names checkout, payment or an order from leaving the device,
// whatever form the body takes (string, Request, Blob, form data), and caps the
// page at 240 requests a minute.
//
// Both scripts are byte-for-byte copies of packages/core/src/guard.ts, with the
// same interpolated regex sources. GuardScriptTest checks them against the
// TypeScript output, so do not reformat them.

/**
 * Operation and field names no request may carry (case-insensitive regex
 * source). Every SDK and the guard script use this exact list.
 */
const val BLOCKED_GRAPHQL_OPERATION = "check_?out|place_?order|submit_?order|confirm_?order|create_?order|purchase|payment"

/** Same output as JSON.stringify for a string. */
internal fun jsStringLiteral(s: String): String {
    val sb = StringBuilder("\"")
    for (c in s) {
        when {
            c == '"' -> sb.append("\\\"")
            c == '\\' -> sb.append("\\\\")
            c == '\n' -> sb.append("\\n")
            c == '\r' -> sb.append("\\r")
            c == '\t' -> sb.append("\\t")
            c == '\b' -> sb.append("\\b")
            c == '\u000C' -> sb.append("\\f")
            c < ' ' -> sb.append(String.format("\\u%04x", c.code))
            else -> sb.append(c)
        }
    }
    return sb.append('"').toString()
}

/** A raw string cannot hold three quotes in a row. */
private const val TRIPLE_QUOTE = "\"\"\""

val GUARD_SCRIPT: String = """(function(){
  if (window.__mealioGuard) return;
  window.__mealioGuard = true;
  var BLOCK = new RegExp(${jsStringLiteral(BLOCKED_PATTERNS.joinToString("|"))}, 'i');
  var OPS = new RegExp(${jsStringLiteral(BLOCKED_GRAPHQL_OPERATION)}, 'i');
  var stamps = [];
  function pathOf(u) {
    try { var a = new URL(String(u), location.href); return a.pathname + a.search; } catch (e) { return String(u || ''); }
  }
  function decoded(s) {
    for (var i = 0; i < 2; i++) s = s.replace(/%([0-9a-f]{2})/gi, function (x, h) { return String.fromCharCode(parseInt(h, 16)); });
    return s;
  }
  function pathBlocked(u) {
    var p = pathOf(u);
    return BLOCK.test(p) || BLOCK.test(decoded(p));
  }
  function mutationNames(doc) {
    var text = doc.replace(/${TRIPLE_QUOTE}(?:\\${TRIPLE_QUOTE}|[\s\S])*?${TRIPLE_QUOTE}|"(?:[^"\\]|\\.)*"|#[^\n\r]*/g, ' ');
    var tokens = text.match(/[A-Za-z_][A-Za-z0-9_]*|\.\.\.|[{}():@]/g) || [];
    var defs = [], def = null, sets = [], parens = 0, inline = false, expect = '', pushed = false, was, root, i, t;
    for (i = 0; i < tokens.length; i++) {
      t = tokens[i]; was = pushed; pushed = false;
      if (t === '(') { parens++; continue; }
      if (t === ')') { parens = Math.max(0, parens - 1); continue; }
      if (parens > 0) continue;
      if (t === '@') { expect = 'directive'; continue; }
      if (t === '{') {
        if (!def) { def = { kind: 'query', name: '', fields: [], spreads: [] }; defs.push(def); }
        sets.push(sets.length === 0 || (inline && sets[sets.length - 1]));
        inline = false; expect = '';
        continue;
      }
      if (t === '}') {
        sets.pop();
        inline = false; expect = '';
        if (sets.length === 0) def = null;
        continue;
      }
      if (sets.length === 0) {
        if (expect === 'directive') expect = '';
        else if (!def && /^(query|mutation|subscription|fragment)$/.test(t)) { def = { kind: t, name: '', fields: [], spreads: [] }; defs.push(def); }
        else if (def && !def.name && t !== 'on' && t !== ':' && t !== '...') def.name = t;
        continue;
      }
      root = sets[sets.length - 1];
      if (t === '...') { expect = 'spread'; inline = true; continue; }
      if (t === ':') { if (was && def) def.fields.pop(); continue; }
      if (expect === 'directive' || expect === 'type') { expect = ''; continue; }
      if (expect === 'spread') {
        expect = '';
        if (t === 'on') { expect = 'type'; continue; }
        inline = false;
        if (root && def) def.spreads.push(t);
        continue;
      }
      inline = false;
      if (root && def) { def.fields.push(t); pushed = true; }
    }
    var fragments = {}, names = [], seen, j;
    for (i = 0; i < defs.length; i++) if (defs[i].kind === 'fragment') fragments['f_' + defs[i].name] = defs[i];
    function walk(x) {
      names = names.concat(x.fields);
      for (var k = 0; k < x.spreads.length; k++) {
        var f = fragments['f_' + x.spreads[k]];
        if (f && !seen['f_' + x.spreads[k]]) { seen['f_' + x.spreads[k]] = true; walk(f); }
      }
    }
    for (j = 0; j < defs.length; j++) {
      if (defs[j].kind !== 'mutation') continue;
      if (defs[j].name) names.push(defs[j].name);
      seen = {};
      walk(defs[j]);
    }
    return names;
  }
  function bodyBlocked(b) {
    if (typeof b !== 'string' || !b) return false;
    var names = [], docs = [], re = /"operationName"\s*:\s*"([^"]*)"/g, m, i;
    while ((m = re.exec(b))) names.push(m[1]);
    try {
      var j = JSON.parse(b);
      var list = Object.prototype.toString.call(j) === '[object Array]' ? j : [j];
      for (i = 0; i < list.length; i++) {
        var o = list[i];
        if (!o || typeof o !== 'object') continue;
        if (typeof o.operationName === 'string') names.push(o.operationName);
        if (typeof o.query === 'string') docs.push(o.query);
      }
    } catch (e) {
      docs.push(b);
      var form = /(?:^|&)(operationName|query|operations)=([^&]*)/g;
      while ((m = form.exec(b))) {
        var v = decoded(m[2].replace(/\+/g, ' '));
        if (m[1] === 'query') docs.push(v);
        else if (m[1] === 'operations') { if (bodyBlocked(v)) return true; }
        else names.push(v);
      }
    }
    for (i = 0; i < docs.length; i++) names = names.concat(mutationNames(docs[i]));
    for (i = 0; i < names.length; i++) if (OPS.test(names[i])) return true;
    return false;
  }
  function isA(v, name) {
    return typeof window[name] === 'function' && v instanceof window[name];
  }
  function fromForm(f) {
    var q = [], keys = ['operationName', 'query', 'operations'], i, k;
    for (i = 0; i < keys.length; i++) { k = f.get(keys[i]); if (typeof k === 'string') q.push(keys[i] + '=' + encodeURIComponent(k)); }
    return q.join('&');
  }
  // A body as text: a string now, or a promise for one when it has to be read.
  function bodyText(b) {
    if (b === null || b === undefined || typeof b === 'string') return b;
    if (isA(b, 'URLSearchParams')) return String(b);
    if (isA(b, 'FormData')) return fromForm(b);
    if (isA(b, 'Blob')) return b.text();
    if (isA(b, 'ArrayBuffer') || (window.ArrayBuffer && window.ArrayBuffer.isView && window.ArrayBuffer.isView(b))) return new window.Blob([b]).text();
    return null;
  }
  // What a fetch call sends. init.body wins over a Request's own, as in fetch.
  function fetchBody(input, init) {
    if (init && init.body !== undefined && init.body !== null) return bodyText(init.body);
    if (!input || typeof input !== 'object') return null;
    if (typeof input.body === 'string') return input.body;
    if (typeof input.clone !== 'function' || /^(GET|HEAD)$/i.test(input.method || 'GET')) return null;
    // A body already read, or a stream that cannot be cloned, cannot be judged: it goes through.
    try { return input.clone().text(); } catch (e) { return null; }
  }
  // Text that cannot be read goes through: fetch itself will fail on it.
  function settled(text, go) {
    if (!text || typeof text.then !== 'function') return go(text);
    return text.then(go, function () { return go(null); });
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
      var self = this, args = arguments;
      if (pathBlocked(url)) return Promise.reject(refuse('blocked_path'));
      return settled(fetchBody(input, init), function (body) {
        if (bodyBlocked(body)) return Promise.reject(refuse('blocked_operation'));
        if (overRate()) return Promise.reject(refuse('rate'));
        return f.apply(self, args);
      });
    };
  }
  var nav = window.navigator, beacon = nav && nav.sendBeacon;
  if (beacon) {
    // A beacon cannot wait for a Blob to be read, so only text bodies are allowed.
    nav.sendBeacon = function (url, data) {
      if (pathBlocked(url)) { refuse('blocked_path'); return false; }
      var text = data == null ? '' : bodyText(data);
      if (text && typeof text.then === 'function') { refuse('blocked_operation'); return false; }
      if (bodyBlocked(text)) { refuse('blocked_operation'); return false; }
      return beacon.apply(nav, arguments);
    };
  }
  var X = window.XMLHttpRequest;
  if (X && X.prototype) {
    var open = X.prototype.open, send = X.prototype.send;
    X.prototype.open = function (m, u) { this.__mealioUrl = u; return open.apply(this, arguments); };
    X.prototype.send = function (b) {
      var self = this, args = arguments, text = bodyText(b);
      if (pathBlocked(this.__mealioUrl)) throw refuse('blocked_path');
      function go(body) {
        if (bodyBlocked(body)) throw refuse('blocked_operation');
        if (overRate()) throw refuse('rate');
        return send.apply(self, args);
      }
      if (!text || typeof text.then !== 'function') return go(text);
      // send() cannot wait, so a Blob is read first and sent after. A refused one never goes.
      text.then(go, function () { return send.apply(self, args); }).then(null, function () { try { self.abort(); } catch (e) {} });
    };
  }
})(); true;"""

/**
 * Injected at document start so store scripts can post with the same call
 * React Native's WebView provides. `__mealioNativePost` is the Android
 * JavascriptInterface bridge (see WebViewHost).
 */
val BRIDGE_SHIM: String = """(function(){
  if (window.ReactNativeWebView) return;
  window.ReactNativeWebView = { postMessage: function (s) { try { window.__mealioNativePost(String(s)); } catch (e) {} } };
})(); true;"""
