// 0.6: one job at a time, cancelling, users, bounded waits, and the cart
// fixes. Mirrors packages/core/test/jobs.test.ts.

import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mealio_sdk/mealio_sdk.dart';

import 'support.dart';

http.Response _json(Object? body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: <String, String>{'content-type': 'application/json'});

Future<Envelope> _env(String job, int seq, List<Map<String, Object?>> ins) => signText(jsonEncode(<String, Object?>{
      'v': 1,
      'kind': 'instructions',
      'job': job,
      'seq': seq,
      'exp': 4102444800,
      'store': 'heb',
      'instructions': ins,
    }));

const Map<String, Object?> _cart = <String, Object?>{
  'cartId': 'c',
  'store': 'heb',
  'items': <Object?>[],
  'ready': <Object?>[],
  'needsChoice': <Object?>[],
  'unavailable': <Object?>[],
};
Map<String, Object?> _done(Object? result) => <String, Object?>{'op': 'done', 'id': 'd', 'result': result};
Map<String, Object?> _open(String id, [int ms = 1000]) =>
    <String, Object?>{'op': 'page_open', 'id': id, 'url': 'https://www.heb.com/robots.txt', 'timeoutMs': ms};
const Map<String, Object?> _login = <String, Object?>{
  'op': 'show_login',
  'id': 'l',
  'url': 'https://www.heb.com/login',
  'title': 'Sign in',
  'doneWhen': <Object?>[],
  'timeoutMs': 1000,
};
const Recipe _recipe = Recipe(id: 'r', ingredients: <RecipeIngredient>[RecipeIngredient(name: 'milk')]);
Future<void> _tick([int ms = 5]) => Future<void>.delayed(Duration(milliseconds: ms));

class _Sent {
  _Sent(this.path, this.body, this.auth);
  final String path;
  final Map<String, Object?>? body;
  final String? auth;
}

typedef _Answer = FutureOr<http.Response> Function(String path, Map<String, Object?>? body);

class _Setup {
  _Setup(
    _Answer answer, {
    FakeHost? host,
    Future<String> Function()? getSessionToken,
  }) {
    this.host = host ?? FakeHost();
    client = MealioClient(
      ClientConfig(
        publishableKey: 'pk',
        getSessionToken: getSessionToken ?? () async => 'tok',
        baseUrl: 'https://mealio.test',
        keys: testKeys,
        httpClient: MockClient((http.Request r) async {
          final body = r.body.isEmpty ? null : jsonDecode(r.body) as Map<String, Object?>;
          sent.add(_Sent(r.url.path, body, r.headers['Authorization']));
          return answer(r.url.path, body);
        }),
      ),
      this.host,
    );
  }

  late final MealioClient client;
  late final FakeHost host;
  final List<_Sent> sent = <_Sent>[];
  int _jobs = 0;

  Future<http.Response> start(List<Map<String, Object?>> ins) async {
    final job = 'job${++_jobs}';
    return _json(<String, Object?>{'job': job, 'envelope': (await _env(job, 1, ins)).toJson()});
  }

  List<String> get paths => sent.map((_Sent s) => s.path.replaceFirst('/api/v1/sdk', '')).toList();
}

String _jobOf(String path) => RegExp(r'jobs/([^/]+)/step').firstMatch(path)!.group(1)!;

TypeMatcher<MealioException> _code(String code) => isA<MealioException>().having((MealioException e) => e.code, 'code', code);

void main() {
  group('one job at a time', () {
    test('a second prepare waits for the first to end', () async {
      final gate = Completer<void>();
      final order = <String>[];
      late _Setup t;
      t = _Setup(
        (String p, _) async => p.endsWith('/carts') ? await t.start(<Map<String, Object?>>[_open('o'), _done(_cart)]) : _json(<String, Object?>{}),
        host: FakeHost(onOpen: (String url) async {
          order.add('open');
          await gate.future;
          order.add('opened');
          return PageLoad(ok: true, finalUrl: url);
        }),
      );
      final a = t.client.prepareCart(recipe: _recipe);
      final b = t.client.prepareCart(recipe: _recipe);
      await _tick(20);
      expect(order, <String>['open']);
      expect(t.paths, <String>['/carts']);
      gate.complete();
      await Future.wait(<Future<CartSession>>[a, b]);
      expect(order, <String>['open', 'opened', 'open', 'opened']);
    });

    test('two prepares never interleave their steps on the one page', () async {
      final calls = <String>[];
      final seqs = <String, int>{};
      late _Setup t;
      t = _Setup(
        (String p, Map<String, Object?>? body) async {
          if (p.endsWith('/carts')) {
            final who = (body!['recipe']! as Map<String, Object?>)['id']! as String;
            return _json(<String, Object?>{
              'job': who,
              'envelope': (await _env(who, 1, <Map<String, Object?>>[
                <String, Object?>{'op': 'page_open', 'id': 'open', 'url': 'https://www.heb.com/$who', 'timeoutMs': 100},
              ]))
                  .toJson(),
            });
          }
          final who = _jobOf(p);
          final n = seqs[who] = (seqs[who] ?? 1) + 1;
          final ins = n == 2
              ? <Map<String, Object?>>[
                  <String, Object?>{'op': 'page_script', 'id': 'search', 'script': 'on-$who', 'until': <Object?>[], 'timeoutMs': 100},
                ]
              : <Map<String, Object?>>[_done(_cart)];
          return _json(<String, Object?>{'envelope': (await _env(who, n, ins)).toJson()});
        },
        host: FakeHost(
          onOpen: (String u) async {
            calls.add('open $u');
            await _tick();
            return PageLoad(ok: true, finalUrl: u);
          },
          onScript: (String s, List<MessageMatcher> _) async {
            calls.add('script $s');
            await _tick();
            return const ScriptRun(messages: <JsonMessage>[], timedOut: false);
          },
        ),
      );
      await Future.wait(<Future<CartSession>>[
        t.client.prepareCart(recipe: const Recipe(id: 'first', ingredients: <RecipeIngredient>[])),
        t.client.prepareCart(recipe: const Recipe(id: 'second', ingredients: <RecipeIngredient>[])),
      ]);
      expect(calls, <String>[
        'open https://www.heb.com/first',
        'script on-first',
        'open https://www.heb.com/second',
        'script on-second',
      ]);
    });

    test('a Host that never answers ends the step at its timeout plus the grace', () async {
      List<Object?>? seen;
      late _Setup t;
      t = _Setup(
        (String p, Map<String, Object?>? b) async {
          if (p.endsWith('/carts')) {
            return await t.start(<Map<String, Object?>>[
              <String, Object?>{'op': 'page_script', 'id': 's', 'script': '', 'until': <Object?>[], 'timeoutMs': 100},
            ]);
          }
          seen = b!['results']! as List<Object?>;
          return _json(<String, Object?>{'envelope': (await _env(_jobOf(p), 2, <Map<String, Object?>>[_done(_cart)])).toJson()});
        },
        host: FakeHost(onScript: (String _, List<MessageMatcher> __) => Completer<ScriptRun>().future),
      );
      final started = DateTime.now();
      await t.client.prepareCart(recipe: _recipe);
      expect(DateTime.now().difference(started).inMilliseconds, greaterThanOrEqualTo(100 + hostGraceMs));
      expect(seen!.first, containsPair('timedOut', true));
      expect((seen!.first! as Map<String, Object?>)['messages'], isEmpty);
    }, timeout: const Timeout(Duration(seconds: 20)));

    test('after a hung job ends, a warm-up runs again', () async {
      late _Setup t;
      t = _Setup(
        (String p, _) async {
          if (p.endsWith('/carts')) return await t.start(<Map<String, Object?>>[_open('o', 50)]);
          if (p.endsWith('/warm')) return _json(<String, Object?>{'warm': null});
          return _json(<String, Object?>{'envelope': (await _env('job1', 2, <Map<String, Object?>>[_done(_cart)])).toJson()});
        },
        host: FakeHost(onOpen: (String _) => Completer<PageLoad>().future),
      );
      await t.client.prepareCart(recipe: _recipe);
      await t.client.warm();
      expect(t.paths, contains('/warm'));
    }, timeout: const Timeout(Duration(seconds: 20)));
  });

  group('bounded requests', () {
    testWidgets('a request with no answer fails as network after 30 seconds', (WidgetTester tester) async {
      final t = _Setup((String _, __) => Completer<http.Response>().future);
      Object? error;
      unawaited(t.client.storePreferences().then((_) {}, onError: (Object e) => error = e));
      await tester.pump(requestTimeout - const Duration(seconds: 1));
      expect(error, isNull);
      await tester.pump(const Duration(seconds: 2));
      expect(error, _code(MealioErrorCode.network));
    });

    test('a 200 that is not JSON is a server error, not a TypeError', () async {
      final t = _Setup((String _, __) => http.Response('<html>portal</html>', 200));
      await expectLater(t.client.prepareCart(recipe: _recipe), throwsA(_code(MealioErrorCode.server)));
      await expectLater(t.client.stores(), throwsA(_code(MealioErrorCode.server)));
    });

    test('a failed store list throws instead of reading as no stores', () async {
      final t = _Setup((String _, __) => _json(<String, Object?>{
            'error': <String, Object?>{'code': 'store_unavailable', 'message': 'down'},
          }, 503));
      await expectLater(t.client.stores(), throwsA(_code('store_unavailable')));
    });
  });

  group('session function', () {
    test('a failing one raises session_failed with its message', () async {
      final t = _Setup((String _, __) => _json(<String, Object?>{}),
          getSessionToken: () async => throw Exception('your server is down'));
      await expectLater(
        t.client.storePreferences(),
        throwsA(_code(MealioErrorCode.sessionFailed).having((MealioException e) => e.message, 'message', 'your server is down')),
      );
    });

    testWidgets('one that never answers raises session_failed', (WidgetTester tester) async {
      final t = _Setup((String _, __) => _json(<String, Object?>{}), getSessionToken: () => Completer<String>().future);
      Object? error;
      unawaited(t.client.storePreferences().then((_) {}, onError: (Object e) => error = e));
      await tester.pump(requestTimeout + const Duration(seconds: 1));
      expect(error, _code(MealioErrorCode.sessionFailed));
    });

    test('a timeout thrown inside it is session_failed, not the end of the job', () async {
      final t = _Setup((String _, __) => _json(<String, Object?>{}),
          getSessionToken: () async => throw TimeoutException('slow server'));
      await expectLater(t.client.prepareCart(recipe: _recipe), throwsA(_code(MealioErrorCode.sessionFailed)));
    });
  });

  group('cancelling', () {
    test('stops after the current step: no sign-in, nothing more sent', () async {
      final cancel = CancelToken();
      late _Setup t;
      t = _Setup(
        (String p, _) async => p.endsWith('/carts') ? await t.start(<Map<String, Object?>>[_open('o'), _login]) : _json(<String, Object?>{}),
        host: FakeHost(onOpen: (String url) async {
          cancel.cancel();
          return PageLoad(ok: true, finalUrl: url);
        }),
      );
      await expectLater(t.client.prepareCart(recipe: _recipe, cancel: cancel), throwsA(_code(MealioErrorCode.cancelled)));
      expect(t.paths, <String>['/carts']);
      expect(t.host.calls, isNot(contains('login')));
      // The queue is free again.
      await t.client.warm();
    });

    test('a cancelled job waiting in the queue never starts', () async {
      final gate = Completer<void>();
      late _Setup t;
      t = _Setup(
        (String p, _) async => p.endsWith('/carts') ? await t.start(<Map<String, Object?>>[_open('o'), _done(_cart)]) : _json(<String, Object?>{}),
        host: FakeHost(onOpen: (String url) async {
          await gate.future;
          return PageLoad(ok: true, finalUrl: url);
        }),
      );
      final a = t.client.prepareCart(recipe: _recipe);
      final cancel = CancelToken();
      final b = expectLater(t.client.prepareCart(recipe: _recipe, cancel: cancel), throwsA(_code(MealioErrorCode.cancelled)));
      cancel.cancel();
      gate.complete();
      await a;
      await b;
      expect(t.paths, <String>['/carts']);
    });

    test('a sign-in open when it is cancelled is told to close', () async {
      final cancel = CancelToken();
      late _Setup t;
      t = _Setup(
        (String p, _) async => p.endsWith('/carts') ? await t.start(<Map<String, Object?>>[_login]) : _json(<String, Object?>{}),
        host: FakeHost(onLogin: (LoginRequest r) {
          final c = Completer<LoginResult>();
          r.cancel?.onCancel(() => c.complete(const LoginResult(outcome: LoginOutcome.cancelled, messages: <JsonMessage>[])));
          return c.future;
        }),
      );
      final p = t.client.prepareCart(recipe: _recipe, cancel: cancel);
      await _tick();
      cancel.cancel();
      await expectLater(p, throwsA(_code(MealioErrorCode.cancelled)));
    });

    test('a prepare run inside runCancellable takes its token', () async {
      final cancel = CancelToken();
      late _Setup t;
      t = _Setup(
        (String p, _) async => p.endsWith('/carts') ? await t.start(<Map<String, Object?>>[_open('o'), _login]) : _json(<String, Object?>{}),
        host: FakeHost(onOpen: (String url) async {
          cancel.cancel();
          return PageLoad(ok: true, finalUrl: url);
        }),
      );
      await expectLater(
        runCancellable(cancel, () => t.client.prepareCart(recipe: _recipe)),
        throwsA(_code(MealioErrorCode.cancelled)),
      );
      expect(t.host.calls, isNot(contains('login')));
    });
  });

  group('users', () {
    test('while nobody is signed in, no session is asked for and warm does nothing', () async {
      var asked = 0;
      final t = _Setup((String _, __) => _json(<String, Object?>{'warm': null}), getSessionToken: () async {
        asked += 1;
        return 't';
      });
      t.client.setUser(null);
      await t.client.warm();
      await expectLater(t.client.prepareCart(recipe: _recipe), throwsA(_code(MealioErrorCode.notSignedIn)));
      expect(asked, 0);
      expect(t.sent, isEmpty);
    });

    test('a new user cancels a prepare, resets the session, and says to sign out of stores', () async {
      final tokens = <String>['alice', 'bob'];
      late _Setup t;
      t = _Setup(
        (String p, _) async => p.endsWith('/carts') ? await t.start(<Map<String, Object?>>[_open('o'), _done(_cart)]) : _json(<String, Object?>{}),
        host: FakeHost(onOpen: (String url) async {
          await _tick(20);
          return PageLoad(ok: true, finalUrl: url);
        }),
        getSessionToken: () async => tokens.removeAt(0),
      );
      t.client.setUser('a');
      final p = expectLater(t.client.prepareCart(recipe: _recipe), throwsA(_code(MealioErrorCode.cancelled)));
      await _tick();
      expect(t.client.setUser('b'), isTrue);
      await p;
      await t.client.storePreferences();
      expect(t.sent.map((_Sent s) => s.auth), <String>['Bearer alice', 'Bearer bob']);
      expect(t.client.setUser('b'), isFalse);
      expect(t.client.setUser(null), isTrue);
      expect(t.client.setUser('c'), isFalse);
    });

    test('an add runs on under the session it started with', () async {
      final tokens = <String>['alice', 'bob'];
      final gate = Completer<void>();
      late _Setup t;
      t = _Setup(
        (String p, _) async => p.endsWith('/add')
            ? await t.start(<Map<String, Object?>>[_open('o')])
            : _json(<String, Object?>{
                'envelope': (await _env('job1', 2, <Map<String, Object?>>[
                  _done(<String, Object?>{'added': <Object?>[]}),
                ]))
                    .toJson(),
              }),
        host: FakeHost(onOpen: (String url) async {
          await gate.future;
          return PageLoad(ok: true, finalUrl: url);
        }),
        getSessionToken: () async => tokens.removeAt(0),
      );
      t.client.setUser('a');
      final p = t.client.addToCart('c', const <Selection>[]);
      await _tick();
      t.client.setUser('b');
      gate.complete();
      await p;
      expect(t.sent.map((_Sent s) => s.auth), <String>['Bearer alice', 'Bearer alice']);
    });

    test('a warm-up that ends after a reset is not offered to the next prepare', () async {
      final gate = Completer<void>();
      late _Setup t;
      t = _Setup((String p, _) async {
        if (p.endsWith('/warm')) {
          await gate.future;
          return _json(<String, Object?>{
            'job': 'w',
            'envelope': (await _env('w', 1, <Map<String, Object?>>[
              _done(<String, Object?>{'store': 'heb', 'signedIn': true}),
            ]))
                .toJson(),
          });
        }
        return await t.start(<Map<String, Object?>>[_done(_cart)]);
      });
      final w = t.client.warm();
      await _tick();
      t.client.resetSession();
      gate.complete();
      await w;
      await t.client.prepareCart(store: 'heb', recipe: _recipe);
      expect(t.sent.firstWhere((_Sent s) => s.path.endsWith('/carts')).body!.containsKey('warm'), isFalse);
    });
  });

  group('cart session', () {
    Map<String, Object?> prod(Map<String, Object?> o) => <String, Object?>{'id': 'p', 'name': 'P', ...o};
    Map<String, Object?> item(Map<String, Object?> o) => <String, Object?>{
          'key': 'k',
          'ingredient': 'x',
          'quantity': 1,
          'status': 'remembered',
          'options': <Object?>[],
          'selectedId': 'p',
          'remembered': null,
          ...o,
        };
    CartSession session(List<Map<String, Object?>> items, {MealioClient? client, String store = 'heb', Object? warnings}) =>
        CartSession(
          client ?? _Setup((String _, __) => _json(<String, Object?>{})).client,
          PreparedCart.fromJson(<String, Object?>{
            'cartId': 'c',
            'store': store,
            'items': items,
            if (warnings != null) 'warnings': warnings,
          }),
        );

    test('shows the quantity it sends, under the cap, also after switching product', () {
      final c = session(<Map<String, Object?>>[
        item(<String, Object?>{
          'quantity': 8,
          'options': <Object?>[prod(<String, Object?>{'unitPrice': 2, 'maxQuantity': 5})],
        }),
      ]);
      expect(c.quantity('k'), 5);
      expect(c.selections().first.quantity, 5);
      final d = session(<Map<String, Object?>>[
        item(<String, Object?>{
          'selectedId': 'a',
          'options': <Object?>[
            prod(<String, Object?>{'id': 'a', 'unitPrice': 2}),
            prod(<String, Object?>{'id': 'b', 'unitPrice': 2, 'maxQuantity': 3}),
          ],
        }),
      ]);
      d.setQuantity('k', 10);
      d.select('k', 'b');
      expect(d.quantity('k'), 3);
      expect(d.selections().first.quantity, 3);
      expect(d.setQuantity('k', d.quantity('k') - 1), 2);
    });

    test('the list total and the done total agree to the cent', () {
      Map<String, Object?> lb(String key) => item(<String, Object?>{
            'key': key,
            'weightLb': 0.25,
            'options': <Object?>[prod(<String, Object?>{'soldByWeight': true, 'pricePerLb': 3.33})],
          });
      final c = session(<Map<String, Object?>>[lb('a'), lb('b')]);
      final added = <AddedItem>[
        for (final String key in <String>['a', 'b'])
          AddedItem(key: key, productId: 'p', name: 'P', quantity: 1, weightLb: 0.25, pricePerLb: 3.33),
      ];
      expect(c.estimate().total, 1.66);
      expect(c.addedTotal(AddResult.fromJson(<String, Object?>{
        'cartId': 'c',
        'store': 'heb',
        'added': added.map((AddedItem a) => a.toJson()).toList(),
        'failed': <Object?>[],
        'skipped': <Object?>[],
      })).total, 1.66);
    });

    test('a second add while one runs returns the same future', () async {
      final gate = Completer<void>();
      late _Setup t;
      t = _Setup(
        (String p, _) async => await t.start(<Map<String, Object?>>[_open('o'), _done(<String, Object?>{'added': <Object?>[]})]),
        host: FakeHost(onOpen: (String url) async {
          await gate.future;
          return PageLoad(ok: true, finalUrl: url);
        }),
      );
      final c = session(const <Map<String, Object?>>[], client: t.client);
      final a = c.addToCart();
      expect(identical(c.addToCart(), a), isTrue);
      gate.complete();
      await a;
      expect(t.paths.where((String p) => p.endsWith('/add')), hasLength(1));
    });

    test('knows when a search runs, and cancels it', () async {
      late _Setup t;
      t = _Setup(
        (String p, _) async => await t.start(<Map<String, Object?>>[_login]),
        host: FakeHost(onLogin: (LoginRequest r) {
          final c = Completer<LoginResult>();
          r.cancel?.onCancel(() => c.complete(const LoginResult(outcome: LoginOutcome.cancelled, messages: <JsonMessage>[])));
          return c.future;
        }),
      );
      final c = session(<Map<String, Object?>>[item(const <String, Object?>{})], client: t.client);
      final p = c.search('k', 'milk');
      expect(c.searching, isTrue);
      await _tick(20);
      c.cancelSearches();
      await expectLater(p, throwsA(_code(MealioErrorCode.cancelled)));
      expect(c.searching, isFalse);
    });

    test('restores picks from a failed add where the product is still offered', () {
      final opts = <Object?>[
        prod(<String, Object?>{
          'id': 'p1',
          'maxQuantity': 9,
          'preferences': <Object?>[
            <String, Object?>{'id': 'sl', 'label': 'Sliced'},
          ],
        }),
        prod(<String, Object?>{'id': 'p2'}),
      ];
      List<Map<String, Object?>> items(String cId) => <Map<String, Object?>>[
            item(<String, Object?>{'key': 'a', 'options': opts, 'selectedId': 'p1'}),
            item(<String, Object?>{'key': 'b', 'options': opts, 'selectedId': 'p1'}),
            item(<String, Object?>{
              'key': 'c',
              'options': <Object?>[prod(<String, Object?>{'id': cId})],
              'selectedId': cId,
            }),
          ];
      final old = session(items('gone'));
      old.select('a', 'p2');
      old.setQuantity('a', 4);
      old.deselect('b');
      old.select('c', 'gone');
      final fresh = session(items('new'));
      fresh.restorePicks(old);
      expect(<Object?>[fresh.selectedId('a'), fresh.quantity('a'), fresh.isSelected('b'), fresh.selectedId('c')],
          <Object?>['p2', 4, false, 'new']);
      final elsewhere = session(<Map<String, Object?>>[
        item(<String, Object?>{'key': 'a', 'options': opts, 'selectedId': 'p1'}),
      ], store: 'walmart');
      elsewhere.restorePicks(old);
      expect(elsewhere.selectedId('a'), 'p1');
    });

    test('exposes server warnings, and none from older servers', () {
      final c = session(const <Map<String, Object?>>[], warnings: <Object?>[
        <String, Object?>{'code': 'lines_dropped', 'message': 'Two lines were empty.'},
      ]);
      expect(c.warnings.map((CartWarning w) => '${w.code}: ${w.message}'), <String>['lines_dropped: Two lines were empty.']);
      expect(session(const <Map<String, Object?>>[]).warnings, isEmpty);
    });
  });

  group('blocked mutations', () {
    test('names a mutation and its root fields, and nothing of a query', () {
      expect(
        mutationNames('mutation Go(\$a: ID!) { x: placeOrder(id: \$a, note: "checkout") { ... on Err { message } } } # payment'),
        <String>['Go', 'placeOrder'],
      );
      expect(mutationNames('query Q { paymentMethods { id } }'), isEmpty);
    });

    test('judges only a mutation root: nested fields and aliases pass, root fields block', () {
      expect(
        mutationNames('mutation AddToCart { addItemsToCart { cart { items { maxPurchaseQuantity } } } }'),
        <String>['AddToCart', 'addItemsToCart'],
      );
      expect(
        mutationNames('mutation { a: placeOrder { id } ... on Mutation { ...F } } fragment F on Mutation { checkout { id } }'),
        <String>['placeOrder', 'checkout'],
      );
      expect(mutationNames('mutation M { a { b(note: "say \\"placeOrder\\"") } } # checkout'), <String>['M', 'a']);
      expect(mutationNames('mutation M { x(d: """ a \\""" placeOrder { """) { id } }'), <String>['M', 'x']);
    });

    test('a multipart body is judged by its operations field', () {
      expect(bodyBlocked('operations=${Uri.encodeQueryComponent('{"query":"mutation { placeOrder { id } }"}')}&map=%7B%7D'), isTrue);
      expect(bodyBlocked('operations=${Uri.encodeQueryComponent('{"query":"mutation { addItemsToCart { id } }"}')}'), isFalse);
    });

    test('the runner refuses a fetch whose body names a blocked mutation', () async {
      final host = FakeHost();
      final env = await signInstructions(<Map<String, Object?>>[
        <String, Object?>{
          'op': 'fetch',
          'id': 'f',
          'request': <String, Object?>{
            'method': 'POST',
            'url': 'https://www.heb.com/graphql',
            'body': '{"query":"mutation Go { submitOrder { id } }"}',
          },
          'timeoutMs': 1000,
          'maxBytes': 1000,
        },
      ]);
      final out = await Runner(host, keys: testKeys).run(env, 'job_test', 0);
      expect(out.results.single.error, 'blocked');
      expect(host.calls, isEmpty);
    });
  });
}
