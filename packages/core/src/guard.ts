// GUARD_SCRIPT runs in the store page before any server script. It is defense
// in depth: the signature on every envelope is the primary control. It stops a
// request that names checkout, payment or an order from leaving the device,
// whatever form the body takes (string, Request, Blob, form data, raw
// multipart text), and caps the page at 240 requests a minute. It goes into
// every same-origin frame of the page, and refuses workers made from blob: or
// data: URLs, whose requests it could not read.
//
// It must stay plain ES5 with no dependencies, because it is injected as text
// into WebViews on four platforms.

import { BLOCKED_GRAPHQL_OPERATION, BLOCKED_PATTERNS, MULTIPART_FIELD } from './allowlist';

export { BLOCKED_GRAPHQL_OPERATION };

// The same rule as mutationNames in allowlist.ts, in ES5 (see there).
const MUTATION_NAMES_JS = String.raw`function mutationNames(doc) {
    var text = doc.replace(/"""(?:\\"""|[\s\S])*?"""|"(?:[^"\\]|\\.)*"|#[^\n\r]*/g, ' ');
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
  }`;

export const GUARD_SCRIPT = `(function(){
  if (window.__mealioGuard) return;
  var BLOCK = new RegExp(${JSON.stringify(BLOCKED_PATTERNS.join('|'))}, 'i');
  var OPS = new RegExp(${JSON.stringify(BLOCKED_GRAPHQL_OPERATION)}, 'i');
  var PART = ${JSON.stringify(MULTIPART_FIELD)};
  var root = window, stamps = [];
  function decoded(s) {
    for (var i = 0; i < 2; i++) s = s.replace(/%([0-9a-f]{2})/gi, function (x, h) { return String.fromCharCode(parseInt(h, 16)); });
    return s;
  }
  ${MUTATION_NAMES_JS}
  function bodyBlocked(b) {
    if (typeof b !== 'string') return false;
    if (b.charCodeAt(0) === 0xFEFF) b = b.slice(1);
    if (!b) return false;
    var names = [], docs = [], re = /"operationName"\\s*:\\s*"([^"]*)"/g, m, i;
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
        var v = decoded(m[2].replace(/\\+/g, ' '));
        if (m[1] === 'query') docs.push(v);
        else if (m[1] === 'operations') { if (bodyBlocked(v)) return true; }
        else names.push(v);
      }
      var part = new RegExp(PART, 'g');
      while ((m = part.exec(b))) {
        if (m[1] === 'query') docs.push(m[2]);
        else if (m[1] === 'operations') { if (bodyBlocked(m[2])) return true; }
        else names.push(m[2]);
      }
    }
    for (i = 0; i < docs.length; i++) names = names.concat(mutationNames(docs[i]));
    for (i = 0; i < names.length; i++) if (OPS.test(names[i])) return true;
    return false;
  }
  function overRate() {
    var now = Date.now();
    while (stamps.length && now - stamps[0] > 60000) stamps.shift();
    if (stamps.length >= 240) return true;
    stamps.push(now);
    return false;
  }
  function refuse(why) {
    try { root.ReactNativeWebView && root.ReactNativeWebView.postMessage(JSON.stringify({ type: 'MEALIO_GUARD_BLOCKED', why: why })); } catch (e) {}
    return new Error('mealio guard: ' + why);
  }
  // A same-origin frame gets the guard too, the first time it is reached. A
  // cross-origin one throws on the first read and is left alone: its requests
  // carry its own origin, not the store's cookies.
  function intoFrame(w) {
    try { if (w && !w.__mealioGuard) install(w); } catch (e) {}
  }
  // Every window the guard is in: the page and its same-origin frames.
  function install(w) {
    w.__mealioGuard = true;
    var loc = w.location;
    function pathOf(u) {
      try { var a = new URL(String(u), loc.href); return a.pathname + a.search; } catch (e) { return String(u || ''); }
    }
    function pathBlocked(u) {
      var p = pathOf(u);
      return BLOCK.test(p) || BLOCK.test(decoded(p));
    }
    // A body may come from another frame of the page, so either one's classes count.
    function isA(v, name) {
      return (typeof w[name] === 'function' && v instanceof w[name]) || (typeof root[name] === 'function' && v instanceof root[name]);
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
      var AB = w.ArrayBuffer;
      if (isA(b, 'ArrayBuffer') || (AB && AB.isView && AB.isView(b))) return new w.Blob([b]).text();
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
    var f = w.fetch;
    if (f) {
      w.fetch = function (input, init) {
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
    var nav = w.navigator, beacon = nav && nav.sendBeacon;
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
    var X = w.XMLHttpRequest;
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
    // A worker runs outside every window, so its requests would pass unread.
    // One made from the page's own text (blob: or data:) is refused; a worker
    // script the store serves from its own https address is the store's code.
    function guardWorker(name) {
      var W = w[name];
      if (typeof W !== 'function') return;
      var G = function (url, opts) {
        var scheme = '';
        try { scheme = new URL(String(url), loc.href).protocol; } catch (e) {}
        if (scheme === 'blob:' || scheme === 'data:') throw refuse('blocked_worker');
        return arguments.length > 1 ? new W(url, opts) : new W(url);
      };
      G.prototype = W.prototype;
      w[name] = G;
    }
    guardWorker('Worker');
    guardWorker('SharedWorker');
    // Frames: through the element's contentWindow and contentDocument, when
    // one is added to the page, and again after each load.
    var tags = ['HTMLIFrameElement', 'HTMLFrameElement', 'HTMLObjectElement'], t;
    function hook(E, prop) {
      var d = Object.getOwnPropertyDescriptor(E.prototype, prop);
      if (!d || !d.get || !d.configurable) return;
      Object.defineProperty(E.prototype, prop, {
        configurable: true, enumerable: d.enumerable,
        get: function () {
          var v = d.get.call(this);
          intoFrame(prop === 'contentWindow' ? v : v && v.defaultView);
          return v;
        },
      });
    }
    for (t = 0; t < tags.length; t++) {
      var E = w[tags[t]];
      if (typeof E === 'function' && E.prototype && Object.getOwnPropertyDescriptor) { hook(E, 'contentWindow'); hook(E, 'contentDocument'); }
    }
    function watch(el) {
      intoFrame(el.contentWindow);
      if (el.__mealioWatched || !el.addEventListener) return;
      el.__mealioWatched = true;
      el.addEventListener('load', function () { intoFrame(el.contentWindow); });
    }
    function scan(n) {
      if (!n || n.nodeType !== 1) return;
      if (/^(IFRAME|FRAME|OBJECT)$/i.test(n.nodeName)) watch(n);
      if (!n.getElementsByTagName) return;
      var names = ['iframe', 'frame', 'object'], i, j, l;
      for (i = 0; i < names.length; i++) {
        l = n.getElementsByTagName(names[i]);
        for (j = 0; j < l.length; j++) watch(l[j]);
      }
    }
    var N = w.Node, ins = ['appendChild', 'insertBefore', 'replaceChild'];
    if (N && N.prototype) {
      for (t = 0; t < ins.length; t++) (function (name) {
        var o = N.prototype[name];
        if (typeof o !== 'function') return;
        N.prototype[name] = function (n) { var r = o.apply(this, arguments); scan(n); return r; };
      })(ins[t]);
    }
    var MO = w.MutationObserver, doc = w.document;
    if (MO && doc) {
      new MO(function (records) {
        for (var i = 0; i < records.length; i++) for (var j = 0; j < records[i].addedNodes.length; j++) scan(records[i].addedNodes[j]);
      }).observe(doc, { childList: true, subtree: true });
      scan(doc.documentElement);
    }
  }
  install(window);
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
