(function(){
  // Never in a cross-origin frame (a captcha, an identity provider): this is
  // the first thing it does, before it reads or installs anything.
  try { if (window.top && window.top !== window && !window.top.document) return; } catch (e) { return; }
  if (window.__mealioGuard) return;
  // The built-ins the guard decides with, captured now. Each is called through
  // a bound copy, so page code that later replaces a prototype method (or
  // Function.prototype.call and apply themselves) does not reach the guard.
  var FP = Function.prototype, bindFn = FP.bind, callFn = FP.call;
  function un(f) { return typeof f === 'function' ? bindFn.call(callFn, f) : null; }
  var apply = un(FP.apply), gopd = Object.getOwnPropertyDescriptor, defProp = Object.defineProperty, ocreate = Object.create;
  function proto(C) { return C && (typeof C === 'function' || typeof C === 'object') ? C.prototype : null; }
  function getter(C, k) { var P = proto(C), d = P && gopd(P, k); return d && d.get ? un(d.get) : null; }
  function method(C, k) { var P = proto(C); return P ? un(P[k]) : null; }
  var Str = String, parse = JSON.parse, isArray = Array.isArray, now = Date.now, enc = encodeURIComponent;
  var fromCC = String.fromCharCode, pInt = parseInt, Pr = Promise;
  var rxExec = method(RegExp, 'exec'), sIndex = method(String, 'indexOf'), sSlice = method(String, 'slice'), sCode = method(String, 'charCodeAt');
  var then = method(Promise, 'then');
  var URLc = typeof window.URL === 'function' ? window.URL : null, urlPath = getter(URLc, 'pathname'), urlSearch = getter(URLc, 'search'), urlProto = getter(URLc, 'protocol');
  var BlobC = typeof window.Blob === 'function' ? window.Blob : null, blobText = method(BlobC, 'text'), blobSize = getter(BlobC, 'size');
  var abView = window.ArrayBuffer && window.ArrayBuffer.isView, abLen = getter(window.ArrayBuffer, 'byteLength');
  var uspString = method(window.URLSearchParams, 'toString');
  var FD = typeof window.FormData === 'function' ? window.FormData : null, fdGet = method(FD, 'get');
  var reqUrl = getter(window.Request, 'url'), reqMethod = getter(window.Request, 'method'), reqClone = method(window.Request, 'clone'), reqText = method(window.Request, 'text');
  var rsLocked = getter(window.ReadableStream, 'locked');
  var docUrl = getter(window.Document, 'URL'), XS = typeof window.XMLSerializer === 'function' ? window.XMLSerializer : null, xsString = method(XS, 'serializeToString');
  var formAction = getter(window.HTMLFormElement, 'action'), formMethod = getter(window.HTMLFormElement, 'method'), formElements = getter(window.HTMLFormElement, 'elements');
  var getAttr = method(window.Element, 'getAttribute'), shadowOf = getter(window.Element, 'shadowRoot');
  var evTarget = getter(window.Event, 'target'), evSubmitter = getter(window.SubmitEvent, 'submitter'), evPrevented = getter(window.Event, 'defaultPrevented');
  var evPrevent = method(window.Event, 'preventDefault');
  var addEL = method(window.EventTarget, 'addEventListener'), gpo = Object.getPrototypeOf;
  var construct = typeof Reflect === 'object' && Reflect && typeof Reflect.construct === 'function' ? Reflect.construct : null;
  var BLOCK = new RegExp("checkout|payment|billing|wallet|place[-_]?order|submit[-_]?order|order[-_]?confirm|gift-?card|/account/(delete|close|security|password)|/addresses?/(add|edit|delete|new)|/orders?/(submit|place)(/|\\?|$)|/cart/confirm|/purchase(/|\\?|$)", 'i');
  var OPS = new RegExp("check_?out|place_?order|submit_?order|confirm_?order|create_?order|purchase|payment", 'i');
  var MAX_DEPTH = 8, MAX_TEXT = 1048576;
  var root = window, stamps = [], head = 0;
  function has(re, s) { re.lastIndex = 0; return rxExec(re, s) !== null; }
  function isPromise(v) { return !!v && typeof v === 'object'; }
  function rejected(e) { return new Pr(function (ok, no) { no(e); }); }
  // Calls go(text) once a body's text is known. Text that cannot be read goes through: fetch itself will fail on it.
  function settled(text, go) {
    if (!isPromise(text)) return go(text);
    var bad = function () { return go(null); };
    if (then) { try { return then(text, go, bad); } catch (e) {} }
    return text.then(go, bad);
  }
  function decodeOnce(s) {
    var re = /%([0-9a-f]{2})/gi, out = '', last = 0, m;
    while ((m = rxExec(re, s))) { out += sSlice(s, last, m.index) + fromCC(pInt(m[1], 16)); last = re.lastIndex; }
    return out + sSlice(s, last);
  }
  function decoded(s) { return decodeOnce(decodeOnce(s)); }
  function plus(s) {
    var out = '', last = 0, i;
    while ((i = sIndex(s, '+', last)) >= 0) { out += sSlice(s, last, i) + ' '; last = i + 1; }
    return out + sSlice(s, last);
  }
  function mutationNames(doc) {
    var strip = /"""(?:\\"""|[\s\S])*?"""|"(?:[^"\\]|\\.)*"|#[^\n\r]*/g, tok = /[A-Za-z_][A-Za-z0-9_]*|\.\.\.|[{}():@]/g;
    var text = '', last = 0, tokens = [], m;
    while ((m = rxExec(strip, doc))) { text += sSlice(doc, last, m.index) + ' '; last = strip.lastIndex; }
    text += sSlice(doc, last);
    while ((m = rxExec(tok, text))) tokens[tokens.length] = m[0];
    var defs = [], def = null, sets = [], parens = 0, inline = false, expect = '', pushed = false, was, root, i, t;
    for (i = 0; i < tokens.length; i++) {
      t = tokens[i]; was = pushed; pushed = false;
      if (t === '(') { parens++; continue; }
      if (t === ')') { parens = parens > 0 ? parens - 1 : 0; continue; }
      if (parens > 0) continue;
      if (t === '@') { expect = 'directive'; continue; }
      if (t === '{') {
        if (!def) { def = { kind: 'query', name: '', fields: [], spreads: [] }; defs[defs.length] = def; }
        sets[sets.length] = sets.length === 0 || (inline && sets[sets.length - 1]);
        inline = false; expect = '';
        continue;
      }
      if (t === '}') {
        if (sets.length) sets.length = sets.length - 1;
        inline = false; expect = '';
        if (sets.length === 0) def = null;
        continue;
      }
      if (sets.length === 0) {
        if (expect === 'directive') expect = '';
        else if (!def && has(/^(query|mutation|subscription|fragment)$/, t)) { def = { kind: t, name: '', fields: [], spreads: [] }; defs[defs.length] = def; }
        else if (def && !def.name && t !== 'on' && t !== ':' && t !== '...') def.name = t;
        continue;
      }
      root = sets[sets.length - 1];
      if (t === '...') { expect = 'spread'; inline = true; continue; }
      if (t === ':') { if (was && def && def.fields.length) def.fields.length = def.fields.length - 1; continue; }
      if (expect === 'directive' || expect === 'type') { expect = ''; continue; }
      if (expect === 'spread') {
        expect = '';
        if (t === 'on') { expect = 'type'; continue; }
        inline = false;
        if (root && def) def.spreads[def.spreads.length] = t;
        continue;
      }
      inline = false;
      if (root && def) { def.fields[def.fields.length] = t; pushed = true; }
    }
    var fragments = ocreate(null), names = [], seen, j;
    for (i = 0; i < defs.length; i++) if (defs[i].kind === 'fragment') fragments['f_' + defs[i].name] = defs[i];
    function walk(x) {
      for (var k = 0; k < x.fields.length; k++) names[names.length] = x.fields[k];
      for (k = 0; k < x.spreads.length; k++) {
        var f = fragments['f_' + x.spreads[k]];
        if (f && !seen['f_' + x.spreads[k]]) { seen['f_' + x.spreads[k]] = true; walk(f); }
      }
    }
    for (j = 0; j < defs.length; j++) {
      if (defs[j].kind !== 'mutation') continue;
      if (defs[j].name) names[names.length] = defs[j].name;
      seen = ocreate(null);
      walk(defs[j]);
    }
    return names;
  }
  function isJsSpace(c) {
    return c === 0x20 || (c >= 0x09 && c <= 0x0d) || c === 0xa0 || c === 0x1680 || (c >= 0x2000 && c <= 0x200a) ||
      c === 0x2028 || c === 0x2029 || c === 0x202f || c === 0x205f || c === 0x3000 || c === 0xfeff;
  }
  function multipartFields(body) {
    var out = [], n = body.length, brkFrom = -1, brkAt = -1, runFrom = -1, runTo = -1, runValue = -1, from = 0;
    var NAMES = ['operationName', 'query', 'operations'];
    var c, k, x, name, j, ch, q, p, v, s, h, e, end, i;
    for (;;) {
      c = sIndex(body, 'name=', from);
      if (c < 0) break;
      from = c + 1;
      k = c + 5;
      ch = sCode(body, k);
      if (ch === 0x22 || ch === 0x27) k++;
      name = '';
      for (i = 0; i < NAMES.length; i++) { x = NAMES[i]; if (sSlice(body, k, k + x.length) === x) { name = x; break; } }
      if (!name) continue;
      j = k + name.length;
      if (j < n) { ch = sCode(body, j); if (ch !== 0x22 && ch !== 0x27 && ch !== 0x3b && !isJsSpace(ch)) continue; }
      if (j >= brkFrom && j <= brkAt) q = brkAt;
      else {
        q = j;
        while (q < n && sCode(body, q) !== 0x0d && sCode(body, q) !== 0x0a) q++;
        brkFrom = j; brkAt = q;
      }
      if (q < n && sCode(body, q) === 0x0a) p = q + 1;
      else if (q + 1 < n && sCode(body, q) === 0x0d && sCode(body, q + 1) === 0x0a) p = q + 2;
      else continue;
      if (p >= runFrom && p <= runTo) v = runValue;
      else {
        s = p; v = -1;
        for (;;) {
          if (s >= n) break;
          h = sCode(body, s);
          if (h === 0x0a) { v = s + 1; break; }
          if (h === 0x0d) { if (s + 1 < n && sCode(body, s + 1) === 0x0a) v = s + 2; break; }
          e = s;
          while (e < n && sCode(body, e) !== 0x0d && sCode(body, e) !== 0x0a) e++;
          if (e < n && sCode(body, e) === 0x0a) s = e + 1;
          else if (e + 1 < n && sCode(body, e) === 0x0d && sCode(body, e + 1) === 0x0a) s = e + 2;
          else break;
        }
        runFrom = p; runTo = s; runValue = v;
      }
      if (v < 0) continue;
      end = sIndex(body, '\n--', v);
      if (end < 0) end = n;
      else if (end > v && sCode(body, end - 1) === 0x0d) end--;
      out[out.length] = [name, sSlice(body, v, end)];
      from = end;
    }
    return out;
  }
  function bodyBlocked(b, depth) {
    if (typeof b !== 'string') return false;
    depth = depth || 0;
    if (sCode(b, 0) === 0xFEFF) b = sSlice(b, 1);
    if (!b) return false;
    if (depth > MAX_DEPTH) return true;
    if (b.length > MAX_TEXT) return true;
    var names = [], docs = [], re = /"operationName"\s*:\s*"([^"]*)"/g, m, i, k;
    while ((m = rxExec(re, b))) names[names.length] = m[1];
    try {
      var j = parse(b);
      var list = isArray(j) ? j : [j];
      for (i = 0; i < list.length; i++) {
        var o = list[i];
        if (!o || typeof o !== 'object') continue;
        if (typeof o.operationName === 'string') names[names.length] = o.operationName;
        if (typeof o.query === 'string') docs[docs.length] = o.query;
      }
    } catch (e) {
      docs[docs.length] = b;
      var form = /(?:^|&)(operationName|query|operations)=([^&]*)/g;
      while ((m = rxExec(form, b))) {
        var v = decoded(plus(m[2]));
        if (m[1] === 'query') docs[docs.length] = v;
        else if (m[1] === 'operations') { if (bodyBlocked(v, depth + 1)) return true; }
        else names[names.length] = v;
      }
      var parts = multipartFields(b);
      for (i = 0; i < parts.length; i++) {
        if (parts[i][0] === 'query') docs[docs.length] = parts[i][1];
        else if (parts[i][0] === 'operations') { if (bodyBlocked(parts[i][1], depth + 1)) return true; }
        else names[names.length] = parts[i][1];
      }
    }
    for (i = 0; i < docs.length; i++) { var more = mutationNames(docs[i]); for (k = 0; k < more.length; k++) names[names.length] = more[k]; }
    for (i = 0; i < names.length; i++) if (has(OPS, names[i])) return true;
    return false;
  }
  function overRate() {
    var t = now(), i, keep;
    while (head < stamps.length && t - stamps[head] > 60000) head++;
    if (head > 512) { keep = []; for (i = head; i < stamps.length; i++) keep[keep.length] = stamps[i]; stamps = keep; head = 0; }
    if (stamps.length - head >= 240) return true;
    stamps[stamps.length] = t;
    return false;
  }
  function refuse(why) {
    try { root.ReactNativeWebView && root.ReactNativeWebView.postMessage(JSON.stringify({ type: 'MEALIO_GUARD_BLOCKED', why: why })); } catch (e) {}
    return new Error('mealio guard: ' + why);
  }
  function brand(g, v) { if (!g) return false; try { g(v); return true; } catch (e) { return false; } }
  function fromForm(f) {
    var q = '', keys = ['operationName', 'query', 'operations'], i, k;
    for (i = 0; i < keys.length; i++) { k = fdGet(f, keys[i]); if (typeof k === 'string') q += (q ? '&' : '') + keys[i] + '=' + enc(k); }
    return q;
  }
  // A body as { text, pass }: text is a string, null (cannot be read) or a
  // promise for the string; pass is what goes on to the platform. Anything
  // that is not a string, URLSearchParams, FormData, Blob, buffer, stream or
  // document is turned into its text once, here, and that text is both what is
  // judged and what is sent, so an object cannot show one text and send another.
  function bodyOf(b) {
    if (b === null || b === undefined || typeof b === 'string') return { text: b, pass: b };
    if (typeof b !== 'object' && typeof b !== 'function') { var p = Str(b); return { text: p, pass: p }; }
    if (uspString) { try { return { text: uspString(b), pass: b }; } catch (e) {} }
    if (fdGet) { try { fdGet(b, ''); return { text: fromForm(b), pass: b }; } catch (e) {} }
    if (brand(blobSize, b)) return { text: blobText(b), pass: b };
    if (BlobC && ((abView && abView(b)) || brand(abLen, b))) {
      // Read and sent as one copy, so the bytes cannot change after they are read.
      var copy = new BlobC([b]);
      return { text: blobText(copy), pass: copy };
    }
    if (brand(rsLocked, b)) return { text: null, pass: b };
    if (brand(docUrl, b)) { var x = null; try { x = xsString(new XS(), b); } catch (e) {} return { text: x, pass: b }; }
    var s = Str(b);
    return { text: s, pass: s };
  }
  // The fetch options, read once into a fresh object: a getter cannot hand the
  // guard one body and fetch another.
  var INIT_KEYS = ['method', 'headers', 'body', 'mode', 'credentials', 'cache', 'redirect', 'referrer', 'referrerPolicy', 'integrity',
    'keepalive', 'signal', 'priority', 'duplex', 'window', 'attributionReporting', 'browsingTopics', 'privateToken', 'adAuctionHeaders'];
  function snapshot(init) {
    if (!init || (typeof init !== 'object' && typeof init !== 'function')) return init;
    var o = ocreate(null), k, i, v;
    for (k in init) { v = init[k]; if (v !== undefined) o[k] = v; }
    for (i = 0; i < INIT_KEYS.length; i++) { k = INIT_KEYS[i]; if (!(k in o)) { v = init[k]; if (v !== undefined) o[k] = v; } }
    return o;
  }
  function copyArgs(a) { var out = [], i; for (i = 0; i < a.length; i++) out[i] = a[i]; return out; }
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
    defProp(w, name, { value: value, writable: false, configurable: false, enumerable: false });
  }
  // Every window the guard is in: the page and its same-origin frames. Each
  // has its own switch; every hook passes straight through while it is off.
  function install(w) {
    var armed = false;
    fixed(w, '__mealioGuard', true);
    var loc = w.location;
    function pathOf(u) {
      var s = Str(u === undefined || u === null ? '' : u);
      if (!URLc || !urlPath) return s;
      try { var a = new URLc(s, loc.href); return urlPath(a) + urlSearch(a); } catch (e) { return s; }
    }
    function pathBlocked(u) {
      var p = pathOf(u);
      return has(BLOCK, p) || has(BLOCK, decoded(p));
    }
    // What a Request sends, when it has a body to read.
    function requestText(r) {
      if (reqUrl) {
        try {
          if (has(/^(GET|HEAD)$/i, reqMethod(r))) return null;
          return reqText(reqClone(r));
        } catch (e) { return null; } // A body already read, or a stream that cannot be cloned, cannot be judged: it goes through.
      }
      if (typeof r.body === 'string') return r.body;
      if (typeof r.clone !== 'function' || has(/^(GET|HEAD)$/i, r.method || 'GET')) return null;
      try { return r.clone().text(); } catch (e) { return null; }
    }
    var f = w.fetch;
    if (f) {
      w.fetch = function (input, init) {
        if (!armed || arguments.length === 0) return apply(f, this, arguments);
        var self = this, url, req = false, body = null, opts, args;
        if (input && (typeof input === 'object' || typeof input === 'function')) {
          if (reqUrl) { try { url = reqUrl(input); req = true; } catch (e) {} }
          else if (typeof input.url === 'string') { url = input.url; req = true; }
        }
        // Anything else is a URL as text, read once: what is checked is what is fetched.
        if (!req) { input = Str(input); url = input; }
        if (pathBlocked(url)) return rejected(refuse('blocked_path'));
        opts = snapshot(init);
        if (opts && typeof opts === 'object' && opts.body !== undefined && opts.body !== null) {
          var b = bodyOf(opts.body); opts.body = b.pass; body = b.text;
        } else if (req) body = requestText(input);
        args = arguments.length > 1 ? [input, opts] : [input];
        return settled(body, function (text) {
          if (bodyBlocked(text)) return rejected(refuse('blocked_operation'));
          if (overRate()) return rejected(refuse('rate'));
          return apply(f, self, args);
        });
      };
    }
    var nav = w.navigator, beacon = nav && nav.sendBeacon;
    if (beacon) {
      // A beacon cannot wait for a Blob to be read, so only text bodies are allowed.
      nav.sendBeacon = function (url, data) {
        if (!armed || arguments.length === 0) return apply(beacon, nav, arguments);
        url = Str(url);
        if (pathBlocked(url)) { refuse('blocked_path'); return false; }
        var b = data === null || data === undefined ? { text: '', pass: data } : bodyOf(data);
        if (isPromise(b.text)) { refuse('blocked_operation'); return false; }
        if (bodyBlocked(b.text)) { refuse('blocked_operation'); return false; }
        return apply(beacon, nav, arguments.length > 1 ? [url, b.pass] : [url]);
      };
    }
    var X = w.XMLHttpRequest;
    if (X && X.prototype) {
      var open = X.prototype.open, send = X.prototype.send;
      // Each request's URL, where page code cannot rewrite it.
      var urls = typeof WeakMap === 'function' ? new WeakMap() : null;
      var wmGet = urls && un(WeakMap.prototype.get), wmSet = urls && un(WeakMap.prototype.set);
      X.prototype.open = function (m, u) {
        var a = arguments;
        if (armed && a.length > 1) { a = copyArgs(a); a[1] = Str(u); }
        // [url, synchronous]: open's third argument, when given, false (or undefined) means synchronous.
        if (a.length > 1) { var rec = [a[1], a.length > 2 && !a[2]]; try { if (wmSet) wmSet(urls, this, rec); else this.__mealioUrl = rec; } catch (e) {} }
        return apply(open, this, a);
      };
      X.prototype.send = function (body) {
        if (!armed) return apply(send, this, arguments);
        var self = this, rec = null, u = null, sync = false;
        try { rec = wmGet ? wmGet(urls, this) : this.__mealioUrl; } catch (e) {}
        if (rec) { u = rec[0]; sync = rec[1]; }
        if (pathBlocked(u)) throw refuse('blocked_path');
        var b = bodyOf(body), args = arguments.length ? [b.pass] : [];
        function go(text) {
          if (bodyBlocked(text)) throw refuse('blocked_operation');
          if (overRate()) throw refuse('rate');
          return apply(send, self, args);
        }
        if (!isPromise(b.text)) return go(b.text);
        // A synchronous request must be sent now, and a Blob cannot be read
        // now: its path was judged above, its body is not (PROTOCOL.md "Known limits").
        if (sync) return go(null);
        // send() cannot wait, so a Blob is read first and sent after. A refused one never goes.
        var abort = function () { try { self.abort(); } catch (e) {} };
        var sent = settled(b.text, go);
        if (then) { try { then(sent, null, abort); return; } catch (e) {} }
        sent.then(null, abort);
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
          url = Str(url);
          try { scheme = URLc && urlProto ? urlProto(new URLc(url, loc.href)) : ''; } catch (e) {}
          if (scheme === 'blob:' || scheme === 'data:') throw refuse('blocked_worker');
        }
        var args = arguments.length > 1 ? [url, opts] : [url], p = null;
        // A subclass (class W2 extends Worker) constructs through here with
        // its own prototype on this: keep it, as new.target would.
        try { if (this instanceof G) p = gpo(this); } catch (e) {}
        if (construct && p && p !== G.prototype) { var NT = function () {}; NT.prototype = p; return construct(W, args, NT); }
        return arguments.length > 1 ? new W(url, opts) : new W(url);
      };
      G.prototype = W.prototype;
      // Worker.prototype.constructor must not hand back the original.
      try { defProp(W.prototype, 'constructor', { value: G, writable: true, configurable: true, enumerable: false }); } catch (e) {}
      w[name] = G;
    }
    guardWorker('Worker');
    guardWorker('SharedWorker');
    // Form submissions: an explicit target (the submitter's formaction, or
    // else the form's action attribute) is checked as a path, and the form's
    // fields as a form-encoded body. A form with neither posts back to the
    // page it is on, which the SDK already allowed: only its fields are
    // judged, never the page URL or its query (a sign-in page at
    // /login?returnUrl=/checkout is not a checkout). The fields are read from
    // the form's controls, not with new FormData: that would fire the page's
    // formdata listeners a second time.
    function fieldsOf(form, submitter) {
      var els = null, q = '', n = 0, i, el, name, type, v;
      try { els = formElements ? formElements(form) : form.elements; n = els.length; } catch (e) { return null; }
      for (i = 0; i < n; i++) {
        try {
          el = els[i]; name = el.name;
          if (name !== 'operationName' && name !== 'query' && name !== 'operations') continue;
          if (el.disabled) continue;
          type = Str(el.type || '');
          if (has(/^(checkbox|radio)$/i, type) && !el.checked) continue;
          if (has(/^(submit|image|button|reset)$/i, type) && el !== submitter) continue;
          if (has(/^file$/i, type)) continue;
          v = el.value;
          if (typeof v === 'string') q += (q ? '&' : '') + name + '=' + enc(v);
        } catch (e) {}
      }
      return q;
    }
    function isDialog(form, submitter) {
      var m = null;
      if (submitter && getAttr) { try { m = getAttr(submitter, 'formmethod'); } catch (e) {} }
      if (m === null || m === undefined) { try { m = formMethod ? formMethod(form) : form.method; } catch (e) {} }
      return typeof m === 'string' && has(/^dialog$/i, m);
    }
    // An attribute that is there and not blank names where the form goes.
    function attrOf(el, name) {
      var v = null;
      if (!el || !getAttr) return null;
      try { v = getAttr(el, name); } catch (e) { return null; }
      return typeof v === 'string' && has(/\S/, v) ? v : null;
    }
    function formCheck(form, submitter) {
      var action = null;
      if (isDialog(form, submitter)) return;
      action = attrOf(submitter, 'formaction');
      if (action === null && attrOf(form, 'action') !== null) {
        try { action = formAction ? formAction(form) : form.action; } catch (e) { action = null; }
      }
      if (action !== null && pathBlocked(action)) throw refuse('blocked_path');
      if (bodyBlocked(fieldsOf(form, submitter))) throw refuse('blocked_operation');
    }
    // form.submit() fires no event, so it is judged here. requestSubmit() is
    // judged here as well, before its event, by the same rules: each throws
    // only for a blocked explicit target or blocked fields. Buttons and the
    // Enter key fire a submit event, judged below.
    var FE = w.HTMLFormElement;
    if (FE && FE.prototype) {
      var fsubmit = FE.prototype.submit, frequest = FE.prototype.requestSubmit;
      if (typeof fsubmit === 'function') FE.prototype.submit = function () { if (armed) formCheck(this, null); return apply(fsubmit, this, arguments); };
      if (typeof frequest === 'function') FE.prototype.requestSubmit = function (by) {
        // A submitter that is not this form's is refused by requestSubmit itself.
        if (armed) { var sb = null; try { if (by && by.form === this) sb = by; } catch (e) {} formCheck(this, sb); }
        return apply(frequest, this, arguments);
      };
    }
    // A submit event is judged in the CAPTURE phase, before any handler of the
    // page's can stop it: on the window, which comes first on every path, and
    // on each shadow root (submit does not cross one), on attachShadow and at
    // arming for open roots already there. A blocked form is refused with
    // preventDefault ONLY, never stopPropagation: the page's own handlers
    // always run, and a request one of them sends itself (a JS sign-in's
    // fetch) is judged on its own by the fetch hook.
    function onSubmit(e) {
      if (!armed) return;
      var form = null, by = null, prevented = false;
      // Already refused (by the window's listener, on a form a shadow root's
      // listener sees again), or already not going anywhere.
      try { prevented = evPrevented ? evPrevented(e) : e.defaultPrevented; } catch (x) {}
      if (prevented) return;
      try { form = evTarget ? evTarget(e) : e.target; } catch (x) {}
      try { by = evSubmitter ? evSubmitter(e) : e.submitter; } catch (x) {}
      try { formCheck(form, by); } catch (x) {
        try { if (evPrevent) evPrevent(e); else e.preventDefault(); } catch (y) {}
      }
    }
    function listen(t) { try { if (addEL) addEL(t, 'submit', onSubmit, true); else t.addEventListener('submit', onSubmit, true); } catch (e) {} }
    if (typeof w.addEventListener === 'function') listen(w);
    var EP = w.Element && w.Element.prototype, attach = EP && EP.attachShadow;
    if (typeof attach === 'function') {
      EP.attachShadow = function () {
        var r = apply(attach, this, arguments);
        if (r) listen(r);
        return r;
      };
    }
    // Frames: through the element's contentWindow and contentDocument, when
    // one is added to the page, and again after each load.
    var tags = ['HTMLIFrameElement', 'HTMLFrameElement', 'HTMLObjectElement'], t;
    function hook(E, prop) {
      var d = gopd(E.prototype, prop);
      if (!d || !d.get || !d.configurable) return;
      var get = un(d.get);
      defProp(E.prototype, prop, {
        configurable: true, enumerable: d.enumerable,
        get: function () {
          var v = get(this);
          if (armed) intoFrame(prop === 'contentWindow' ? v : v && v.defaultView);
          return v;
        },
      });
    }
    for (t = 0; t < tags.length; t++) {
      var E = w[tags[t]];
      if (typeof E === 'function' && E.prototype) { hook(E, 'contentWindow'); hook(E, 'contentDocument'); }
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
      if (has(/^(IFRAME|FRAME|OBJECT)$/i, n.nodeName)) watch(n);
      var names = ['iframe', 'frame', 'object'], i, j, l;
      for (i = 0; i < names.length; i++) {
        l = n.getElementsByTagName ? n.getElementsByTagName(names[i]) : n.querySelectorAll ? n.querySelectorAll(names[i]) : [];
        for (j = 0; j < l.length; j++) watch(l[j]);
      }
    }
    // Frames inside open shadow roots, at any depth. A closed shadow root
    // cannot be read; only its frame elements' hooked getters reach those.
    function shadows(top) {
      if (!shadowOf) return;
      var stack = [top], n, all, i, sr;
      while (stack.length) {
        n = stack[stack.length - 1]; stack.length = stack.length - 1;
        all = n.querySelectorAll ? n.querySelectorAll('*') : [];
        for (i = 0; i < all.length; i++) {
          sr = null;
          try { sr = shadowOf(all[i]); } catch (e) {}
          if (sr) { listen(sr); scan(sr); stack[stack.length] = sr; }
        }
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
          if (!armed) return apply(o, this, arguments);
          var added = [], k, j, a;
          for (k = 0; k < arguments.length; k++) {
            a = arguments[k];
            if (!a || typeof a !== 'object') continue;
            if (a.nodeType === 11) for (j = 0; j < a.childNodes.length; j++) added[added.length] = a.childNodes[j];
            else added[added.length] = a;
          }
          var r = apply(o, this, arguments);
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
          if (!armed) return apply(o, this, arguments);
          var r = apply(o, this, arguments);
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
        if (!armed) return apply(adj, this, arguments);
        var up = this.parentNode, r = apply(adj, this, arguments);
        scan(has(/^(beforebegin|afterend)$/i, Str(where)) ? up : this);
        return r;
      };
    }
    // innerHTML and outerHTML make frames synchronously as well.
    function setter(P, prop) {
      var d = P && gopd(P, prop);
      if (!d || !d.set || !d.configurable) return;
      var set = un(d.set);
      defProp(P, prop, {
        configurable: true, enumerable: d.enumerable, get: d.get,
        set: function (v) {
          if (!armed) return set(this, v);
          var up = this.parentNode; set(this, v); scan(prop === 'outerHTML' ? up : this);
        },
      });
    }
    setter(El && El.prototype, 'innerHTML');
    setter(El && El.prototype, 'outerHTML');
    setter(SR && SR.prototype, 'innerHTML');
    // A same-origin window this one opens gets the guard, armed, at once.
    var wopen = w.open;
    if (typeof wopen === 'function') {
      w.open = function () {
        var r = apply(wopen, this, arguments);
        if (armed) intoFrame(r);
        return r;
      };
    }
    var MO = w.MutationObserver, doc = w.document;
    if (MO && doc) {
      new MO(function (records) {
        if (!armed) return;
        for (var i = 0; i < records.length; i++) for (var j = 0; j < records[i].addedNodes.length; j++) scan(records[i].addedNodes[j]);
      }).observe(doc, { childList: true, subtree: true });
    }
    // On for good, until the page navigates. It arms every same-origin frame
    // the window has now, those in open shadow roots included; frames added
    // later are armed as they are added.
    fixed(w, '__mealioArm', function () {
      if (armed) return;
      armed = true;
      if (doc) { scan(doc); shadows(doc); }
      sweep();
    });
    fixed(w, '__mealioArmed', function () { return armed; });
  }
  install(window);
  // A frame that loads into an armed page starts armed, and so does a popup
  // whose opener is armed and same-origin.
  try { if (window.parent !== window && window.parent.__mealioArmed()) window.__mealioArm(); } catch (e) {}
  try { var op = window.opener; if (op && op !== window && op.document && op.__mealioArmed()) window.__mealioArm(); } catch (e) {}
})(); true;