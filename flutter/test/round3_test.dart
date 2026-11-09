// 0.6 round 3: restorePicks searches again on the new cart, nothing waits
// forever (store sign-out steps, the exclusive cap, a cancel in the queue),
// capped restarts after an outside cancel, `cancelled` wins over a failed
// session fetch, and the reason a call was cancelled.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mealio_sdk/mealio_sdk.dart';
import 'package:mealio_sdk/testing.dart';

import 'support.dart';

http.Response _json(Object? body, [int status = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(body)), status, headers: <String, String>{'content-type': 'application/json'});

Future<http.Response> _job(Object? result) async {
  final env = await signInstructions(<Map<String, Object?>>[
    <String, Object?>{'op': 'done', 'id': 'd', 'result': result},
  ]);
  return _json(<String, Object?>{'job': 'job_test', 'envelope': env.toJson()});
}

Map<String, Object?> _searchResult(String query, List<String> ids) => <String, Object?>{
      'key': 'onion',
      'query': query,
      'options': <Object?>[
        for (final String id in ids) <String, Object?>{'id': id, 'name': 'Onion $id', 'price': r'$2.00', 'unitPrice': 2},
      ],
    };

PreparedCart _cart(String id) => PreparedCart.fromJson(<String, Object?>{
      'cartId': id,
      'store': 'heb',
      'items': <Object?>[
        <String, Object?>{
          'key': 'onion',
          'ingredient': 'onion',
          'quantity': 1,
          'status': 'remembered',
          'selectedId': 'o1',
          'options': <Object?>[
            <String, Object?>{'id': 'o1', 'name': 'Yellow Onion', 'price': r'$1.25', 'unitPrice': 1.25},
          ],
        },
      ],
    });

const Recipe _recipe = Recipe(id: 'r', title: 'Tacos', ingredients: <RecipeIngredient>[RecipeIngredient(name: 'onion')]);

TypeMatcher<MealioException> _cancelled(String reason) => isA<MealioException>()
    .having((MealioException e) => e.code, 'code', MealioErrorCode.cancelled)
    .having((MealioException e) => e.reason, 'reason', reason);

/// A fake host that can reset its page, recording it.
class _ResettingHost extends FakeHost implements MealioPageReset {
  @override
  Future<void> resetPage() async => calls.add('reset');
}

MealioClient _client(
  FutureOr<http.Response> Function(String path) answer, {
  Future<String> Function()? token,
  MealioHost? host,
  List<String>? paths,
}) =>
    MealioClient(
      ClientConfig(
        publishableKey: 'pk',
        getSessionToken: token ?? () async => 'tok',
        baseUrl: 'https://mealio.test',
        keys: testKeys,
        httpClient: MockClient((http.Request r) async {
          paths?.add(r.url.path);
          return answer(r.url.path);
        }),
      ),
      host ?? FakeHost(),
    );

/// A few frames, for the sheet to open and its prepare to reach the queue.
Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 5; i++) {
    await tester.pump(const Duration(milliseconds: 20));
  }
}

void _phone(WidgetTester tester) {
  tester.view.physicalSize = const Size(390, 844);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}

Widget _app(Widget home) {
  final nav = GlobalKey<NavigatorState>();
  return MaterialApp(
    navigatorKey: nav,
    builder: (BuildContext c, Widget? child) => MealioScope(navigatorKey: nav, child: child!),
    home: Scaffold(body: Center(child: home)),
  );
}

void main() {
  group('restorePicks with a searched pick (item 1)', () {
    test('runs the last search again on the new cart and selects the same product with its quantity', () async {
      final paths = <String>[];
      final client = _client((String p) => _job(_searchResult('sweet', <String>['o9'])), paths: paths);
      final old = CartSession(client, _cart('c1'));
      await old.search('onion', 'sweet');
      old.select('onion', 'o9');
      old.setQuantity('onion', 3);
      paths.clear();

      final next = CartSession(client, _cart('c2'));
      await next.restorePicks(old);
      expect(paths, <String>['/api/v1/sdk/carts/c2/search']);
      expect(next.selectedId('onion'), 'o9');
      expect(next.quantity('onion'), 3);
    });

    test('when the search does not bring the product back, the item keeps the new cart pick', () async {
      var answer = _searchResult('sweet', <String>['o9']);
      final client = _client((String p) => _job(answer));
      final old = CartSession(client, _cart('c1'));
      await old.search('onion', 'sweet');
      old.select('onion', 'o9');
      answer = _searchResult('sweet', <String>['o7']);

      final next = CartSession(client, _cart('c2'));
      await next.restorePicks(old);
      expect(next.selectedId('onion'), 'o1');
      expect(next.selections().map((Selection s) => s.productId), <String?>['o1']);
      expect(next.options('onion').map((Product p) => p.id), isNot(contains('o9')));
    });

    test('a failed search leaves the item on the new cart pick, and nothing unoffered is sent', () async {
      var fail = false;
      final client = _client((String p) async => fail ? _json(<String, Object?>{}, 500) : await _job(_searchResult('sweet', <String>['o9'])));
      final old = CartSession(client, _cart('c1'));
      await old.search('onion', 'sweet');
      old.select('onion', 'o9');
      fail = true;
      final next = CartSession(client, _cart('c2'));
      await next.restorePicks(old);
      expect(next.selectedId('onion'), 'o1');
    });
  });

  group('nothing waits forever (items 2, 8)', () {
    testWidgets('store sign-out gives each platform call 10 seconds', (WidgetTester tester) async {
      installMealioTestPlatform();
      configureMealioForTesting();
      await tester.pumpWidget(_app(const SizedBox()));
      final page = MealioFakeWebViewController.all.last;
      MealioFakeCookieManager.onClear = () => Completer<bool>().future;
      MealioFakeWebViewController.hangLoadOn = 'about:blank';
      var done = false;
      Object? error;
      unawaited(MealioCart.instance.signOutOfAllStores().then((_) => done = true, onError: (Object e) => error = e));
      await tester.pump(const Duration(seconds: 9));
      expect(done, isFalse);
      await tester.pump(const Duration(seconds: 12));
      expect(page.loads.last, 'about:blank');
      expect(done, isTrue, reason: 'cookie clearing and the blank load each gave up after 10 seconds');
      expect(error, isNull);
      expect(await MealioCart.storeEpoch(), 1);
      // The queue moved on.
      var next = false;
      unawaited(MealioCart.instance.client.runExclusive((_) async => next = true));
      await tester.pump();
      expect(next, isTrue);
    });

    testWidgets('clearStoreSessions starts no step after its cancel fired', (WidgetTester tester) async {
      installMealioTestPlatform();
      final host = WebViewHost();
      final page = MealioFakeWebViewController.all.last;
      await host.clearStoreSessions(cancel: CancelToken()..cancel());
      expect(MealioFakeCookieManager.clears, 0);
      expect(page.loads, isEmpty);
    });

    testWidgets('exclusive work holds the queue 60 seconds at most; the next job resets the page first',
        (WidgetTester tester) async {
      final host = _ResettingHost();
      final client = _client((String p) => _job(<String, Object?>{'cartId': 'c', 'store': 'heb', 'items': <Object?>[]}),
          host: host);
      CancelToken? given;
      unawaited(client.runExclusive((CancelToken c) {
        given = c;
        return Completer<void>().future;
      }).then((_) {}, onError: (Object _) {}));
      var prepared = false;
      unawaited(client.prepareCart(recipe: _recipe).then((_) => prepared = true));
      await tester.pump(const Duration(seconds: 59));
      expect(prepared, isFalse);
      expect(host.calls, isEmpty);
      await tester.pump(const Duration(seconds: 2));
      await tester.pump();
      expect(given!.cancelled, isTrue);
      expect(prepared, isTrue);
      expect(host.calls.first, 'reset');
      // Only once.
      unawaited(client.prepareCart(recipe: _recipe));
      await tester.pump();
      expect(host.calls.where((String c) => c == 'reset'), hasLength(1));
    });

    testWidgets('a job cancelled while it waits in the queue settles at once', (WidgetTester tester) async {
      final client = _client((String p) => _json(<String, Object?>{}));
      final hold = Completer<void>();
      unawaited(client.runExclusive((_) => hold.future));
      final cancel = CancelToken();
      Object? error;
      unawaited(client.prepareCart(recipe: _recipe, cancel: cancel).then((_) {}, onError: (Object e) => error = e));
      await tester.pump();
      cancel.cancel();
      await tester.pump();
      expect(error, _cancelled(MealioCancelReason.cancelled));
      hold.complete();
    });
  });

  group('restarts after an outside cancel (item 3)', () {
    late List<String> carts;

    void configure() {
      carts = <String>[];
      installMealioTestPlatform();
      configureMealioForTesting(
        httpClient: MockClient((http.Request r) async {
          if (r.url.path.endsWith('/sdk/carts')) carts.add(r.url.path);
          return mealioTestErrorResponse();
        }),
      );
    }

    testWidgets('restart at most 3 times in a row, then the error screen; Try again resets the count',
        (WidgetTester tester) async {
      _phone(tester);
      configure();
      final errors = <Object>[];
      await tester.pumpWidget(_app(MealioCartButton(recipe: _recipe, store: 'heb', onError: errors.add)));
      await tester.pumpAndSettle();
      final hold = Completer<void>();
      unawaited(MealioCart.instance.client.runExclusive((_) => hold.future));
      await tester.tap(find.byType(MealioCartButton));
      await _frames(tester);

      Future<void> outsideCancel() async {
        MealioCart.instance.cancelJobs();
        await _frames(tester);
      }

      for (var i = 0; i < 3; i++) {
        await outsideCancel();
      }
      expect(find.text('Try again'), findsNothing, reason: 'three restarts so far');
      await outsideCancel();
      expect(find.text('Try again'), findsOneWidget);
      expect(errors.map((Object e) => (e as MealioException).code), <String>[MealioErrorCode.cancelled]);
      expect(find.byType(MealioCartFlow), findsOneWidget, reason: 'the sheet stays open');

      await tester.tap(find.text('Try again'));
      await _frames(tester);
      for (var i = 0; i < 3; i++) {
        await outsideCancel();
      }
      expect(find.text('Try again'), findsNothing, reason: 'the count started over');
      hold.complete();
      await tester.pumpAndSettle();
      expect(carts, hasLength(1));
    });

    testWidgets('resetSession during the session fetch starts the cart again', (WidgetTester tester) async {
      _phone(tester);
      installMealioTestPlatform();
      final gate = Completer<String>();
      var calls = 0;
      final errors = <Object>[];
      configureMealioForTesting(sessionTokenProvider: () {
        calls += 1;
        return calls == 1 ? gate.future : Future<String>.value('tok2');
      });
      // MealioCartFlow.show, not the button: no warm-up asks for a token first.
      await tester.pumpWidget(_app(Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () => MealioCartFlow.show(context, recipe: _recipe, store: 'heb', onError: errors.add),
          child: const Text('open'),
        ),
      )));
      await tester.tap(find.text('open'));
      await _frames(tester);
      expect(calls, 1);
      MealioCart.instance.resetSession();
      gate.complete('tok1');
      await tester.pumpAndSettle();
      expect(calls, 2);
      // It reached Mealio, whose test answer is an error.
      expect(errors.map((Object e) => (e as MealioException).code), <String>[MealioErrorCode.server]);
    });
  });

  group('cancelled, and why (items 4, 10)', () {
    test('cancelJobs during the session fetch reports cancelled even when the fetch then fails', () async {
      final gate = Completer<String>();
      final client = _client((String p) => _json(<String, Object?>{}), token: () => gate.future);
      final prepare = client.prepareCart(recipe: _recipe);
      await Future<void>.delayed(Duration.zero);
      client.cancelJobs();
      gate.completeError(Exception('server down'));
      await expectLater(prepare, throwsA(_cancelled(MealioCancelReason.cancelled)));
    });

    test('a user change cancels with reason user_changed', () async {
      final gate = Completer<String>();
      final client = _client((String p) => _json(<String, Object?>{}), token: () => gate.future);
      client.setUser('A');
      final prepare = client.prepareCart(recipe: _recipe);
      await Future<void>.delayed(Duration.zero);
      client.setUser('B');
      gate.complete('tok');
      await expectLater(prepare, throwsA(_cancelled(MealioCancelReason.userChanged)));
    });

    test('resetSession while the token is fetched cancels with reason user_changed', () async {
      final gate = Completer<String>();
      var calls = 0;
      final client = _client((String p) => _json(<String, Object?>{}), token: () {
        calls += 1;
        return gate.future;
      });
      final cancel = CancelToken();
      final prepare = client.prepareCart(recipe: _recipe, cancel: cancel);
      await Future<void>.delayed(Duration.zero);
      client.resetSession();
      gate.complete('tok');
      await expectLater(prepare, throwsA(_cancelled(MealioCancelReason.userChanged)));
      expect(calls, 1);
    });

    test('a token cancelled with closed says closed', () async {
      final client = _client((String p) => _json(<String, Object?>{}));
      final cancel = CancelToken()..cancel(MealioCancelReason.closed);
      await expectLater(client.prepareCart(recipe: _recipe, cancel: cancel), throwsA(_cancelled(MealioCancelReason.closed)));
    });

    testWidgets('closing the sheet cancels its prepare with reason closed', (WidgetTester tester) async {
      _phone(tester);
      installMealioTestPlatform();
      configureMealioForTesting();
      Object? error;
      final gate = Completer<CartSession>();
      await tester.pumpWidget(_app(Builder(
        builder: (BuildContext context) => TextButton(
          onPressed: () => MealioCartFlow.show(
            context,
            recipe: _recipe,
            store: 'heb',
            prepareCart: ({String? store, required Recipe recipe, String? zip, StepListener? onStep}) {
              final hold = Completer<void>();
              unawaited(MealioCart.instance.client.runExclusive((_) => hold.future));
              final p = MealioCart.instance.prepareCart(store: store, recipe: recipe);
              p.then(gate.complete, onError: (Object e) {
                error = e;
                hold.complete();
              });
              return p;
            },
          ),
          child: const Text('open'),
        ),
      )));
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump();
      await tester.tapAt(const Offset(10, 10));
      await tester.pumpAndSettle();
      expect(error, _cancelled(MealioCancelReason.closed));
    });
  });
}
