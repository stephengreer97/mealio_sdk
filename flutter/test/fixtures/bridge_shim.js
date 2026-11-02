(function(){
  if (window.ReactNativeWebView) return;
  window.ReactNativeWebView = { postMessage: function (s) { try { window.__mealioNativePost(String(s)); } catch (e) {} } };
})(); true;