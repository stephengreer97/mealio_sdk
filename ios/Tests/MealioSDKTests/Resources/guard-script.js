(function(){
  if (window.__mealioGuard) return;
  window.__mealioGuard = true;
  var BLOCK = new RegExp("checkout|payment|billing|wallet|place-?order|submit-?order|order-?confirm|gift-?card|/account/(delete|close|security|password)|/addresses?/(add|edit|delete|new)", 'i');
  var OPS = new RegExp("checkout|placeorder|submitorder|payment", 'i');
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
  function bodyBlocked(b) {
    if (typeof b !== 'string') return false;
    var names = [], re = /"operationName"\s*:\s*"([^"]*)"/g, m, i;
    while ((m = re.exec(b))) names.push(m[1]);
    try {
      var j = JSON.parse(b);
      var list = Object.prototype.toString.call(j) === '[object Array]' ? j : [j];
      for (i = 0; i < list.length; i++) {
        var o = list[i];
        if (!o || typeof o !== 'object') continue;
        if (typeof o.operationName === 'string') names.push(o.operationName);
        if (typeof o.query === 'string') {
          var q = /\bmutation\s+([A-Za-z_][A-Za-z0-9_]*)/g, k;
          while ((k = q.exec(o.query))) names.push(k[1]);
        }
      }
    } catch (e) {}
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
    try { window.ReactNativeWebView && window.ReactNativeWebView.postMessage(JSON.stringify({ type: 'MEALIO_GUARD_BLOCKED', why: why })); } catch (e) {}
    return new Error('mealio guard: ' + why);
  }
  var f = window.fetch;
  if (f) {
    window.fetch = function (input, init) {
      var url = (input && typeof input === 'object' && input.url) ? input.url : input;
      var body = init && init.body;
      if (pathBlocked(url)) return Promise.reject(refuse('blocked_path'));
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
      if (pathBlocked(this.__mealioUrl)) throw refuse('blocked_path');
      if (bodyBlocked(b)) throw refuse('blocked_operation');
      if (overRate()) throw refuse('rate');
      return send.apply(this, arguments);
    };
  }
})(); true;