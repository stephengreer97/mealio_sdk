// Runner, allowlist widening, client loop and CartSession, against a fake
// Host. Envelopes beyond the shared vectors are signed here with the same
// deterministic test key.

import 'dart:async';
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

    test('refuses a fetch whose body names an order, before it leaves the device', () async {
      Map<String, Object?> post(String id, String body) => <String, Object?>{
            'op': 'fetch',
            'id': id,
            'request': <String, Object?>{'method': 'POST', 'url': 'https://www.heb.com/graphql', 'body': body},
            'timeoutMs': 1000,
            'maxBytes': 1000,
          };
      // The JSON text carries a literal backslash-u escape: the server reads
      // "placeOrder" once it parses the body.
      final host = FakeHost();
      final out = await Runner(host, keys: testKeys)
          .run(await signInstructions(<Map<String, Object?>>[post('f1', r'{"operationName":"placeOrder"}')]), 'job_test', 0);
      expect(out.results.single.ok, isFalse);
      expect(out.results.single.error, 'blocked');
      expect(host.calls, isNot(contains('fetch')));

      final host2 = FakeHost();
      final ok = await Runner(host2, keys: testKeys)
          .run(await signInstructions(<Map<String, Object?>>[post('f2', '{"operationName":"cartItemsV2"}')]), 'job_test', 0);
      expect(ok.results.single.ok, isTrue);
      expect(host2.calls, contains('fetch'));
    });

    test('refuses show_login when the run may not sign in (a warm-up)', () async {
      final env = await signInstructions(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'show_login',
          'id': 'l1',
          'url': 'https://www.heb.com/login',
          'title': 'Sign in',
          'doneWhen': <Object?>[],
          'timeoutMs': 1000,
        },
      ]);
      final host = FakeHost();
      final out = await Runner(host, keys: testKeys).run(env, 'job_test', 0, allowLogin: false);
      expect(out.results.single.toJson(), <String, Object?>{
        'id': 'l1',
        'ok': false,
        'outcome': 'cancelled',
        'messages': <Object?>[],
        'error': 'not_allowed',
        'ms': 0,
      });
      expect(host.calls, isNot(contains('login')));

      final out2 = await Runner(host, keys: testKeys).run(env, 'job_test', 0);
      expect(out2.results.single.toJson()['outcome'], 'signed_in');
      expect(host.calls, contains('login'));
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
    MealioClient clientWith(MockClient mock, {Future<int> Function()? getEpoch, Future<String> Function()? token}) =>
        MealioClient(
          ClientConfig(
            publishableKey: 'pk_test',
            getSessionToken: token ?? () async => 'tok',
            baseUrl: 'https://mealio.test/',
            getEpoch: getEpoch,
            httpClient: mock,
            keys: testKeys,
          ),
          FakeHost(),
        );

    void expectAbout(Map<String, Object?> b, int epoch) {
      final sdk = b['sdk']! as Map<String, Object?>;
      expect(sdk['platform'], 'flutter');
      expect(sdk['version'], mealioSdkVersion);
      expect(sdk['core'], sdkCoreVersion);
      expect(sdk['ops'], supportedOps);
      expect(b['epoch'], epoch);
    }

    test('drives a job to done through step calls, with sdk and epoch on the start call and no hello', () async {
      final c1 = vectorList('cases')[0]['envelope'];
      final c2 = vectorList('cases')[1]['envelope'];
      final seen = <String>[];
      final mock = MockClient((http.Request req) async {
        seen.add(req.url.path);
        expect(req.headers['x-mealio-sdk'], 'flutter/$mealioSdkVersion');
        expect(req.headers['x-mealio-publishable-key'], 'pk_test');
        expect(req.headers['authorization'], 'Bearer tok');
        expect(req.headers['content-type'], 'application/json');
        final b = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, Object?>;
        if (req.url.path.endsWith('/carts')) {
          expect(b['store'], 'heb');
          expect(b['zip'], '78701');
          expect((b['recipe']! as Map<String, Object?>)['id'], 'r1');
          expectAbout(b, 3);
          return _json(<String, Object?>{'job': 'job_test', 'envelope': c1});
        }
        if (req.url.path.endsWith('/step')) {
          expect(b['seq'], 1);
          expect(b['results']! as List<Object?>, hasLength(2));
          return _json(<String, Object?>{'envelope': c2});
        }
        throw StateError('unexpected ${req.url}');
      });
      final steps = <MealioStep>[];
      final session = await clientWith(mock, getEpoch: () async => 3).prepareCart(
        store: 'heb',
        zip: '78701',
        recipe: const Recipe(id: 'r1', ingredients: <RecipeIngredient>[]),
        onStep: (MealioStep s, Instruction ins) => steps.add(s),
      );
      expect(seen, <String>['/api/v1/sdk/carts', '/api/v1/sdk/jobs/job_test/step']);
      expect(session, isA<CartSession>());
      expect(steps, hasLength(2));
    });

    test('addToCart sends selections with sdk and epoch', () async {
      final failEnv = await signInstructions(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'done',
          'id': 'i1',
          'result': <String, Object?>{'cartId': 'c1', 'store': 'heb', 'added': <Object?>[]},
        },
      ]);
      Map<String, Object?>? body;
      String? path;
      final mock = MockClient((http.Request req) async {
        path = req.url.path;
        body = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, Object?>;
        return _json(<String, Object?>{'job': 'job_test', 'envelope': failEnv.toJson()});
      });
      final r = await clientWith(mock).addToCart('c 1', const <Selection>[
        Selection(key: 'milk', productId: 'p1', quantity: 1, remember: true),
        Selection(key: 'salt', productId: null, remember: false),
      ]);
      expect(r.cartId, 'c1');
      expect(path, '/api/v1/sdk/carts/c%201/add');
      expect(body!['selections'], <Object?>[
        <String, Object?>{'key': 'milk', 'productId': 'p1', 'quantity': 1, 'remember': true},
        <String, Object?>{'key': 'salt', 'productId': null, 'remember': false},
      ]);
      expectAbout(body!, 0);
    });

    test('search posts key, query, sdk and epoch and returns the options', () async {
      final env = await signInstructions(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'done',
          'id': 'i1',
          'result': <String, Object?>{
            'key': 'garlic',
            'query': 'jar',
            'options': <Object?>[
              <String, Object?>{'id': 'g9', 'name': 'Minced Garlic Jar', 'unitPrice': 2.5},
            ],
          },
        },
      ]);
      Map<String, Object?>? body;
      String? path;
      final mock = MockClient((http.Request req) async {
        path = req.url.path;
        body = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, Object?>;
        return _json(<String, Object?>{'job': 'job_test', 'envelope': env.toJson()});
      });
      final r = await clientWith(mock, getEpoch: () async => 7).search('c1', 'garlic', 'jar');
      expect(path, '/api/v1/sdk/carts/c1/search');
      expect(body!['key'], 'garlic');
      expect(body!['query'], 'jar');
      expectAbout(body!, 7);
      expect(r.key, 'garlic');
      expect(r.options.single.id, 'g9');
      expect(r.options.single.unitPrice, 2.5);
    });

    test('retries once with a fresh token on 401', () async {
      var tokens = 0;
      var calls = 0;
      final auth = <String?>[];
      final env = await signInstructions(<Map<String, Object?>>[
        <String, Object?>{'op': 'done', 'id': 'i1', 'result': <String, Object?>{}},
      ]);
      final mock = MockClient((http.Request req) async {
        calls += 1;
        auth.add(req.headers['authorization']);
        if (calls == 1) return _json(<String, Object?>{}, 401);
        return _json(<String, Object?>{'job': 'job_test', 'envelope': env.toJson()});
      });
      await clientWith(mock, token: () async => 't${++tokens}').addToCart('c1', const <Selection>[]);
      expect(tokens, 2);
      expect(auth, <String?>['Bearer t1', 'Bearer t2']);
    });

    group('resetSession', () {
      MockClient recording(List<String?> auth) => MockClient((http.Request req) async {
            auth.add(req.headers['authorization']);
            return _json(<String, Object?>{});
          });

      test('gives the next user a new token', () async {
        final auth = <String?>[];
        final users = <String>['alice', 'bob'];
        final client = clientWith(recording(auth), token: () async => users.removeAt(0));
        await client.storePreferences();
        await client.storePreferences();
        client.resetSession();
        await client.storePreferences();
        expect(auth, <String?>['Bearer alice', 'Bearer alice', 'Bearer bob']);
      });

      test('drops a token that arrives after the reset', () async {
        final auth = <String?>[];
        final alice = Completer<String>();
        final answers = <Future<String>>[alice.future, Future<String>.value('bob')];
        final client = clientWith(recording(auth), token: () => answers.removeAt(0));
        final asked = client.storePreferences();
        client.resetSession();
        alice.complete('alice');
        await asked;
        await client.storePreferences();
        expect(auth, <String?>['Bearer bob', 'Bearer bob']);
      });
    });

    test('a second 401 is session_expired', () async {
      final mock = MockClient((http.Request req) async => _json(<String, Object?>{}, 401));
      await expectLater(
        clientWith(mock).addToCart('c1', const <Selection>[]),
        throwsA(isA<MealioException>().having((MealioException e) => e.code, 'code', 'session_expired')),
      );
    });

    test('server errors carry the server code', () async {
      final mock = MockClient((http.Request req) async => _json(<String, Object?>{
            'error': <String, Object?>{'code': 'store_unavailable', 'message': 'H-E-B is down'},
          }, 503));
      await expectLater(
        clientWith(mock).prepareCart(store: 'heb', recipe: const Recipe(id: 'r', ingredients: <RecipeIngredient>[])),
        throwsA(isA<MealioException>()
            .having((MealioException e) => e.code, 'code', 'store_unavailable')
            .having((MealioException e) => e.message, 'message', 'H-E-B is down')),
      );
    });

    test('a transport failure is network', () async {
      final mock = MockClient((http.Request req) async => throw http.ClientException('offline'));
      await expectLater(
        clientWith(mock).search('c1', 'k', 'q'),
        throwsA(isA<MealioException>().having((MealioException e) => e.code, 'code', 'network')),
      );
    });

    test('a bad envelope stops the run with bad_envelope, a fail with its code', () async {
      final tampered = vectorCase('tampered_payload')['envelope'];
      final failEnv = await signInstructions(<Map<String, Object?>>[
        <String, Object?>{'op': 'fail', 'id': 'i1', 'code': 'store_unavailable', 'message': 'down'},
      ]);
      for (final (Object? env, String code) in <(Object?, String)>[(tampered, 'bad_envelope'), (failEnv.toJson(), 'store_unavailable')]) {
        final mock = MockClient((http.Request req) async => _json(<String, Object?>{'job': 'job_test', 'envelope': env}));
        await expectLater(
          clientWith(mock).prepareCart(store: 'heb', recipe: const Recipe(id: 'r', ingredients: <RecipeIngredient>[])),
          throwsA(isA<MealioException>().having((MealioException e) => e.code, 'code', code)),
        );
      }
    });

    test('stores is a public GET with no auth; prepareCart without a store leaves it out', () async {
      final seen = <String>[];
      Map<String, Object?>? body;
      final mock = MockClient((http.Request req) async {
        seen.add('${req.method} ${req.url.path}');
        if (req.method == 'GET') {
          expect(req.headers['authorization'], isNull);
          return _json(<String, Object?>{
            'stores': <Object?>[
              <String, Object?>{'id': 'heb', 'name': 'H-E-B', 'via': 'device'},
              <String, Object?>{'id': 'kroger', 'name': 'Kroger', 'via': 'kroger_api'},
            ],
          });
        }
        body = jsonDecode(utf8.decode(req.bodyBytes)) as Map<String, Object?>;
        return _json(<String, Object?>{
          'error': <String, Object?>{'code': 'store_required', 'message': 'Pick a store'},
        }, 400);
      });
      final client = clientWith(mock);
      final stores = await client.stores();
      expect(stores.map((StoreInfo s) => s.name), <String>['H-E-B', 'Kroger']);
      expect(stores.last.via, 'kroger_api');
      await expectLater(
        client.prepareCart(recipe: const Recipe(id: 'r', ingredients: <RecipeIngredient>[])),
        throwsA(isA<MealioException>().having((MealioException e) => e.code, 'code', MealioErrorCode.storeRequired)),
      );
      expect(body!.containsKey('store'), isFalse);
      expect(seen, <String>['GET /api/v1/stores', 'POST /api/v1/sdk/carts']);
    });

    test('AddResult reads verified', () {
      expect(AddResult.fromJson(<String, Object?>{'verified': true}).verified, isTrue);
      expect(AddResult.fromJson(<String, Object?>{}).verified, isNull);
    });

    test('widenAllowlist applies a signed allowlist envelope and ignores a bad one', () async {
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
      final client = clientWith(MockClient((http.Request req) async => _json(<String, Object?>{})));
      await client.widenAllowlist(const Envelope(payload: '{}', sig: 'AAAA', kid: 'ktest'));
      expect(client.allowlist.hostsFor('heb')!.hosts, isNot(contains('api.heb.com')));
      await client.widenAllowlist(allow);
      expect(client.allowlist.hostsFor('heb')!.hosts, contains('api.heb.com'));
    });
  });

  group('stepOf', () {
    test('maps instruction ids to progress steps', () {
      Instruction open(String id) => PageOpen(id: id, url: 'https://www.heb.com/', timeoutMs: 1);
      expect(stepOf(open('open-1')), MealioStep.connecting);
      expect(stepOf(open('session-check')), MealioStep.checkingSignIn);
      expect(stepOf(open('resession-2')), MealioStep.checkingSignIn);
      expect(stepOf(open('search-onion')), MealioStep.searching);
      expect(stepOf(open('add-3')), MealioStep.adding);
      expect(stepOf(open('whatever')), MealioStep.connecting);
      expect(
        stepOf(const ShowLogin(
          id: 'session-login',
          url: 'https://www.heb.com/login',
          title: 'Sign in',
          check: null,
          doneWhen: <MessageMatcher>[],
          doneWhenUrl: null,
          timeoutMs: 1,
        )),
        MealioStep.signingIn,
      );
      expect(MealioStep.checkingSignIn.wire, 'checking_sign_in');
    });

    test('Runner.run calls onStep before each instruction it runs, never for skipped ones', () async {
      final env = await signInstructions(<Map<String, Object?>>[
        _open('open-1', 'https://www.heb.com/'),
        _open('search-1', 'https://evil.example/'),
        _open('add-1', 'https://www.heb.com/'),
      ]);
      final seen = <String>[];
      final out = await Runner(FakeHost(), keys: testKeys).run(env, 'job_test', 0, onStep: (Instruction i) {
        seen.add(i.id);
        throw StateError('a progress callback never breaks a run');
      });
      expect(seen, <String>['open-1', 'search-1']);
      expect(out.results.map((InstructionResult r) => r.skipped), <bool>[false, false, true]);
    });
  });

  group('cart session', () {
    Map<String, Object?> prepared() => <String, Object?>{
          'cartId': 'c1',
          'store': 'heb',
          'storeName': 'H-E-B',
          'items': <Object?>[
            <String, Object?>{
              'key': 'onion',
              'ingredient': 'onion',
              'quantity': 2,
              'status': 'remembered',
              'selectedId': 'o1',
              'rememberedPreferenceId': 'diced',
              'remembered': <String, Object?>{'id': 'o1', 'name': 'Onion'},
              'options': <Object?>[
                <String, Object?>{'id': 'o1', 'name': 'Onion', 'price': r'$1.00', 'unitPrice': 1.0},
                <String, Object?>{'id': 'o2', 'name': 'Red Onion', 'unitPrice': 1.25},
              ],
            },
            <String, Object?>{
              'key': 'garlic',
              'ingredient': 'garlic',
              'quantity': 1,
              'status': 'choose',
              'selectedId': null,
              'remembered': null,
              'options': <Object?>[
                <String, Object?>{'id': 'g1', 'name': 'Garlic', 'unitPrice': 0.5},
              ],
            },
            <String, Object?>{
              'key': 'beef',
              'ingredient': 'beef',
              'quantity': 1,
              'status': 'remembered_unavailable',
              'selectedId': null,
              'reason': 'out_of_stock',
              'remembered': <String, Object?>{'id': 'b0', 'name': 'Beef', 'outOfStock': true},
              'options': <Object?>[
                <String, Object?>{'id': 'b1', 'name': 'Ground Beef', 'unitPrice': 5.99, 'estimated': true},
              ],
            },
            <String, Object?>{
              'key': 'saffron',
              'ingredient': 'saffron',
              'quantity': 1,
              'status': 'unavailable',
              'selectedId': null,
              'remembered': null,
              'options': <Object?>[],
              'reason': 'no_results',
            },
          ],
          'ready': <Object?>[],
          'needsChoice': <Object?>[],
          'unavailable': <Object?>[],
        };

    Future<Envelope> searchDone(List<Map<String, Object?>> options) => signInstructions(<Map<String, Object?>>[
          <String, Object?>{
            'op': 'done',
            'id': 'i1',
            'result': <String, Object?>{'key': 'garlic', 'query': 'jar', 'options': options},
          },
        ]);

    CartSession session({Map<String, Object?>? cart, MockClient? mock}) {
      final client = MealioClient(
        ClientConfig(
          publishableKey: 'pk',
          getSessionToken: () async => 't',
          httpClient: mock ?? MockClient((http.Request req) async => _json(<String, Object?>{})),
          keys: testKeys,
        ),
        FakeHost(),
      );
      return CartSession(client, PreparedCart.fromJson(cart ?? prepared()));
    }

    test('parses the 0.2 shape', () {
      final s = session();
      expect(s.storeName, 'H-E-B');
      expect(s.items.map((CartItem i) => i.status), <ItemStatus>[
        ItemStatus.remembered,
        ItemStatus.choose,
        ItemStatus.rememberedUnavailable,
        ItemStatus.unavailable,
      ]);
      expect(s.items[2].remembered!.outOfStock, isTrue);
      expect(s.items[2].options.single.estimated, isTrue);
    });

    test('remembered items start selected with their preference', () {
      final s = session();
      expect(s.isSelected('onion'), isTrue);
      expect(s.selectedId('onion'), 'o1');
      expect(s.selectedPreferenceId('onion'), 'diced');
      expect(s.isSelected('garlic'), isFalse);
      expect(s.isSelected('beef'), isFalse);
      expect(s.selected('onion')!.name, 'Onion');
    });

    test('deselect leaves an item out with productId null and remember false; every item is in selections', () {
      final s = session();
      var notified = 0;
      s.addListener(() => notified += 1);
      s.select('garlic', 'g1');
      s.deselect('onion');
      expect(notified, 2);
      expect(s.selections().map((Selection x) => x.toJson()).toList(), <Object?>[
        <String, Object?>{'key': 'onion', 'productId': null, 'remember': false},
        <String, Object?>{'key': 'garlic', 'productId': 'g1', 'quantity': 1, 'remember': true},
        <String, Object?>{'key': 'beef', 'productId': null, 'remember': false},
        <String, Object?>{'key': 'saffron', 'productId': null, 'remember': false},
      ]);
    });

    test('select keeps a preference; unknown items and products are refused', () {
      final s = session();
      s.select('onion', 'o2', preferenceId: 'sliced');
      expect(s.selections().first.toJson(), <String, Object?>{
        'key': 'onion',
        'productId': 'o2',
        'quantity': 2,
        'remember': true,
        'preferenceId': 'sliced',
      });
      expect(
        () => s.select('nope', 'o1'),
        throwsA(isA<MealioException>().having((MealioException e) => e.code, 'code', 'unknown_item')),
      );
      expect(
        () => s.select('garlic', 'p9'),
        throwsA(isA<MealioException>().having((MealioException e) => e.code, 'code', 'unknown_product')),
      );
    });

    test('search merges found products into the options without duplicates, and they can be selected', () async {
      final envs = <Envelope>[
        await searchDone(<Map<String, Object?>>[
          <String, Object?>{'id': 'g9', 'name': 'Minced Garlic Jar'},
          <String, Object?>{'id': 'g1', 'name': 'Garlic'},
        ]),
        await searchDone(<Map<String, Object?>>[
          <String, Object?>{'id': 'g8', 'name': 'Garlic Powder'},
          <String, Object?>{'id': 'g9', 'name': 'Minced Garlic Jar'},
        ]),
      ];
      var n = 0;
      final mock = MockClient(
          (http.Request req) async => _json(<String, Object?>{'job': 'job_test', 'envelope': envs[n++].toJson()}));
      final s = session(mock: mock);
      var notified = 0;
      s.addListener(() => notified += 1);
      final found = await s.search('garlic', 'jar');
      expect(found.map((Product p) => p.id), <String>['g9', 'g1']);
      expect(s.options('garlic').map((Product p) => p.id), <String>['g1', 'g9']);
      await s.search('garlic', 'powder');
      expect(s.options('garlic').map((Product p) => p.id), <String>['g1', 'g8', 'g9']);
      expect(notified, 2);
      s.select('garlic', 'g9');
      expect(s.selectedId('garlic'), 'g9');
      expect(() => s.select('garlic', 'nope'), throwsA(isA<MealioException>()));
    });

    test('estimate sums unit price times quantity of selected items', () {
      final s = session();
      var e = s.estimate();
      expect(e.count, 1);
      expect(e.total, 2.0);
      expect(e.estimated, isFalse);
      expect(e.unpriced, 0);
      s.select('garlic', 'g1');
      e = s.estimate();
      expect(e.count, 2);
      expect(e.total, 2.5);
      expect(e.estimated, isFalse);
    });

    test('keeps a quantity per item, clamped to 1 and the store cap, in selections and the total', () {
      final cart = prepared();
      final onion = (cart['items']! as List<Object?>).first! as Map<String, Object?>;
      final capped = <String, Object?>{'id': 'o1', 'name': 'Onion', 'unitPrice': 1.5, 'maxQuantity': 3};
      (onion['options']! as List<Object?>)[0] = capped;
      onion['remembered'] = capped;
      onion['quantity'] = 2;
      final s = session(cart: cart);
      expect(s.quantity('onion'), 2);
      expect(s.setQuantity('onion', 9), 3);
      expect(s.setQuantity('onion', 0), 1);
      s.setQuantity('onion', 3);
      expect(s.selections().first.toJson(), <String, Object?>{
        'key': 'onion',
        'productId': 'o1',
        'quantity': 3,
        'remember': true,
        'preferenceId': 'diced',
      });
      expect(s.estimate().total, closeTo(4.5, 1e-9));
      s.select('onion', 'o2');
      expect(s.maxQuantity('onion'), 99);
      expect(s.quantity('onion'), 3);
    });

    test('a missing or 0 recipe quantity starts at 1, in selections and the total', () {
      final cart = prepared();
      final onion = (cart['items']! as List<Object?>).first! as Map<String, Object?>;
      onion['quantity'] = 0;
      final s = session(cart: cart);
      expect(s.items.first.quantity, 0);
      expect(s.quantity('onion'), 1);
      expect(s.selections().first.quantity, 1);
      expect(s.estimate().total, 1.0);
      onion.remove('quantity');
      expect(session(cart: cart).quantity('onion'), 1);
    });

    test('parses the optional quantity fields, and old payloads without them', () {
      final p = Product.fromJson(<String, Object?>{
        'id': 'f1',
        'name': 'Salmon',
        'maxQuantity': 4,
        'soldByWeight': true,
        'weightOptions': <Object?>[0.5, 1, 1.5],
      });
      expect(p.maxQuantity, 4);
      expect(p.soldByWeight, isTrue);
      expect(p.weightOptions, <double>[0.5, 1.0, 1.5]);
      final old = Product.fromJson(<String, Object?>{'id': 'o1', 'name': 'Onion'});
      expect(old.maxQuantity, isNull);
      expect(old.soldByWeight, isNull);
      expect(old.weightOptions, isNull);
    });

    test('estimate is flagged estimated for sold-by-weight or unpriced items', () {
      final s = session();
      s.select('beef', 'b1');
      var e = s.estimate();
      expect(e.total, 7.99);
      expect(e.estimated, isTrue);
      expect(e.unpriced, 0);

      final cart = prepared();
      final onion = (cart['items']! as List<Object?>).first! as Map<String, Object?>;
      (onion['options']! as List<Object?>)[0] = <String, Object?>{'id': 'o1', 'name': 'Onion'};
      e = session(cart: cart).estimate();
      expect(e.count, 1);
      expect(e.total, isNull);
      expect(e.unpriced, 1);
      expect(e.estimated, isTrue);
    });

    group('sold by weight', () {
      const turkey = <String, Object?>{
        'id': 't1',
        'name': 'Deli Turkey',
        'soldByWeight': true,
        'estimated': true,
        'pricePerLb': 10,
        'unitPrice': 10,
        'weightOptions': <Object?>[0.25, 0.5, 0.75, 1, 1.25],
      };
      const salmon = <String, Object?>{
        'id': 's1',
        'name': 'Salmon',
        'soldByWeight': true,
        'estimated': true,
        'pricePerLb': 12,
        'unitPrice': 12,
      };
      const brisket = <String, Object?>{
        'id': 'b1',
        'name': 'Brisket, Avg. 4 lbs',
        'soldByWeight': true,
        'estimated': true,
        'pricePerLb': null,
        'unitPrice': 32,
      };
      Map<String, Object?> weightCart([Map<String, Object?> over = const <String, Object?>{}]) => <String, Object?>{
            'cartId': 'c1',
            'store': 'heb',
            'ready': <Object?>[],
            'needsChoice': <Object?>[],
            'unavailable': <Object?>[],
            'items': <Object?>[
              <String, Object?>{
                'key': 'turkey',
                'ingredient': 'deli turkey',
                'quantity': 1,
                'status': 'remembered',
                'selectedId': 't1',
                'remembered': turkey,
                'options': <Object?>[turkey, salmon, brisket],
                ...over,
              },
              <String, Object?>{
                'key': 'onion',
                'ingredient': 'onion',
                'quantity': 2,
                'status': 'remembered',
                'selectedId': 'o1',
                'remembered': null,
                'options': <Object?>[
                  <String, Object?>{'id': 'o1', 'name': 'Onion', 'unitPrice': 1},
                ],
              },
            ],
          };

      test('parses pricePerLb and the recipe weight, and payloads without them', () {
        final c = PreparedCart.fromJson(weightCart(<String, Object?>{'weightLb': 0.75}));
        expect(c.items.first.weightLb, 0.75);
        expect(c.items.first.options.first.pricePerLb, 10.0);
        expect(c.items.first.options[2].pricePerLb, isNull);
        expect(c.items[1].weightLb, isNull);
        expect(c.items[1].options.first.pricePerLb, isNull);
        final a = AddedItem.fromJson(<String, Object?>{
          'key': 'turkey',
          'productId': 't1',
          'name': 'Deli Turkey',
          'quantity': 1,
          'weightLb': 1.25,
        });
        expect(a.weightLb, 1.25);
        expect(a.toJson()['weightLb'], 1.25);
        expect(AddedItem.fromJson(<String, Object?>{'key': 'o', 'productId': 'o1', 'name': 'O', 'quantity': 1}).weightLb,
            isNull);
        expect(Selection.fromJson(<String, Object?>{'key': 'turkey', 'productId': 't1', 'weightLb': 1}).weightLb, 1.0);
      });

      test('starts at the recipe weight, else the first option, else 0.25', () {
        expect(session(cart: weightCart(<String, Object?>{'weightLb': 0.75})).weight('turkey'), 0.75);
        // A recipe weight the store does not sell becomes the nearest one it does.
        expect(session(cart: weightCart(<String, Object?>{'weightLb': 0.6})).weight('turkey'), 0.5);
        expect(session(cart: weightCart()).weight('turkey'), 0.25);
        final cs = session(cart: weightCart());
        cs.select('turkey', 's1');
        expect(cs.weight('turkey'), 0.25);
        expect(cs.weight('onion'), 0);
        expect(cs.isWeight('turkey'), isTrue);
        expect(cs.isWeight('onion'), isFalse);
      });

      test('setWeight snaps to the options and clamps to their range', () {
        final cs = session(cart: weightCart());
        var notified = 0;
        cs.addListener(() => notified += 1);
        expect(cs.setWeight('turkey', 0.8), 0.75);
        expect(cs.setWeight('turkey', 9), 1.25);
        expect(cs.setWeight('turkey', 0), 0.25);
        expect(cs.setWeight('turkey', double.nan), 0.25);
        expect(cs.weightRange('turkey'), const WeightRange(min: 0.25, max: 1.25));
        expect(cs.weight('turkey'), 0.25);
        expect(notified, 4);
      });

      test('with no options, 0.25 lb steps from 0.25 to 20', () {
        final cs = session(cart: weightCart());
        cs.select('turkey', 's1');
        expect(cs.setWeight('turkey', 1.1), 1);
        expect(cs.setWeight('turkey', 1.13), 1.25);
        expect(cs.setWeight('turkey', 0.01), 0.25);
        expect(cs.setWeight('turkey', 99), 20);
        expect(cs.weightRange('turkey'), const WeightRange(min: weightStep, max: maxWeightLb));
        cs.setWeight('turkey', 1);
        expect(cs.stepWeight('turkey', 1), 1.25);
        expect(cs.stepWeight('turkey', -1), 1);
      });

      test('stepWeight walks the options and stops at the ends', () {
        final cs = session(cart: weightCart());
        expect(cs.stepWeight('turkey', -1), 0.25);
        expect(cs.stepWeight('turkey', 1), 0.5);
        cs.setWeight('turkey', 1.25);
        expect(cs.stepWeight('turkey', 1), 1.25);
        expect(cs.stepWeight('turkey', -1), 1);
      });

      test('switching product re-snaps the weight to the new product', () {
        final cs = session(cart: weightCart());
        cs.select('turkey', 's1');
        cs.setWeight('turkey', 3);
        cs.select('turkey', 't1');
        expect(cs.weight('turkey'), 1.25);
      });

      test('selections send weightLb for weight items only', () {
        final cs = session(cart: weightCart(<String, Object?>{'weightLb': 1}));
        expect(cs.selections().map((Selection x) => x.toJson()).toList(), <Object?>[
          <String, Object?>{'key': 'turkey', 'productId': 't1', 'quantity': 1, 'weightLb': 1.0, 'remember': true},
          <String, Object?>{'key': 'onion', 'productId': 'o1', 'quantity': 2, 'remember': true},
        ]);
      });

      test('estimate is price per lb times the weight, and marked estimated', () {
        final cs = session(cart: weightCart());
        cs.setWeight('turkey', 1.25);
        var e = cs.estimate();
        expect(e.total, 14.5);
        expect(e.estimated, isTrue);
        expect(e.count, 2);
        // A package-priced weight item counts its price once, whatever the weight.
        cs.select('turkey', 'b1');
        cs.setWeight('turkey', 3);
        e = cs.estimate();
        expect(e.total, 34);
        expect(e.estimated, isTrue);
      });
    });

    group('no partial totals', () {
      Map<String, Object?> priced([List<Map<String, Object?>> over = const <Map<String, Object?>>[]]) =>
          <String, Object?>{
            'cartId': 'c1',
            'store': 'heb',
            'items': <Object?>[
              <String, Object?>{
                'key': 'onion',
                'ingredient': 'onion',
                'quantity': 2,
                'status': 'remembered',
                'selectedId': 'o1',
                'remembered': null,
                'options': <Object?>[
                  <String, Object?>{'id': 'o1', 'name': 'Onion', 'unitPrice': 1, ...(over.isNotEmpty ? over[0] : const <String, Object?>{})},
                ],
              },
              <String, Object?>{
                'key': 'turkey',
                'ingredient': 'deli turkey',
                'quantity': 1,
                'weightLb': 0.5,
                'status': 'remembered',
                'selectedId': 't1',
                'remembered': null,
                'options': <Object?>[
                  <String, Object?>{
                    'id': 't1',
                    'name': 'Deli Turkey',
                    'soldByWeight': true,
                    'estimated': true,
                    'pricePerLb': 12,
                    'unitPrice': 12,
                    ...(over.length > 1 ? over[1] : const <String, Object?>{}),
                  },
                ],
              },
              <String, Object?>{
                'key': 'chipotle',
                'ingredient': 'chipotle in adobo',
                'quantity': 1,
                'status': 'choose',
                'selectedId': null,
                'remembered': null,
                'options': <Object?>[
                  <String, Object?>{'id': 'c1', 'name': 'Chipotle Peppers', 'unitPrice': null},
                ],
              },
            ],
          };

      AddResult result(List<AddedItem> added) => AddResult(
            cartId: 'c1',
            store: 'heb',
            added: added,
            skipped: const <SkippedItem>[],
            failed: const <FailedItem>[],
            storeCartUrl: null,
            verified: true,
          );

      test('totals when every selected item has a price; a weight item priced per lb counts as priced', () {
        expect(session(cart: priced()).estimate(),
            const CartEstimate(total: 8, count: 2, estimated: true, unpriced: 0));
      });

      test('total is null when even one selected item has no price', () {
        final cs = session(cart: priced());
        cs.select('chipotle', 'c1');
        expect(cs.estimate(), const CartEstimate(total: null, count: 3, estimated: true, unpriced: 1));
        // A weight item with neither a per-lb nor a package price is unpriced too.
        final w = session(cart: priced(<Map<String, Object?>>[
          <String, Object?>{},
          <String, Object?>{'pricePerLb': null, 'unitPrice': null},
        ]));
        expect(w.estimate().total, isNull);
        expect(w.estimate().unpriced, 1);
        // Deselecting the unpriced item brings the number back.
        cs.deselect('chipotle');
        expect(cs.estimate().total, 8);
      });

      test('prices added items from their own fields: unit times quantity, per lb times pounds, a package once', () {
        expect(addedPrice(const AddedItem(key: 'a', productId: '1', name: 'Onion', quantity: 2, unitPrice: 0.37)),
            const AddedPrice(amount: 0.74, estimated: false));
        expect(
            addedPrice(const AddedItem(
                key: 'b',
                productId: '2',
                name: 'Salmon',
                quantity: 1,
                weightLb: 1.25,
                pricePerLb: 10.9,
                unitPrice: 10.9,
                estimated: true)),
            const AddedPrice(amount: 13.63, estimated: true));
        expect(
            addedPrice(const AddedItem(
                key: 'c', productId: '3', name: 'Brisket', quantity: 1, weightLb: 4, unitPrice: 32, estimated: true)),
            const AddedPrice(amount: 32, estimated: true));
        expect(addedPrice(const AddedItem(key: 'd', productId: '4', name: 'Chipotle', quantity: 1)), isNull);
      });

      test('addedTotal reads the added entries, falls back to the session product, and is null when any is unpriced',
          () {
        final cs = session(cart: priced());
        final full = result(const <AddedItem>[
          AddedItem(
              key: 'onion',
              productId: 'o1',
              name: 'Onion',
              quantity: 2,
              imageUrl: 'https://img/o.jpg',
              ingredient: '2 onions',
              unitPrice: 1.25),
          AddedItem(key: 'turkey', productId: 't1', name: 'Deli Turkey', quantity: 1, weightLb: 0.5, pricePerLb: 12, estimated: true),
        ]);
        expect(cs.addedTotal(full), const CartEstimate(total: 8.5, count: 2, estimated: true, unpriced: 0));
        // An older server: no prices on the entries, the selected products stand in.
        final old = result(const <AddedItem>[
          AddedItem(key: 'onion', productId: 'o1', name: 'Onion', quantity: 2),
          AddedItem(key: 'turkey', productId: 't1', name: 'Deli Turkey', quantity: 1, weightLb: 0.5),
        ]);
        expect(cs.addedTotal(old), const CartEstimate(total: 8, count: 2, estimated: true, unpriced: 0));
        cs.select('chipotle', 'c1');
        expect(
          cs.addedTotal(result(<AddedItem>[
            ...full.added,
            const AddedItem(key: 'chipotle', productId: 'c1', name: 'Chipotle Peppers', quantity: 1),
          ])),
          const CartEstimate(total: null, count: 3, estimated: true, unpriced: 1),
        );
        expect(cs.addedPrice(full.added[0]), const AddedPrice(amount: 2.5, estimated: false));
      });

      test('AddedItem reads and writes the finished-run fields, and older entries without them', () {
        final a = AddedItem.fromJson(<String, Object?>{
          'key': 'onion',
          'productId': 'o1',
          'name': 'Onion',
          'quantity': 2,
          'imageUrl': 'https://img/o.jpg',
          'ingredient': '2 onions',
          'unitPrice': 1.25,
          'pricePerLb': null,
          'estimated': false,
        });
        expect(a.imageUrl, 'https://img/o.jpg');
        expect(a.ingredient, '2 onions');
        expect(a.unitPrice, 1.25);
        expect(a.pricePerLb, isNull);
        expect(a.estimated, isFalse);
        expect(a.toJson(), <String, Object?>{
          'key': 'onion',
          'productId': 'o1',
          'name': 'Onion',
          'quantity': 2,
          'imageUrl': 'https://img/o.jpg',
          'ingredient': '2 onions',
          'unitPrice': 1.25,
          'estimated': false,
        });
        final old = AddedItem.fromJson(<String, Object?>{'key': 'k', 'productId': 'p', 'name': 'N', 'quantity': 1});
        expect(old.imageUrl, isNull);
        expect(old.estimated, isNull);
        expect(old.toJson(), <String, Object?>{'key': 'k', 'productId': 'p', 'name': 'N', 'quantity': 1});
      });
    });

    test('holds an item back from the add and the total until its preference is chosen', () {
      final cart = prepared();
      final garlic = (cart['items']! as List<Object?>)[1]! as Map<String, Object?>;
      garlic['options'] = <Object?>[
        <String, Object?>{
          'id': 'g1',
          'name': 'Deli Turkey',
          'unitPrice': 6,
          'preferences': <Object?>[
            <String, Object?>{'id': 'thin', 'label': 'Thin'},
            <String, Object?>{'id': 'none', 'label': 'No preference'},
          ],
        },
      ];
      final cs = session(cart: cart);
      cs.select('garlic', 'g1');
      expect(cs.needsPreference('garlic'), isTrue);
      expect(cs.needsPreference('onion'), isFalse);
      expect(cs.needsPreference('beef'), isFalse);
      expect(cs.pendingPreferences(), <String>['garlic']);
      expect(cs.selections()[1].toJson(), <String, Object?>{'key': 'garlic', 'productId': null, 'remember': false});
      expect(cs.estimate().count, 1);
      cs.select('garlic', 'g1', preferenceId: 'thin');
      expect(cs.needsPreference('garlic'), isFalse);
      expect(cs.pendingPreferences(), isEmpty);
      expect(cs.preferenceId('garlic'), 'thin');
      expect(cs.selections()[1].toJson(), <String, Object?>{
        'key': 'garlic',
        'productId': 'g1',
        'quantity': 1,
        'remember': true,
        'preferenceId': 'thin',
      });
      expect(cs.estimate().count, 2);
    });

    test('a 0.1 cart without items is rebuilt from the groupings, ready items pre-selected', () {
      final s = session(cart: <String, Object?>{
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
              <String, Object?>{'id': 'p2', 'name': 'Ham'},
            ],
          },
        ],
        'unavailable': <Object?>[
          <String, Object?>{'key': 'salt', 'ingredient': 'salt', 'quantity': 1, 'reason': 'no_results'},
        ],
      });
      expect(s.items.map((CartItem i) => i.key), <String>['milk', 'ham', 'salt']);
      expect(s.items.map((CartItem i) => i.status),
          <ItemStatus>[ItemStatus.remembered, ItemStatus.choose, ItemStatus.unavailable]);
      expect(s.selectedId('milk'), 'p1');
      expect(s.options('milk').single.id, 'p1');
      // ignore: deprecated_member_use
      s.choose('ham', 'p2');
      // ignore: deprecated_member_use
      s.skip('milk');
      // ignore: deprecated_member_use
      expect(s.pending().map((CartItem i) => i.key), <String>['milk']);
      expect(s.selections().map((Selection x) => x.productId), <String?>[null, 'p2', null]);
    });
  });
}
