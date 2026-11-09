// GUARD_SCRIPT runs in the store page. It is defense in depth: the signature
// on every envelope is the primary control. Once armed, it stops a request
// that names checkout, payment or an order from leaving the device, whatever
// form the body takes (string, Request, Blob, form data, raw multipart text),
// and caps the page at 240 requests a minute. It goes into every same-origin
// frame of the page, and refuses workers made from blob: or data: URLs, whose
// requests it could not read. It never installs in a cross-origin frame.
//
// It installs UNARMED (every hook passes straight through) and arms on
// `window.__mealioArm()`. The other SDKs inject GUARD_SCRIPT into every frame
// at document start through the platform. webview_flutter cannot: it has only
// runJavaScript (top frame, after the page started), webview_flutter_android
// exposes no addDocumentStartJavaScript, and webview_flutter_wkwebview keeps
// its WKUserScript and WKUserContentController classes and its WKWebView
// private. So Flutter injects only the per-script copy, [guardArmScript],
// right before each Mealio script: it installs the guard and arms it there,
// and the in-page hooks carry it, armed, into same-origin frames (README,
// "Guard, top frame only"; PROTOCOL.md "Guard script"). Until Mealio's first
// script the store page runs untouched.
//
// It must stay plain ES5 with no dependencies, because it is injected as text
// into WebViews on four platforms. The text below is byte-for-byte the text
// packages/core/src/guard.ts produces; test/vectors_test.dart checks that
// against a fixture dumped from the TypeScript.

import 'dart:convert';

import 'allowlist.dart';

// `__MEALIO_BLOCK__`, `__MEALIO_OPS__` and `__MEALIO_PART__` are replaced with
// the JSON string literals of the three regex sources, the same as the reference's
// `${JSON.stringify(...)}` interpolations, and `__MEALIO_MAX_DEPTH__` and
// `__MEALIO_MAX_TEXT__` with [bodyMaxDepth] and [bodyMaxText].
const String _guardTemplate = r'''(function(){
  // Never in a cross-origin frame (a captcha, an identity provider): this is
  // the first thing it does, before it reads or installs anything.
  try { if (window.top && window.top !== window && !window.top.document) return; } catch (e) { return; }
  if (window.__mealioGuard) return;
  var BLOCK = new RegExp(__MEALIO_BLOCK__, 'i');
  var OPS = new RegExp(__MEALIO_OPS__, 'i');
  var PART = __MEALIO_PART__;
  var MAX_DEPTH = __MEALIO_MAX_DEPTH__, MAX_TEXT = __MEALIO_MAX_TEXT__;
  var root = window, stamps = [];
  function decoded(s) {
    for (var i = 0; i < 2; i++) s = s.replace(/%([0-9a-f]{2})/gi, function (x, h) { return String.fromCharCode(parseInt(h, 16)); });
    return s;
  }
  function mutationNames(doc) {
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
  }
  function bodyBlocked(b, depth) {
    if (typeof b !== 'string') return false;
    depth = depth || 0;
    if (b.charCodeAt(0) === 0xFEFF) b = b.slice(1);
    if (!b) return false;
    if (depth > MAX_DEPTH) return true;
    if (b.length > MAX_TEXT) return true;
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
        else if (m[1] === 'operations') { if (bodyBlocked(v, depth + 1)) return true; }
        else names.push(v);
      }
      var part = new RegExp(PART, 'g');
      while ((m = part.exec(b))) {
        if (m[1] === 'query') docs.push(m[2]);
        else if (m[1] === 'operations') { if (bodyBlocked(m[2], depth + 1)) return true; }
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
  // A same-origin frame of an armed window gets the guard, armed, the first
  // time it is reached. A cross-origin one throws on the first read and is
  // left alone: its requests carry its own origin, not the store's cookies.
  function intoFrame(w) {
    try {
      if (!w) return;
      if (!w.__mealioGuard) install(w);
      if (typeof w.__mealioArm === 'function') w.__mealioArm();
    } catch (e) {}
  }
  function fixed(w, name, value) {
    Object.defineProperty(w, name, { value: value, writable: false, configurable: false, enumerable: false });
  }
  // Every window the guard is in: the page and its same-origin frames. Each
  // has its own switch; every hook passes straight through while it is off.
  function install(w) {
    var armed = false;
    fixed(w, '__mealioGuard', true);
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
        if (!armed) return f.apply(this, arguments);
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
        if (!armed) return beacon.apply(nav, arguments);
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
        if (!armed) return send.apply(this, arguments);
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
        if (armed) {
          var scheme = '';
          try { scheme = new URL(String(url), loc.href).protocol; } catch (e) {}
          if (scheme === 'blob:' || scheme === 'data:') throw refuse('blocked_worker');
        }
        return arguments.length > 1 ? new W(url, opts) : new W(url);
      };
      G.prototype = W.prototype;
      // Worker.prototype.constructor must not hand back the original.
      try { Object.defineProperty(W.prototype, 'constructor', { value: G, writable: true, configurable: true, enumerable: false }); } catch (e) {}
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
          if (armed) intoFrame(prop === 'contentWindow' ? v : v && v.defaultView);
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
      el.addEventListener('load', function () { if (armed) intoFrame(el.contentWindow); });
    }
    // A node, a document, or a fragment or shadow root (which has no
    // getElementsByTagName), and every frame in it.
    function scan(n) {
      if (!armed || !n || (n.nodeType !== 1 && n.nodeType !== 9 && n.nodeType !== 11)) return;
      if (/^(IFRAME|FRAME|OBJECT)$/i.test(n.nodeName)) watch(n);
      var names = ['iframe', 'frame', 'object'], i, j, l;
      for (i = 0; i < names.length; i++) {
        l = n.getElementsByTagName ? n.getElementsByTagName(names[i]) : n.querySelectorAll ? n.querySelectorAll(names[i]) : [];
        for (j = 0; j < l.length; j++) watch(l[j]);
      }
    }
    // Every frame the window has, by index, ones a parser made included. (A
    // frame in a shadow tree is not among them: only its element, whose
    // getters are hooked, reaches its window.)
    function sweep() {
      if (!armed) return;
      var fr = w.frames, i, n = 0;
      try { n = fr.length; } catch (e) {}
      for (i = 0; i < n; i++) { try { intoFrame(fr[i]); } catch (e) {} }
    }
    // Every way a script adds nodes in one call: a frame added this way has a
    // window at once, before any MutationObserver runs. The nodes passed in are
    // searched after the call, and a fragment's children are noted before it
    // empties into the page.
    function after(P, names) {
      if (!P) return;
      for (var i = 0; i < names.length; i++) (function (name) {
        var o = P[name];
        if (typeof o !== 'function') return;
        P[name] = function () {
          if (!armed) return o.apply(this, arguments);
          var added = [], k, j, a;
          for (k = 0; k < arguments.length; k++) {
            a = arguments[k];
            if (!a || typeof a !== 'object') continue;
            if (a.nodeType === 11) for (j = 0; j < a.childNodes.length; j++) added.push(a.childNodes[j]);
            else added.push(a);
          }
          var r = o.apply(this, arguments);
          for (k = 0; k < added.length; k++) scan(added[k]);
          return r;
        };
      })(names[i]);
    }
    // Calls that parse HTML into the node they are called on: it is searched after.
    function parses(P, names, all) {
      if (!P) return;
      for (var i = 0; i < names.length; i++) (function (name) {
        var o = P[name];
        if (typeof o !== 'function') return;
        P[name] = function () {
          if (!armed) return o.apply(this, arguments);
          var r = o.apply(this, arguments);
          scan(this);
          if (all) sweep();
          return r;
        };
      })(names[i]);
    }
    var N = w.Node, El = w.Element, CD = w.CharacterData, DT = w.DocumentType, D = w.Document, DF = w.DocumentFragment;
    var SR = w.ShadowRoot, R = w.Range;
    var kids = ['append', 'prepend', 'replaceChildren'], sibs = ['before', 'after', 'replaceWith'];
    after(N && N.prototype, ['appendChild', 'insertBefore', 'replaceChild']);
    after(El && El.prototype, kids.concat(sibs, ['insertAdjacentElement']));
    after(CD && CD.prototype, sibs);
    after(DT && DT.prototype, sibs);
    after(D && D.prototype, kids);
    after(DF && DF.prototype, kids);
    after(R && R.prototype, ['insertNode', 'surroundContents']);
    parses(El && El.prototype, ['setHTMLUnsafe']);
    parses(SR && SR.prototype, ['setHTMLUnsafe']);
    // document.write makes frames where the parser is, and execCommand where the caret is.
    parses(D && D.prototype, ['write', 'writeln', 'execCommand'], true);
    // HTML text makes frames at once as well: the element, or its parent for
    // the text that lands beside it, is searched after.
    var adj = El && El.prototype.insertAdjacentHTML;
    if (typeof adj === 'function') {
      El.prototype.insertAdjacentHTML = function (where) {
        if (!armed) return adj.apply(this, arguments);
        var up = this.parentNode, r = adj.apply(this, arguments);
        scan(/^(beforebegin|afterend)$/i.test(String(where)) ? up : this);
        return r;
      };
    }
    // innerHTML and outerHTML make frames synchronously as well.
    function setter(P, prop) {
      var d = P && Object.getOwnPropertyDescriptor(P, prop);
      if (!d || !d.set || !d.configurable) return;
      Object.defineProperty(P, prop, {
        configurable: true, enumerable: d.enumerable, get: d.get,
        set: function (v) {
          if (!armed) return d.set.call(this, v);
          var up = this.parentNode; d.set.call(this, v); scan(prop === 'outerHTML' ? up : this);
        },
      });
    }
    setter(El && El.prototype, 'innerHTML');
    setter(El && El.prototype, 'outerHTML');
    setter(SR && SR.prototype, 'innerHTML');
    var MO = w.MutationObserver, doc = w.document;
    if (MO && doc) {
      new MO(function (records) {
        if (!armed) return;
        for (var i = 0; i < records.length; i++) for (var j = 0; j < records[i].addedNodes.length; j++) scan(records[i].addedNodes[j]);
      }).observe(doc, { childList: true, subtree: true });
    }
    // On for good, until the page navigates. It arms every same-origin frame
    // the window has now; frames added later are armed as they are added.
    fixed(w, '__mealioArm', function () {
      if (armed) return;
      armed = true;
      if (doc) scan(doc);
      sweep();
    });
    fixed(w, '__mealioArmed', function () { return armed; });
  }
  install(window);
  // A frame that loads into an armed page starts armed.
  try { if (window.parent !== window && window.parent.__mealioArmed()) window.__mealioArm(); } catch (e) {}
})(); true;''';

/// Injected before every server script, in the hidden page and the login sheet.
final String guardScript = _guardTemplate
    .replaceFirst('__MEALIO_BLOCK__', jsonEncode(blockedPatterns.join('|')))
    .replaceFirst('__MEALIO_OPS__', jsonEncode(blockedGraphqlOperation))
    .replaceFirst('__MEALIO_PART__', jsonEncode(multipartField))
    .replaceFirst('__MEALIO_MAX_DEPTH__', '$bodyMaxDepth')
    .replaceFirst('__MEALIO_MAX_TEXT__', '$bodyMaxText');

/// Arms the guard [guardScript] installed in this window. GUARD_ARM in guard.ts.
const String guardArm = 'window.__mealioArm(); true;';

/// The per-script copy: injected into the top frame right before every Mealio
/// server script (a page_script's script, a show_login check script). It
/// installs the guard if it is missing, then arms it. Flutter has no
/// document-start injection, so this is the only copy that arms: the guard
/// stays off until Mealio's first script in the page (PROTOCOL.md "Guard
/// script"). GUARD_ARM_SCRIPT in guard.ts.
final String guardArmScript = '$guardScript\n$guardArm';

/// Native SDKs (iOS, Android, Flutter) inject this so the store scripts can
/// post with the same call React Native's WebView provides.
/// `__mealioNativePost` is the platform's own bridge; in Flutter it forwards
/// to the `__mealioNativeBridge` JavaScriptChannel.
const String bridgeShim = r'''(function(){
  if (window.ReactNativeWebView) return;
  window.ReactNativeWebView = { postMessage: function (s) { try { window.__mealioNativePost(String(s)); } catch (e) {} } };
})(); true;''';
