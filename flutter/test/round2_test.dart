// 0.6 round 2: session tokens across a user change, the exclusive queue,
// the drop-in sheet's props, cancel and hide, restorePicks after a search,
// the per-run bridge nonce, and the partner test helpers.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mealio_sdk/mealio_sdk.dart';
import 'package:mealio_sdk/testing.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart' as wv;

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

Map<String, Object?> _open(String id) =>
    <String, Object?>{'op': 'page_open', 'id': id, 'url': 'https://www.heb.com/robots.txt', 'timeoutMs': 1000};
Map<String, Object?> _done(Object? result) => <String, Object?>{'op': 'done', 'id': 'd', 'result': result};
const Map<String, Object?> _added = <String, Object?>{'store': 'heb', 'added': <Object?>[], 'failed': <Object?>[]};
const Recipe _recipe = Recipe(id: 'r', title: 'Tacos', ingredients: <RecipeIngredient>[RecipeIngredient(name: 'onion')]);
Future<void> _tick([int ms = 5]) => Future<void>.delayed(Duration(milliseconds: ms));
TypeMatcher<MealioException> _code(String code) => isA<MealioException>().having((MealioException e) => e.code, 'code', code);

class _Sent {
  _Sent(this.path, this.body, this.auth);
  final String path;
  final Map<String, Object?>? body;
  final String? auth;
}

/// A client on a fake host, recording what it sends.
class _Setup {
  _Setup(
    FutureOr<http.Response> Function(_Setup t, String path) answer, {
    FakeHost? host,
    Future<String> Function()? getSessionToken,
  }) {
    client = MealioClient(
      ClientConfig(
        publishableKey: 'pk',
        getSessionToken: getSessionToken ?? () async => 'tok',
        baseUrl: 'https://mealio.test',
        keys: testKeys,
        httpClient: MockClient((http.Request r) async {
          final body = r.body.isEmpty ? null : jsonDecode(r.body) as Map<String, Object?>;
          sent.add(_Sent(r.url.path, body, r.headers['Authorization']));
          return answer(this, r.url.path);
        }),
      ),
      host ?? FakeHost(),
    );
  }

  late final MealioClient client;
  final List<_Sent> sent = <_Sent>[];
  int _jobs = 0;

  Future<http.Response> start(List<Map<String, Object?>> ins) async {
    final job = 'job${++_jobs}';
    return _json(<String, Object?>{'job': job, 'envelope': (await _env(job, 1, ins)).toJson()});
  }

  Iterable<String> get paths => sent.map((_Sent s) => s.path);
}

/// One remembered item, so an add has something to send.
Map<String, Object?> _cartJson({String key = 'onion', List<Map<String, Object?>>? options}) => <String, Object?>{
      'cartId': 'c1',
      'store': 'heb',
      'storeName': 'H-E-B',
      'items': <Object?>[
        <String, Object?>{
          'key': key,
          'ingredient': key,
          'quantity': 1,
          'status': 'remembered',
          'selectedId': 'o1',
          'remembered': <String, Object?>{'id': 'o1', 'name': 'Yellow Onion'},
          'options': options ??
              <Object?>[
                <String, Object?>{'id': 'o1', 'name': 'Yellow Onion', 'price': r'$1.25', 'unitPrice': 1.25},
              ],
        },
      ],
    };

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

/// The SDK's queue, probed the way the partner trial did.
Future<String> _queueProbe(WidgetTester tester) async {
  MealioCart.configure(publishableKey: 'pk', sessionTokenProvider: () async => 't');
  var state = 'stuck';
  unawaited(MealioCart.instance.client.runExclusive((_) async => 1).then((_) => state = 'ran'));
  await tester.pump(const Duration(seconds: 1));
  return state;
}

void main() {
  // F5: a static queue must not keep a future from a finished test's zone.
  group('the shared job queue across widget tests', () {
    testWidgets('first test: a job runs', (WidgetTester tester) async {
      expect(await _queueProbe(tester), 'ran');
    });
    testWidgets('second test: a job still runs', (WidgetTester tester) async {
      expect(await _queueProbe(tester), 'ran');
    });
  });

  group('session tokens and a user change (items 1, 2)', () {
    test('a prepare waiting for its token is cancelled by a user change and sends nothing', () async {
      final gate = Completer<String>();
      var asked = 0;
      final t = _Setup((_Setup t, String p) => _json(<String, Object?>{}), getSessionToken: () {
        asked += 1;
        return asked == 1 ? gate.future : Future<String>.value('tokB');
      });
      t.client.setUser('A');
      final prep = t.client.prepareCart(recipe: _recipe);
      await _tick();
      t.client.setUser('B');
      gate.complete('tokA');
      await expectLater(prep, throwsA(_code(MealioErrorCode.cancelled)));
      expect(asked, 1, reason: "never fetches the next user's token for it");
      expect(t.sent, isEmpty);
    });

    test('signing out while a prepare waits for its token is cancelled, not not_signed_in', () async {
      final gate = Completer<String>();
      final t = _Setup((_Setup t, String p) => _json(<String, Object?>{}), getSessionToken: () => gate.future);
      t.client.setUser('A');
      final prep = t.client.prepareCart(recipe: _recipe);
      await _tick();
      t.client.setUser(null);
      gate.complete('tokA');
      await expectLater(prep, throwsA(_code(MealioErrorCode.cancelled)));
      expect(t.sent, isEmpty);
    });

    test('an add whose step gets 401 after a user change fails with session_expired on its own token', () async {
      final gate = Completer<void>();
      var tokenFor = 'A';
      var steps = 0;
      final t = _Setup(
        (_Setup t, String p) async {
          if (p.endsWith('/add')) return t.start(<Map<String, Object?>>[_open('o')]);
          if (p.contains('/step')) {
            steps += 1;
            if (steps == 1) return _json(<String, Object?>{}, 401);
            return _json(<String, Object?>{
              'envelope': (await _env('job1', 2, <Map<String, Object?>>[_done(_added)])).toJson(),
            });
          }
          return _json(<String, Object?>{});
        },
        getSessionToken: () async => 'tok$tokenFor',
        host: FakeHost(onOpen: (String url) async {
          await gate.future;
          return PageLoad(ok: true, finalUrl: url);
        }),
      );
      t.client.setUser('A');
      final add = t.client.addToCart('c', <Selection>[]);
      await _tick(20);
      tokenFor = 'B';
      t.client.setUser('B');
      gate.complete();
      await expectLater(add, throwsA(_code(MealioErrorCode.sessionExpired)));
      expect(t.sent.map((_Sent s) => s.auth).toSet(), <String>{'Bearer tokA'});
    });

    test('an add tapped behind a warm-up keeps the session it was tapped under', () async {
      final gate = Completer<void>();
      var tokenFor = 'A';
      final t = _Setup(
        (_Setup t, String p) async {
          if (p.endsWith('/warm')) {
            return t.start(<Map<String, Object?>>[_open('w'), _done(<String, Object?>{'store': 'heb', 'signedIn': true})]);
          }
          if (p.endsWith('/add')) return t.start(<Map<String, Object?>>[_done(_added)]);
          return _json(<String, Object?>{});
        },
        getSessionToken: () async => 'tok$tokenFor',
        host: FakeHost(onOpen: (String url) async {
          await gate.future;
          return PageLoad(ok: true, finalUrl: url);
        }),
      );
      t.client.setUser('A');
      unawaited(t.client.warm());
      await _tick(20);
      final add = t.client.addToCart('c', <Selection>[]);
      tokenFor = 'B';
      t.client.setUser('B');
      gate.complete();
      await add;
      expect(t.sent.firstWhere((_Sent s) => s.path.endsWith('/add')).auth, 'Bearer tokA');
    });

    test('with no user change, an add retries a 401 with a fresh token for the same user', () async {
      var n = 0;
      final t = _Setup(
        (_Setup t, String p) async {
          if (p.endsWith('/add')) {
            return t.sent.where((_Sent s) => s.path.endsWith('/add')).length == 1
                ? _json(<String, Object?>{}, 401)
                : await t.start(<Map<String, Object?>>[_done(_added)]);
          }
          return _json(<String, Object?>{});
        },
        getSessionToken: () async => 'tok${++n}',
      );
      t.client.setUser('A');
      await t.client.addToCart('c', <Selection>[]);
      expect(t.sent.map((_Sent s) => s.auth), <String>['Bearer tok1', 'Bearer tok2']);
    });
  });

  // F1, item 4.
  testWidgets('runExclusive reports a timeout but holds the queue until its work ends', (WidgetTester tester) async {
    final t = _Setup((_Setup t, String p) => _json(<String, Object?>{}));
    final events = <String>[];
    final release = Completer<void>();
    Object? error;
    unawaited(t.client.runExclusive((_) async {
      events.add('first start');
      await release.future;
      events.add('first end');
    }).catchError((Object e) {
      error = e;
    }));
    unawaited(t.client.runExclusive((_) async => events.add('second')));
    await tester.pump(const Duration(seconds: 31));
    expect(error, _code(MealioErrorCode.network));
    expect(events, <String>['first start']);
    release.complete();
    await tester.pump();
    expect(events, <String>['first start', 'first end', 'second']);
  });

  // Item 7.
  test('restorePicks keeps a product found with search, and its quantity', () async {
    final found = await signInstructions(<Map<String, Object?>>[
      _done(<String, Object?>{
        'key': 'onion',
        'query': 'sweet',
        'options': <Object?>[
          <String, Object?>{'id': 'o9', 'name': 'Sweet Onion', 'price': r'$2.00', 'unitPrice': 2},
        ],
      }),
    ]);
    final t = _Setup((_Setup t, String p) => _json(<String, Object?>{'job': 'job_test', 'envelope': found.toJson()}));
    final old = CartSession(t.client, PreparedCart.fromJson(_cartJson()));
    await old.search('onion', 'sweet');
    old.select('onion', 'o9');
    old.setQuantity('onion', 3);
    final next = CartSession(t.client, PreparedCart.fromJson(_cartJson()));
    await next.restorePicks(old);
    expect(next.selectedId('onion'), 'o9');
    expect(next.quantity('onion'), 3);
    expect(next.options('onion').map((Product p) => p.id), contains('o9'));
  });

  // F4.
  test("a late message from the last script's run cannot answer the next", () async {
    installMealioTestPlatform();
    final h = WebViewHost();
    final c = MealioFakeWebViewController.all.last;
    String nonceIn(String script) => RegExp(r'n: "([0-9a-f]+)"').firstMatch(script)!.group(1)!;
    void post(String nonce, Map<String, Object?> m) => c.channel!
        .onMessageReceived(wv.JavaScriptMessage(message: jsonEncode(<String, Object?>{'n': nonce, 'm': jsonEncode(m)})));

    final first = h.runScript('heb', '/*g*/', '/*one*/', const <MessageMatcher>[MessageMatcher(type: 'A')], 2000);
    await _tick();
    final one = nonceIn(c.scripts.lastWhere((String s) => s.contains('__mealioNativePost')));
    post(one, <String, Object?>{'type': 'A'});
    expect((await first).timedOut, isFalse);

    final second = h.runScript('heb', '/*g*/', '/*two*/', const <MessageMatcher>[MessageMatcher(type: 'RESULT')], 2000);
    await _tick();
    final two = nonceIn(c.scripts.lastWhere((String s) => s.contains('__mealioNativePost')));
    // The first script, still running, posts late through the poster it held.
    post(one, <String, Object?>{'type': 'RESULT', 'from': 'one'});
    post(two, <String, Object?>{'type': 'RESULT', 'from': 'two'});
    final run = await second;
    expect(run.messages.map((JsonMessage m) => m['from']), <Object?>['two']);
  });

  group('the drop-in sheet', () {
    late List<_Sent> sent;
    late FutureOr<http.Response> Function(String path) answer;

    Future<void> configure(WidgetTester tester) async {
      sent = <_Sent>[];
      answer = (String _) => mealioTestErrorResponse();
      installMealioTestPlatform();
      configureMealioForTesting(
        httpClient: MockClient((http.Request r) async {
          sent.add(_Sent(r.url.path, r.body.isEmpty ? null : jsonDecode(r.body) as Map<String, Object?>, null));
          return answer(r.url.path);
        }),
      );
    }

    Widget app(Widget home) {
      final nav = GlobalKey<NavigatorState>();
      return MaterialApp(
        navigatorKey: nav,
        builder: (BuildContext c, Widget? child) => MealioScope(navigatorKey: nav, child: child!),
        home: Scaffold(body: Center(child: home)),
      );
    }

    List<Object?> cartStores() =>
        sent.where((_Sent s) => s.path.endsWith('/sdk/carts')).map((_Sent s) => s.body?['store']).toList();

    // F2, and the helpers in package:mealio_sdk/testing.dart.
    testWidgets("a store change on the button reaches the open sheet's Try again", (WidgetTester tester) async {
      _phone(tester);
      await configure(tester);
      final store = ValueNotifier<String>('heb');
      await tester.pumpWidget(app(ValueListenableBuilder<String>(
        valueListenable: store,
        builder: (BuildContext _, String s, Widget? __) => MealioCartButton(recipe: _recipe, store: s),
      )));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MealioCartButton));
      await tester.pumpAndSettle();
      expect(find.text('Try again'), findsOneWidget);
      expect(cartStores(), <Object?>['heb']);

      store.value = 'kroger';
      await tester.pumpAndSettle();
      await tester.tap(find.text('Try again'));
      await tester.pumpAndSettle();
      expect(cartStores(), <Object?>['heb', 'kroger']);
    });

    // Item 5.
    testWidgets('a prepare cancelled by cancelJobs while the sheet is open starts again, with no error',
        (WidgetTester tester) async {
      _phone(tester);
      await configure(tester);
      final errors = <Object>[];
      await tester.pumpWidget(app(MealioCartButton(recipe: _recipe, store: 'heb', onError: errors.add)));
      await tester.pumpAndSettle();
      // Something else holds the page, so the prepare waits in the queue.
      final hold = Completer<void>();
      unawaited(MealioCart.instance.client.runExclusive((_) => hold.future));
      await tester.tap(find.byType(MealioCartButton));
      await tester.pump();
      MealioCart.instance.cancelJobs();
      hold.complete();
      await tester.pumpAndSettle();
      // Started again: it reached Mealio, whose test answer is an error.
      expect(cartStores(), <Object?>['heb']);
      expect(errors.map((Object e) => (e as MealioException).code), <String>[MealioErrorCode.server]);
      expect(find.text('Try again'), findsOneWidget);
    });

    // F3.
    testWidgets('configure again keeps the user, and the button follows the new instance', (WidgetTester tester) async {
      _phone(tester);
      await configure(tester);
      MealioCart.instance.setUser('u1');
      await tester.pumpWidget(app(const MealioCartButton(recipe: _recipe, store: 'heb')));
      await tester.pumpAndSettle();
      bool enabled() =>
          tester.widget<InkWell>(find.descendant(of: find.byType(MealioCartButton), matching: find.byType(InkWell))).onTap !=
          null;
      expect(enabled(), isTrue);

      configureMealioForTesting(httpClient: MockClient((http.Request _) async => mealioTestErrorResponse()));
      expect(MealioCart.instance.userId, 'u1');
      expect(MealioCart.instance.hasUser, isTrue);

      MealioCart.instance.setUser(null);
      await tester.pumpAndSettle();
      expect(enabled(), isFalse, reason: 'nobody signed in and no onSignInRequired');
    });

    // F6: the README's example.
    testWidgets('with the test helpers, a signed-out tap calls onSignInRequired', (WidgetTester tester) async {
      _phone(tester);
      installMealioTestPlatform();
      var signInShown = false;
      configureMealioForTesting(onSignInRequired: () => signInShown = true);
      await tester.pumpWidget(app(const MealioCartButton(recipe: _recipe)));
      MealioCart.instance.setUser(null);
      await tester.pump();
      await tester.tap(find.byType(MealioCartButton));
      expect(signInShown, isTrue);
      MealioCart.instance.setUser('u');
      await tester.pumpAndSettle();
      await tester.tap(find.byType(MealioCartButton));
      await tester.pumpAndSettle();
      expect(find.text('Try again'), findsOneWidget);
    });

    // Item 6.
    testWidgets('a sheet hidden during an add still reports the add through onAdded and onClose',
        (WidgetTester tester) async {
      _phone(tester);
      installMealioTestPlatform();
      final done = await tester.runAsync(() => signInstructions(<Map<String, Object?>>[
            _done(<String, Object?>{
              'cartId': 'c1',
              'store': 'heb',
              'added': <Object?>[
                <String, Object?>{'key': 'onion', 'productId': 'o1', 'name': 'Yellow Onion', 'quantity': 1},
              ],
              'failed': <Object?>[],
            }),
          ]));
      final gate = Completer<void>();
      final client = MealioClient(
        ClientConfig(
          publishableKey: 'pk',
          getSessionToken: () async => 't',
          keys: testKeys,
          httpClient: MockClient((http.Request r) async {
            await gate.future;
            return _json(<String, Object?>{'job': 'job_test', 'envelope': done!.toJson()});
          }),
        ),
        FakeHost(),
      );
      AddResult? added;
      AddResult? closedWith;
      var closes = 0;
      AddResult? shown;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (BuildContext context) => TextButton(
            onPressed: () async {
              shown = await MealioCartFlow.show(
                context,
                recipe: _recipe,
                store: 'heb',
                onAdded: (AddResult r) => added = r,
                onClose: (AddResult? r) {
                  closes += 1;
                  closedWith = r;
                },
                prepareCart: ({String? store, required Recipe recipe, String? zip, StepListener? onStep}) async =>
                    CartSession(client, PreparedCart.fromJson(_cartJson())),
              );
            },
            child: const Text('open'),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Add 1 item to H-E-B'));
      await tester.pump();
      // The partner hides the sheet while the add runs.
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      expect(closes, 0, reason: 'onClose waits for the add');
      gate.complete();
      await tester.pumpAndSettle();
      expect(added?.added.single.key, 'onion');
      expect(closes, 1);
      expect(closedWith?.added.single.key, 'onion');
      expect(shown, same(closedWith));
    });
  });
}
