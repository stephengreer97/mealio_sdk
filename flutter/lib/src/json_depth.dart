// JSON from the page, read with a depth limit. PROTOCOL.md: every SDK parses
// a message from the page with a depth limit of 512, and a container deeper
// than that is kept empty, never built. `jsonDecode` itself does not recurse,
// but everything after it does (comparison, `jsonEncode`, `toString`), so a
// 100k-deep message built in full overflowed the stack there.
//
// This is parseJson in matcher.ts, step for step, so every SDK accepts the
// same messages: a container that opens deeper than the limit is found by
// bracket and string matching alone and replaced with an empty one of its
// kind, its contents never read (so text inside it that is not JSON is
// dropped, as TypeScript drops it). What is left is handed to `jsonDecode`,
// which never sees a container deeper than the limit. No recursion anywhere.

import 'dart:convert';

/// The deepest container a message from the page may build. Deeper ones are
/// read but kept empty.
const int maxMessageDepth = 512;

/// `jsonDecode(text)`, except that a container nested deeper than [maxDepth]
/// comes back empty (the top container is depth 1). Throws FormatException on
/// what is left if it is not JSON. parseJson in matcher.ts.
Object? decodeJsonLimited(String text, {int maxDepth = maxMessageDepth}) {
  final n = text.length;
  StringBuffer? out;
  var last = 0, depth = 0;
  var inString = false;
  for (var i = 0; i < n; i++) {
    final c = text.codeUnitAt(i);
    if (inString) {
      if (c == 0x5c) {
        i++; // backslash: skip the escaped character
      } else if (c == 0x22) {
        inString = false;
      }
      continue;
    }
    if (c == 0x22) {
      inString = true;
      continue;
    }
    if (c == 0x5b || c == 0x7b) {
      depth++;
      if (depth <= maxDepth) continue;
      // Too deep: find where this container closes, and keep it empty.
      final start = i;
      var d = 1, j = i + 1;
      var str = false;
      for (; j < n && d > 0; j++) {
        final k = text.codeUnitAt(j);
        if (str) {
          if (k == 0x5c) {
            j++;
          } else if (k == 0x22) {
            str = false;
          }
          continue;
        }
        if (k == 0x22) {
          str = true;
        } else if (k == 0x5b || k == 0x7b) {
          d++;
        } else if (k == 0x5d || k == 0x7d) {
          d--;
        }
      }
      if (d > 0) break; // never closes: not JSON, and jsonDecode will say so
      (out ??= StringBuffer())
        ..write(text.substring(last, start))
        ..write(c == 0x5b ? '[]' : '{}');
      last = j > n ? n : j;
      i = j - 1;
      depth--;
      continue;
    }
    if (c == 0x5d || c == 0x7d) depth--;
  }
  if (out == null) return jsonDecode(text);
  out.write(text.substring(last));
  return jsonDecode(out.toString());
}
