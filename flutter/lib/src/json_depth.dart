// JSON from the page, read with a depth limit. PROTOCOL.md: every SDK parses
// a message from the page with a depth limit of 512, and a container deeper
// than that is kept empty, never built. `jsonDecode` itself does not recurse,
// but everything after it does (comparison, `jsonEncode`, `toString`), so a
// 100k-deep message built in full overflowed the stack there.
//
// This parser has no recursion at all: it keeps an explicit stack. It accepts
// exactly what `jsonDecode` accepts. Each string and number token is handed to
// `jsonDecode` on its own, so their meaning (escapes, lone surrogates, int or
// double) is jsonDecode's. Containers past the limit are still checked for
// syntax, just not built, so bad JSON is a FormatException at any depth.

import 'dart:convert';

/// The deepest container a message from the page may build. Deeper ones are
/// read but kept empty.
const int maxMessageDepth = 512;

class _Frame {
  _Frame(this.list, this.map);
  final List<Object?>? list; // null when skipped or a map
  final Map<String, Object?>? map; // null when skipped or a list
  bool get isList => list != null;
  // The kind of the skipped child being read, while one is.
  bool _skipList = false;
  String? key; // the pending key of a map
  // 0: expecting first entry or close; 1: expecting a value (after ':' or ',');
  // 2: expecting ',' or close; 3: (map) expecting a key after ','.
  int state = 0;
}

/// `jsonDecode(text)`, except that a container nested deeper than [maxDepth]
/// comes back empty. Throws FormatException on anything jsonDecode rejects.
Object? decodeJsonLimited(String text, {int maxDepth = maxMessageDepth}) {
  final n = text.length;
  var i = 0;
  final stack = <_Frame>[];
  var skipped = 0; // open containers past maxDepth (not on `stack`)
  final skipKinds = <bool>[]; // true for '[' among the skipped ones
  // Their states, the same values as _Frame.state.
  final skipStates = <int>[];
  Object? result;
  var done = false;

  Never fail([String? why]) => throw FormatException(why ?? 'Unexpected character', text, i < n ? i : n);

  void ws() {
    while (i < n) {
      final c = text.codeUnitAt(i);
      if (c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d) {
        i++;
      } else {
        break;
      }
    }
  }

  int stringEnd(int start) {
    var j = start + 1;
    while (j < n) {
      final c = text.codeUnitAt(j);
      if (c == 0x22) return j + 1;
      if (c == 0x5c) {
        j += 2;
      } else {
        j++;
      }
    }
    i = n;
    fail('Unterminated string');
  }

  int scalarEnd(int start) {
    var j = start;
    while (j < n) {
      final c = text.codeUnitAt(j);
      if (c == 0x2c || c == 0x5d || c == 0x7d || c == 0x3a || c == 0x20 || c == 0x09 || c == 0x0a || c == 0x0d ||
          c == 0x5b || c == 0x7b || c == 0x22) {
        break;
      }
      j++;
    }
    if (j == start) fail();
    return j;
  }

  // The state of the innermost open container, skipped or built.
  int topState() => skipped > 0 ? skipStates.last : stack.last.state;
  void setTop(int s) {
    if (skipped > 0) {
      skipStates[skipStates.length - 1] = s;
    } else {
      stack.last.state = s;
    }
  }

  bool topIsList() => skipped > 0 ? skipKinds.last : stack.last.isList;

  void put(Object? v) {
    if (stack.isEmpty && skipped == 0) {
      result = v;
      done = true;
      return;
    }
    if (skipped > 0) return;
    final f = stack.last;
    if (f.list != null) {
      f.list!.add(v);
    } else if (f.map != null) {
      f.map![f.key!] = v;
    }
  }

  void close() {
    if (skipped > 0) {
      skipped--;
      skipKinds.removeLast();
      skipStates.removeLast();
      if (skipped > 0) return;
      // The outermost skipped container is an empty one in its parent.
      final f = stack.last;
      f.state = 2;
      if (f.list != null) {
        f.list!.add(f._skipList ? <Object?>[] : <String, Object?>{});
      } else if (f.map != null) {
        f.map![f.key!] = f._skipList ? <Object?>[] : <String, Object?>{};
      }
      return;
    }
    final f = stack.removeLast();
    final Object? v = f.list ?? f.map;
    if (stack.isEmpty) {
      result = v;
      done = true;
    } else {
      stack.last.state = 2;
      put(v);
    }
  }

  void open(bool list) {
    final depth = stack.length + skipped + 1;
    if (depth > maxDepth) {
      if (skipped == 0 && stack.isNotEmpty) stack.last._skipList = list;
      skipped++;
      skipKinds.add(list);
      skipStates.add(0);
    } else {
      stack.add(list ? _Frame(<Object?>[], null) : _Frame(null, <String, Object?>{}));
    }
  }

  while (true) {
    ws();
    if (done) {
      if (i < n) fail();
      return result;
    }
    if (i >= n) fail('Unexpected end of input');
    final c = text.codeUnitAt(i);
    final inside = stack.isNotEmpty || skipped > 0;
    final state = inside ? topState() : 1;
    final list = inside && topIsList();
    if (inside && !list && (state == 0 || state == 3)) {
      // A map wants a key (or, in state 0, may close).
      if (c == 0x7d && state == 0) {
        i++;
        close();
        continue;
      }
      if (c != 0x22) fail();
      final e = stringEnd(i);
      final k = jsonDecode(text.substring(i, e)) as String;
      i = e;
      ws();
      if (i >= n || text.codeUnitAt(i) != 0x3a) fail();
      i++;
      if (skipped == 0) stack.last.key = k;
      setTop(1);
      continue;
    }
    if (inside && state == 2) {
      if (c == 0x2c) {
        i++;
        setTop(list ? 1 : 3);
        continue;
      }
      if ((list && c == 0x5d) || (!list && c == 0x7d)) {
        i++;
        close();
        continue;
      }
      fail();
    }
    // A value is expected (state 1, or state 0 in a list).
    if (list && state == 0 && c == 0x5d) {
      i++;
      close();
      continue;
    }
    if (inside) setTop(2);
    if (c == 0x5b || c == 0x7b) {
      i++;
      open(c == 0x5b);
      continue;
    }
    final e = c == 0x22 ? stringEnd(i) : scalarEnd(i);
    final v = jsonDecode(text.substring(i, e));
    i = e;
    put(v);
  }
}
