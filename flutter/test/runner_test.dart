// Runner, allowlist widening, client loop and CartSession, against a fake
// Host. Envelopes beyond the shared vectors are signed here with the same
// deterministic test key.

import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mealio_sdk/mealio_sdk.dart';

import 'support.dart';

Matcher _why(String why) => throwsA(isA<EnvelopeError>().having((EnvelopeError e) => e.why, 'why', why));

Map<String, Object?> _open(String id, String url) =>
    <String, Object?>{'op': 'page_open', 'id': id, 'url': url, 'timeoutMs': 1000};

Map<String, Object?> _script(String id) => <String, Object?>{
      'op': 'page_script',
      'id': id,
      'script': 'true;',
      'until': <Object?>[
        <String, Object?>{'type': 'X'},
      ],
      'timeoutMs': 1000,
    };

Map<String, Object?> _fetch(String id, String url) => <String, Object?>{
      'op': 'fetch',
      'id': id,
      'request': <String, Object?>{'method': 'GET', 'url': url},
      'timeoutMs': 1000,
      'maxBytes': 1000,
    };

http.Response _json(Object? body, [int status = 200]) => http.Response.bytes(
      utf8.encode(jsonEncode(body)),
      status,
      headers: <String, String>{'content-type': 'application/json'},
    );

void main() {
  group('runner', () {
    test('skips the rest of an envelope after a failure', () async {
      final c = vectorCase('blocked_url_runs_but_refuses');
      final host = FakeHost();
      final out = await Runner(host, keys: testKeys).run(Envelope.fromJson(c['envelope']), 'job_test', 0);
      expect(out.results, hasLength(1));
      expect(host.calls, isEmpty);
    });

    test('marks every later instruction skipped, and still honours done', () async {
      final env = await signInstructions(<Map<String, Object?>>[
        _open('i1', 'https://www.heb.com/checkout/review'),
        _script('i2'),
        _fetch('i3', 'https://www.heb.com/x'),
        <String, Object?>{'op': 'done', 'id': 'i4', 'result': 7},
      ]);
      final host = FakeHost();
      final out = await Runner(host, keys: testKeys).run(env, 'job_test', 0);
      expect(host.calls, isEmpty);
      expect(out.results.map((InstructionResult r) => r.toJson()).toList(), <Object?>[
        <String, Object?>{'id': 'i1', 'ok': false, 'error': 'blocked', 'ms': 0},
        <String, Object?>{'id': 'i2', 'ok': false, 'messages': <Object?>[], 'timedOut': false, 'ms': 0, 'skipped': true},
        <String, Object?>{'id': 'i3', 'ok': false, 'ms': 0, 'skipped': true},
      ]);
      expect((out.terminal! as TerminalDone).result, 7);
    });

    test('fail ends the job with the server code', () async {
      final env = await signInstructions(<Map<String, Object?>>[
        <String, Object?>{'op': 'fail', 'id': 'i1', 'code': 'store_unavailable', 'message': 'down'},
      ]);
      final out = await Runner(FakeHost(), keys: testKeys).run(env, 'job_test', 0);
      final t = out.terminal! as TerminalFail;
      expect(t.code, 'store_unavailable');
      expect(t.message, 'down');
      expect(out.results, isEmpty);
    });

    test('runs instructions in order and reports page_open and page_script', () async {
      final c = vectorCase('valid_two_instructions');
      final host = FakeHost();
      final out = await Runner(host, keys: testKeys).run(Envelope.fromJson(c['envelope']), 'job_test', 0);
      expect(host.calls, <String>['open https://www.heb.com/robots.txt', 'script']);
      final open = out.results[0] as PageOpenResult;
      expect(open.ok, isTrue);
      expect(open.finalUrl, 'https://www.heb.com/robots.txt');
      final script = out.results[1] as PageScriptResult;
      expect(script.messages.single['type'], 'HEB_SESSION');
      expect(script.timedOut, isFalse);
      expect(out.terminal, isNull);
    });

    test('host failures become instruction failures, not exceptions', () async {
      final env = await signInstructions(<Map<String, Object?>>[_open('i1', 'https://www.heb.com/')]);
      final host = FakeHost(onOpen: (String url) async => throw StateError('boom'));
      final out = await Runner(host, keys: testKeys).run(env, 'job_test', 0);
      expect(out.results.single.toJson()['error'], 'load_failed');

      final env2 = await signInstructions(<Map<String, Object?>>[_fetch('i1', 'https://www.heb.com/x')]);
      final host2 = FakeHost(onFetch: (FetchRequest r) async => throw StateError('boom'));
      final out2 = await Runner(host2, keys: testKeys).run(env2, 'job_test', 0);
      expect(out2.results.single.error, 'no_response');

      final env3 = await signInstructions(<Map<String, Object?>>[_script('i1')]);
      final host3 = FakeHost(
        onScript: (String s, List<MessageMatcher> u) async =>
            const ScriptRun(messages: <JsonMessage>[], timedOut: false, error: 'x'),
      );
      final out3 = await Runner(host3, keys: testKeys).run(env3, 'job_test', 0);
      expect(out3.results.single.ok, isFalse);
    });

    test('show_login hands the host an allowlist-backed navigation check', () async {
      LoginRequest? seen;
      final env = await signInstructions(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'show_login',
          'id': 'i1',
          'url': 'https://www.heb.com/my-account/login',
          'title': 'Sign in to H-E-B',
          'check': <String, Object?>{'script': 'true;', 'intervalMs': 3000},
          'doneWhen': <Object?>[
            <String, Object?>{
              'type': 'HEB_SESSION',
              'eq': <String, Object?>{'loggedIn': true},
            },
          ],
          'doneWhenUrl': null,
          'timeoutMs': 600000,
        },
      ]);
      final host = FakeHost(onLogin: (LoginRequest r) async {
        seen = r;
        return const LoginResult(outcome: LoginOutcome.signedIn, messages: <JsonMessage>[]);
      });
      final out = await Runner(host, keys: testKeys).run(env, 'job_test', 0);
      expect(out.results.single.toJson()['outcome'], 'signed_in');
      final r = seen!;
      expect(r.title, 'Sign in to H-E-B');
      expect(r.guard, guardScript);
      expect(r.check!.intervalMs, 3000);
      expect(r.allowNavigation('https://accounts.google.com/o/oauth2'), isTrue);
      expect(r.allowNavigation('https://www.heb.com/my-account'), isTrue);
      expect(r.allowNavigation('https://evil.example/'), isFalse);
      expect(r.allowNavigation('https://www.heb.com/checkout'), isFalse);
    });

    test('a login URL outside the allowlist is refused without showing anything', () async {
      final env = await signInstructions(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'show_login',
          'id': 'i1',
          'url': 'https://evil.example/login',
          'title': 't',
          'doneWhen': <Object?>[],
          'timeoutMs': 1000,
        },
      ]);
      final host = FakeHost();
      final out = await Runner(host, keys: testKeys).run(env, 'job_test', 0);
      expect(host.calls, isEmpty);
      expect(out.results.single.toJson(), <String, Object?>{
        'id': 'i1',
        'ok': false,
        'outcome': 'cancelled',
        'messages': <Object?>[],
        'error': 'blocked',
        'ms': 0,
      });
    });

    test('caps fetch at 120 a minute per store', () async {
      final runner = Runner(FakeHost(), keys: testKeys);
      final first = await signInstructions(
        List<Map<String, Object?>>.generate(64, (int n) => _fetch('a$n', 'https://www.heb.com/x')),
      );
      final out1 = await runner.run(first, 'job_test', 0);
      expect(out1.results.every((InstructionResult r) => r.ok), isTrue);
      final second = await signInstructions(
        List<Map<String, Object?>>.generate(57, (int n) => _fetch('b$n', 'https://www.heb.com/x')),
        seq: 2,
      );
      final out2 = await runner.run(second, 'job_test', 1);
      expect(out2.results.take(56).every((InstructionResult r) => r.ok), isTrue);
      expect(out2.results[56].error, 'rate');
    });
  });

  group('envelope checks', () {
    test('shape', () async {
      await expectLater(openEnvelope(Envelope.fromJson(<String, Object?>{'sig': 'x', 'kid': 'ktest'}), testKeys), _why('shape'));
      await expectLater(openEnvelope(Envelope.fromJson('nope'), testKeys), _why('shape'));
    });

    test('json', () async {
      await expectLater(openEnvelope(await signText('{not json'), testKeys), _why('json'));
    });

    test('version', () async {
      final env = await signInstructions(<Map<String, Object?>>[_open('i1', 'https://www.heb.com/')], v: 2);
      await expectLater(Runner(FakeHost(), keys: testKeys).run(env, 'job_test', 0), _why('version'));
      await expectLater(openEnvelope(await signText('[1]'), testKeys), _why('version'));
    });

    test('expiry allows 120 seconds of skew', () async {
      final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
      final ok = await signInstructions(<Map<String, Object?>>[_open('i1', 'https://www.heb.com/')], exp: now - 60);
      await Runner(FakeHost(), keys: testKeys).run(ok, 'job_test', 0);
      final stale = await signInstructions(<Map<String, Object?>>[_open('i1', 'https://www.heb.com/')], exp: now - 200);
      await expectLater(Runner(FakeHost(), keys: testKeys).run(stale, 'job_test', 0), _why('expired'));
    });

    test('kind', () async {
      final env = await signInstructions(<Map<String, Object?>>[_open('i1', 'https://www.heb.com/')], kind: 'allowlist');
      await expectLater(Runner(FakeHost(), keys: testKeys).run(env, 'job_test', 0), _why('kind'));
    });

    test('empty and too_many', () async {
      final empty = await signInstructions(<Map<String, Object?>>[]);
      await expectLater(Runner(FakeHost(), keys: testKeys).run(empty, 'job_test', 0), _why('empty'));
      final many = await signInstructions(
        List<Map<String, Object?>>.generate(65, (int n) => _open('i$n', 'https://www.heb.com/')),
      );
      await expectLater(Runner(FakeHost(), keys: testKeys).run(many, 'job_test', 0), _why('too_many'));
    });

    test('unsupported_op', () async {
      final env = await signInstructions(<Map<String, Object?>>[
        <String, Object?>{'op': 'eval_native', 'id': 'i1'},
      ]);
      await expectLater(Runner(FakeHost(), keys: testKeys).run(env, 'job_test', 0), _why('unsupported_op'));
      final noId = await signInstructions(<Map<String, Object?>>[
        <String, Object?>{'op': 'page_open', 'url': 'https://www.heb.com/'},
      ]);
      await expectLater(Runner(FakeHost(), keys: testKeys).run(noId, 'job_test', 0), _why('unsupported_op'));
    });

    test('a null job skips the job check', () async {
      final c = vectorCase('wrong_job');
      final out = await Runner(FakeHost(), keys: testKeys).run(Envelope.fromJson(c['envelope']), null, 0);
      expect(out.payload.job, 'job_test');
    });

    test('url-safe and unpadded base64 decode the same', () {
      expect(base64ToBytes('-_8'), base64ToBytes('+/8='));
      expect(base64ToBytes('AQID'), <int>[1, 2, 3]);
    });
  });

  group('allowlist widening', () {
    test('adds only hosts on a registrable domain the store already has', () {
      final a = Allowlist();
      a.widen(AllowlistPayload.fromJson(<String, Object?>{
        'v': 1,
        'kind': 'allowlist',
        'exp': 0,
        'stores': <String, Object?>{
          'heb': <String, Object?>{
            'hosts': <Object?>['api.heb.com', 'heb-cdn.net'],
          },
          'nope': <String, Object?>{
            'hosts': <Object?>['x.com'],
          },
        },
      }));
      expect(a.hostsFor('heb')!.hosts, contains('api.heb.com'));
      expect(a.hostsFor('heb')!.hosts, isNot(contains('heb-cdn.net')));
      expect(a.hostsFor('nope'), isNull);
      expect(a.check('heb', 'https://www.heb.com/checkout', UrlUse.page).ok, isFalse);
    });

    test('registrableDomain knows two-label public suffixes', () {
      expect(registrableDomain('www.shop.example.co.uk'), 'example.co.uk');
      expect(registrableDomain('a.b.heb.com'), 'heb.com');
      expect(registrableDomain('heb.com'), 'heb.com');
    });

    test('ports, case and the default path', () {
      final a = Allowlist();
      expect(a.check('heb', 'HTTPS://WWW.HEB.COM:443', UrlUse.page).ok, isTrue);
      expect(a.check('heb', 'not a url', UrlUse.page).reason, 'bad_url');
      expect(a.check('heb', 'https://www.heb.com/Gift-Card/buy', UrlUse.fetch).reason, 'blocked_path');
      expect(a.check('heb', 'https://mealio.co/return', UrlUse.login).ok, isTrue);
      expect(a.check('heb', 'https://mealio.co/return', UrlUse.page).ok, isFalse);
    });
  });

  group('client', () {
    test('drives a job to done through step calls', () async {
      final c1 = vectorList('cases')[0]['envelope'];
      final c2 = vectorList('cases')[1]['envelope'];
      final seen = <String>[];
      final mock = MockClient((http.Request req) async {
        seen.add(req.url.path);
        expect(req.headers['x-mealio-sdk'], 'flutter/$mealioSdkVersion');
        expect(req.headers['x-mealio-publishable-key'], 'pk_test');
        expect(req.headers['authorization'], 'Bearer tok');
        expect(req.headers['content-type'], 'application/json');
        if (req.url.path.endsWith('/hello')) {
          final b = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, Object?>;
          final sdk = b['sdk']! as Map<String, Object?>;
          expect(sdk['platform'], 'flutter');
          expect(sdk['core'], sdkCoreVersion);
          expect(sdk['ops'], supportedOps);
          expect(b['epoch'], 3);
          return _json(<String, Object?>{'ok': true});
        }
        if (req.url.path.endsWith('/carts')) return _json(<String, Object?>{'job': 'job_test', 'envelope': c1});
        if (req.url.path.endsWith('/step')) {
          final b = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, Object?>;
          expect(b['seq'], 1);
          expect(b['results']! as List<Object?>, hasLength(2));
          return _json(<String, Object?>{'envelope': c2});
        }
        throw StateError('unexpected ${req.url}');
      });
      final client = MealioClient(
        ClientConfig(
          publishableKey: 'pk_test',
          getSessionToken: () async => 'tok',
          baseUrl: 'https://mealio.test/',
          getEpoch: () async => 3,
          httpClient: mock,
          keys: testKeys,
        ),
        FakeHost(),
      );
      // The done result is not a PreparedCart here; the point is the loop.
      final session = await client.prepareCart(store: 'heb', recipe: const Recipe(id: 'r1', ingredients: <RecipeIngredient>[]));
      expect(seen, <String>['/api/v1/sdk/hello', '/api/v1/sdk/carts', '/api/v1/sdk/jobs/job_test/step']);
      expect(session, isA<CartSession>());
    });

    test('retries once with a fresh token on 401', () async {
      var tokens = 0;
      var calls = 0;
      final auth = <String?>[];
      final mock = MockClient((http.Request req) async {
        calls += 1;
        auth.add(req.headers['authorization']);
        if (calls == 1) return _json(<String, Object?>{}, 401);
        return _json(<String, Object?>{'ok': true});
      });
      final client = MealioClient(
        ClientConfig(
          publishableKey: 'pk',
          getSessionToken: () async => 't${++tokens}',
          sdkVersion: '0',
          httpClient: mock,
          keys: testKeys,
        ),
        FakeHost(),
      );
      await client.hello();
      expect(tokens, 2);
      expect(auth, <String?>['Bearer t1', 'Bearer t2']);
    });

    test('a second 401 is session_expired', () async {
      final mock = MockClient((http.Request req) async => _json(<String, Object?>{}, 401));
      final client = MealioClient(
        ClientConfig(publishableKey: 'pk', getSessionToken: () async => 't', httpClient: mock, keys: testKeys),
        FakeHost(),
      );
      await expectLater(
        client.hello(),
        throwsA(isA<MealioException>().having((MealioException e) => e.code, 'code', 'session_expired')),
      );
    });

    test('server errors carry the server code', () async {
      final mock = MockClient((http.Request req) async => _json(<String, Object?>{
            'error': <String, Object?>{'code': 'store_unavailable', 'message': 'H-E-B is down'},
          }, 503));
      final client = MealioClient(
        ClientConfig(publishableKey: 'pk', getSessionToken: () async => 't', httpClient: mock, keys: testKeys),
        FakeHost(),
      );
      await expectLater(
        client.hello(),
        throwsA(isA<MealioException>()
            .having((MealioException e) => e.code, 'code', 'store_unavailable')
            .having((MealioException e) => e.message, 'message', 'H-E-B is down')),
      );
    });

    test('a transport failure is network', () async {
      final mock = MockClient((http.Request req) async => throw http.ClientException('offline'));
      final client = MealioClient(
        ClientConfig(publishableKey: 'pk', getSessionToken: () async => 't', httpClient: mock, keys: testKeys),
        FakeHost(),
      );
      await expectLater(
        client.hello(),
        throwsA(isA<MealioException>().having((MealioException e) => e.code, 'code', 'network')),
      );
    });

    test('a bad envelope stops the run with bad_envelope, a fail with its code', () async {
      final tampered = vectorCase('tampered_payload')['envelope'];
      final failEnv = await signInstructions(<Map<String, Object?>>[
        <String, Object?>{'op': 'fail', 'id': 'i1', 'code': 'store_unavailable', 'message': 'down'},
      ]);
      for (final (Object? env, String code) in <(Object?, String)>[(tampered, 'bad_envelope'), (failEnv.toJson(), 'store_unavailable')]) {
        final mock = MockClient((http.Request req) async {
          if (req.url.path.endsWith('/hello')) return _json(<String, Object?>{'ok': true});
          return _json(<String, Object?>{'job': 'job_test', 'envelope': env});
        });
        final client = MealioClient(
          ClientConfig(publishableKey: 'pk', getSessionToken: () async => 't', httpClient: mock, keys: testKeys),
          FakeHost(),
        );
        await expectLater(
          client.prepareCart(store: 'heb', recipe: const Recipe(id: 'r', ingredients: <RecipeIngredient>[])),
          throwsA(isA<MealioException>().having((MealioException e) => e.code, 'code', code)),
        );
      }
    });

    test('hello widens the allowlist from a signed allowlist envelope', () async {
      final allow = await signText(jsonEncode(<String, Object?>{
        'v': 1,
        'kind': 'allowlist',
        'exp': 4102444800,
        'stores': <String, Object?>{
          'heb': <String, Object?>{
            'hosts': <Object?>['api.heb.com'],
          },
        },
      }));
      final mock = MockClient((http.Request req) async => _json(<String, Object?>{'ok': true, 'allowlist': allow.toJson()}));
      final client = MealioClient(
        ClientConfig(publishableKey: 'pk', getSessionToken: () async => 't', httpClient: mock, keys: testKeys),
        FakeHost(),
      );
      await client.hello();
      expect(client.allowlist.hostsFor('heb')!.hosts, contains('api.heb.com'));
    });
  });

  group('cart session', () {
    CartSession session() {
      final mock = MockClient((http.Request req) async => _json(<String, Object?>{}));
      final client = MealioClient(
        ClientConfig(publishableKey: 'pk', getSessionToken: () async => 't', httpClient: mock, keys: testKeys),
        FakeHost(),
      );
      return CartSession(
        client,
        PreparedCart.fromJson(<String, Object?>{
          'cartId': 'c1',
          'store': 'heb',
          'ready': <Object?>[
            <String, Object?>{
              'key': 'milk',
              'ingredient': 'milk',
              'quantity': 1,
              'chosen': <String, Object?>{'id': 'p1', 'name': 'Milk'},
            },
          ],
          'needsChoice': <Object?>[
            <String, Object?>{
              'key': 'ham',
              'ingredient': 'ham',
              'quantity': 2,
              'options': <Object?>[
                <String, Object?>{
                  'id': 'p2',
                  'name': 'Ham',
                  'preferences': <Object?>[
                    <String, Object?>{'id': 'sliced', 'label': 'Sliced'},
                  ],
                },
              ],
            },
            <String, Object?>{'key': 'salt', 'ingredient': 'salt', 'quantity': 1, 'options': <Object?>[]},
          ],
          'unavailable': <Object?>[],
        }),
      );
    }

    test('ready items start picked; choose and skip fill the rest', () {
      final s = session();
      expect(s.pending().map((CartItem i) => i.key), <String>['ham', 'salt']);
      s.choose('ham', 'p2', preferenceId: 'sliced');
      s.skip('salt');
      expect(s.pending(), isEmpty);
      expect(s.selections().map((Selection x) => x.toJson()).toList(), <Object?>[
        <String, Object?>{'key': 'milk', 'productId': 'p1', 'quantity': 1, 'remember': true},
        <String, Object?>{'key': 'ham', 'productId': 'p2', 'quantity': 2, 'remember': true, 'preferenceId': 'sliced'},
        <String, Object?>{'key': 'salt', 'productId': null, 'remember': false},
      ]);
    });

    test('refuses items and products that were not offered', () {
      final s = session();
      expect(
        () => s.choose('nope', 'p1'),
        throwsA(isA<MealioException>().having((MealioException e) => e.code, 'code', 'unknown_item')),
      );
      expect(
        () => s.choose('ham', 'p9'),
        throwsA(isA<MealioException>().having((MealioException e) => e.code, 'code', 'unknown_product')),
      );
    });
  });
}
