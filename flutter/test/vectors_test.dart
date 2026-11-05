// The shared protocol vectors, run the same way packages/core/test/core.test.ts
// runs them: every case, every allowlist case, every matcher case.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:mealio_sdk/mealio_sdk.dart';

import 'support.dart';

void main() {
  group('test vectors', () {
    for (final Map<String, Object?> c in vectorList('cases')) {
      test(c['name']! as String, () async {
        final runner = Runner(FakeHost(), keys: testKeys);
        final env = Envelope.fromJson(c['envelope']);
        final job = c['job']! as String;
        final lastSeq = (c['lastSeq']! as num).toInt();
        if (c['expect'] == 'ok') {
          final out = await runner.run(env, job, lastSeq);
          final firstResultError = c['firstResultError'];
          if (firstResultError != null) {
            expect(out.results.first.error, firstResultError);
          } else {
            expect(out.results.every((InstructionResult r) => r.ok) || out.terminal != null, isTrue);
          }
        } else {
          await expectLater(
            runner.run(env, job, lastSeq),
            throwsA(isA<EnvelopeError>().having((EnvelopeError e) => e.why, 'why', c['expect'])),
          );
        }
      });
    }

    test('allowlist cases', () {
      final a = Allowlist();
      for (final Map<String, Object?> c in vectorList('allowlist')) {
        final store = c['store']! as String;
        final url = c['url']! as String;
        final use = UrlUse.values.byName(c['use']! as String);
        expect(a.check(store, url, use).ok, c['ok'], reason: '$store $url ${use.name}');
      }
    });

    test('blocked body cases', () {
      for (final Map<String, Object?> c in vectorList('blockedBodies')) {
        final body = c['body']! as String;
        expect(bodyBlocked(body), c['blocked'], reason: body);
      }
    });

    test('parses only plain host names: no userinfo, backslash or spaces', () {
      expect(parseUrl('https://www.heb.com:x@evil.com/'), isNull);
      expect(parseUrl(r'https://evil.com\.heb.com/'), isNull);
      expect(parseUrl('https://www.heb.com /'), isNull);
      final p = parseUrl('https://www.heb.com:443/a?b=1#c')!;
      expect(<String>[p.scheme, p.host, p.rest], <String>['https', 'www.heb.com', '/a?b=1']);
      expect(parseUrl('https://www.heb.com')!.rest, '/');
    });

    test('matcher cases', () {
      for (final Map<String, Object?> c in vectorList('matchers')) {
        final msg = parseMessage(c['msg'])!;
        expect(messageMatches(msg, MessageMatcher.fromJson(c['m'])), c['ok'], reason: jsonEncode(c));
      }
    });

    test('done carries unicode result intact', () async {
      final c = vectorCase('valid_unicode_done');
      final out = await Runner(FakeHost(), keys: testKeys).run(Envelope.fromJson(c['envelope']), 'job_test', 1);
      final terminal = out.terminal;
      expect(terminal, isA<TerminalDone>());
      expect((terminal! as TerminalDone).result, <String, Object?>{'hello': 'café ✓'});
    });

    test('refuses the production key for test envelopes', () async {
      final c = vectorList('cases').first;
      await expectLater(
        openEnvelope(Envelope.fromJson(c['envelope'])),
        throwsA(isA<EnvelopeError>().having((EnvelopeError e) => e.why, 'why', 'unknown_kid')),
      );
    });

    test('the test seed derives the vectors public key', () async {
      final pub = await (await testKeyPair()).extractPublicKey();
      expect(base64Encode(pub.bytes), vectors['publicKey']);
    });
  });

  group('guard script', () {
    test('GUARD_SCRIPT is byte-for-byte the TypeScript output', () {
      expect(guardScript, File('test/fixtures/guard_script.js').readAsStringSync());
    });

    test('BRIDGE_SHIM is byte-for-byte the TypeScript output', () {
      expect(bridgeShim, File('test/fixtures/bridge_shim.js').readAsStringSync());
    });

    test('the bridge injection defines the native post and then the shim', () {
      final js = bridgeInjection('abc123');
      expect(js, startsWith('window.__mealioNativePost = function(s){ __mealioNativeBridge.postMessage('));
      expect(js, contains('"abc123"'));
      expect(js, endsWith(bridgeShim));
    });

    test('bridge messages without the nonce are dropped', () {
      const msg = '{"type":"X","loggedIn":true}';
      expect(bridgeUnwrap(jsonEncode(<String, Object?>{'n': 'abc123', 'm': msg}), 'abc123'), msg);
      expect(bridgeUnwrap(jsonEncode(<String, Object?>{'n': 'nope', 'm': msg}), 'abc123'), isNull);
      expect(bridgeUnwrap(msg, 'abc123'), isNull);
      expect(bridgeUnwrap('not json', 'abc123'), isNull);
    });
  });
}
