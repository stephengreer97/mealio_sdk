// The Flutter host's hidden page on a fake WebView platform: which page
// events answer a page_open, bounded injection, the blocked-path backstop,
// and a MealioScope remount or a closed sheet while a job runs.

import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:mealio_sdk/mealio_sdk.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart' as wv;

import 'fake_platform.dart';
import 'support.dart';

/// Resolves the mounted scope's host at call time, as MealioCart's own host does.
class _Scoped implements MealioHost, MealioPageIdentity {
  WebViewHost get _h => WebViewHost.current!;
  @override
  Object? get currentPage => WebViewHost.current?.page;
  @override
  Future<PageLoad> openPage(String s, String u, int t) => _h.openPage(s, u, t);
  @override
  Future<ScriptRun> runScript(String s, String g, String x, List<MessageMatcher> u, int t) => _h.runScript(s, g, x, u, t);
  @override
  Future<LoginResult> showLogin(LoginRequest r) => _h.showLogin(r);
  @override
  Future<HttpResult> fetch(String s, FetchRequest r, int t, int m) => _h.fetch(s, r, t, m);
}

http.Response _json(Object? b, [int s = 200]) =>
    http.Response.bytes(utf8.encode(jsonEncode(b)), s, headers: <String, String>{'content-type': 'application/json'});

Future<Envelope> _env(String job, int seq, List<Map<String, Object?>> ins) => signText(jsonEncode(<String, Object?>{
      'v': 1,
      'kind': 'instructions',
      'job': job,
      'seq': seq,
      'exp': 4102444800,
      'store': 'heb',
      'instructions': ins,
    }));

const Map<String, Object?> _emptyCart = <String, Object?>{
  'cartId': 'c',
  'store': 'heb',
  'items': <Object?>[],
  'ready': <Object?>[],
  'needsChoice': <Object?>[],
  'unavailable': <Object?>[],
};
const Recipe _recipe = Recipe(id: 'r1', title: 'T', ingredients: <RecipeIngredient>[RecipeIngredient(name: 'milk')]);

Widget _app(GlobalKey<NavigatorState> nav, Key scopeKey, Widget home) => MaterialApp(
      navigatorKey: nav,
      builder: (BuildContext c, Widget? child) => MealioScope(key: scopeKey, navigatorKey: nav, child: child!),
      home: home,
    );

Future<void> _settle() async {
  for (var i = 0; i < 5; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  setUp(() {
    wv.WebViewPlatform.instance = FakePlatform();
    FakeController.all.clear();
    FakeController.hangOn = null;
    FakeController.onLoad = null;
  });

  group('page_open', () {
    test('a stale about:blank finish does not answer it', () async {
      final h = WebViewHost();
      final c = FakeController.all.last;
      FakeController.onLoad = (FakeController _, String __) {};
      var answered = false;
      final r = h.openPage('heb', 'https://www.heb.com/', 3000).whenComplete(() => answered = true);
      await _settle();
      // A sign-out's about:blank reports finished while the store page loads.
      c.d!.finished!('about:blank');
      await _settle();
      expect(answered, isFalse);
      c.d!.started!('https://www.heb.com/');
      c.d!.finished!('https://www.heb.com/');
      expect((await r).ok, isTrue);
    });

    test('an older page finishing does not answer the next one', () async {
      final h = WebViewHost();
      final c = FakeController.all.last;
      FakeController.onLoad = (FakeController _, String __) {};
      var answered = false;
      final r = h.openPage('heb', 'https://www.heb.com/search', 3000).whenComplete(() => answered = true);
      await _settle();
      c.d!.finished!('https://www.heb.com/old');
      await _settle();
      expect(answered, isFalse);
      c.d!.started!('https://www.heb.com/search');
      c.d!.finished!('https://www.heb.com/search');
      expect((await r).ok, isTrue);
    });

    test('a load that times out is stopped', () async {
      final h = WebViewHost();
      final c = FakeController.all.last;
      FakeController.onLoad = (FakeController _, String __) {};
      final p = await h.openPage('heb', 'https://www.heb.com/', 50);
      expect(p.error, 'timeout');
      expect(c.loads.last, 'about:blank');
    });

    test('on Android, the finish of a navigation the plugin cancelled does not answer it', () async {
      final h = WebViewHost()..reissuesNavigations = true;
      final c = FakeController.all.last;
      FakeController.onLoad = (FakeController _, String __) {};
      var answered = false;
      final r = h.openPage('heb', 'https://www.heb.com/a', 3000).whenComplete(() => answered = true);
      await _settle();
      c.d!.started!('https://www.heb.com/a');
      // A redirect: the plugin cancels it and loads it again itself.
      final decision = await c.d!.onNav!(const wv.NavigationRequest(url: 'https://www.heb.com/b', isMainFrame: true));
      expect(decision, wv.NavigationDecision.navigate);
      c.d!.finished!('https://www.heb.com/b');
      c.d!.finished!('https://www.heb.com/a');
      await _settle();
      expect(answered, isFalse);
      c.d!.started!('https://www.heb.com/b');
      c.d!.finished!('https://www.heb.com/b');
      expect((await r).ok, isTrue);
    });

    test('on iOS, a server redirect finishes without a new start', () async {
      final h = WebViewHost()..reissuesNavigations = false;
      final c = FakeController.all.last;
      FakeController.onLoad = (FakeController _, String __) {};
      final r = h.openPage('heb', 'https://www.heb.com/a', 3000);
      await _settle();
      c.d!.started!('https://www.heb.com/a');
      await c.d!.onNav!(const wv.NavigationRequest(url: 'https://www.heb.com/b', isMainFrame: true));
      c.d!.finished!('https://www.heb.com/b');
      expect((await r).ok, isTrue);
    });

    test('a blocked page that starts without a navigation request is replaced with a blank one', () async {
      final h = WebViewHost();
      final c = FakeController.all.last;
      FakeController.onLoad = (FakeController _, String __) {};
      final r = h.openPage('heb', 'https://www.heb.com/', 3000);
      await _settle();
      c.loads.clear();
      // A form POST on Android never reaches shouldOverrideUrlLoading.
      c.d!.started!('https://www.heb.com/checkout/place-order');
      await _settle();
      expect(c.loads, <String>['about:blank']);
      final p = await r;
      expect(p.ok, isFalse);
      expect(p.error, 'blocked');
    });
  });

  group('injection', () {
    test('a runJavaScript that never returns ends the step at its timeout, and the page goes on', () async {
      final h = WebViewHost();
      FakeController.hangOn = 'STUCK';
      final run = await h.runScript('heb', '/*guard*/', '/*STUCK*/', const <MessageMatcher>[], 50);
      expect(run.timedOut, isTrue);
      final next = await h.openPage('heb', 'https://www.heb.com/', 1000);
      expect(next.ok, isTrue);
    });

    test('a fetch whose injection never returns ends at its timeout', () async {
      final h = WebViewHost();
      await h.openPage('heb', 'https://www.heb.com/', 1000);
      FakeController.hangOn = 'heb.com/stuck';
      final r = await h.fetch('heb', const FetchRequest(method: 'GET', url: 'https://www.heb.com/stuck'), 50, 1000);
      expect(r.error, 'timeout');
    });
  });

  group('MealioScope remount', () {
    testWidgets('a warm-up made on the old page is not offered to the next prepare', (WidgetTester tester) async {
      final carts = <Map<String, Object?>>[];
      late MealioClient client;
      await tester.runAsync(() async {
        final warmEnv = await _env('job_warm', 1, <Map<String, Object?>>[
          <String, Object?>{'op': 'page_open', 'id': 'open-1', 'url': 'https://www.heb.com/', 'timeoutMs': 3000},
          <String, Object?>{'op': 'done', 'id': 'd', 'result': <String, Object?>{'store': 'heb', 'signedIn': true}},
        ]);
        final cartEnv = await _env('job_cart', 1, <Map<String, Object?>>[
          <String, Object?>{'op': 'done', 'id': 'd', 'result': _emptyCart},
        ]);
        client = MealioClient(
          ClientConfig(
            publishableKey: 'pk',
            getSessionToken: () async => 't',
            keys: testKeys,
            httpClient: MockClient((http.Request r) async {
              if (r.url.path.endsWith('/warm')) return _json(<String, Object?>{'job': 'job_warm', 'envelope': warmEnv.toJson()});
              carts.add(jsonDecode(utf8.decode(r.bodyBytes)) as Map<String, Object?>);
              return _json(<String, Object?>{'job': 'job_cart', 'envelope': cartEnv.toJson()});
            }),
          ),
          _Scoped(),
        );
      });
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(_app(nav, const ValueKey<int>(1), const SizedBox()));
      var warmed = false;
      unawaited(client.warm().then((_) => warmed = true));
      for (var i = 0; i < 40 && !warmed; i++) {
        await tester.pump(const Duration(milliseconds: 1));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      }
      expect(warmed, isTrue);
      await tester.pumpWidget(_app(nav, const ValueKey<int>(2), const SizedBox()));
      var carted = false;
      unawaited(client.prepareCart(recipe: _recipe).then((_) => carted = true));
      for (var i = 0; i < 40 && !carted; i++) {
        await tester.pump(const Duration(milliseconds: 1));
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
      }
      expect(carted, isTrue);
      // The new hidden page is blank: the warm-up's page is gone with the old one.
      expect(carts.single.containsKey('warm'), isFalse);
    });

    testWidgets('an open sheet follows the new host, and sign-in shows in the sheet', (WidgetTester tester) async {
      final gate = Completer<void>();
      late MealioClient client;
      late Envelope first;
      await tester.runAsync(() async {
        first = await _env('j', 1, <Map<String, Object?>>[
          <String, Object?>{
            'op': 'show_login',
            'id': 'login-1',
            'url': 'https://www.heb.com/login',
            'title': 'Sign in',
            'doneWhen': <Object?>[],
            'timeoutMs': 60000,
          },
        ]);
        client = MealioClient(
          ClientConfig(
            publishableKey: 'pk',
            getSessionToken: () async => 't',
            keys: testKeys,
            httpClient: MockClient((http.Request r) async {
              await gate.future;
              return _json(<String, Object?>{'job': 'j', 'envelope': first.toJson()});
            }),
          ),
          _Scoped(),
        );
      });
      final nav = GlobalKey<NavigatorState>();
      Widget home() => Builder(
            builder: (BuildContext c) => Scaffold(
              body: TextButton(
                onPressed: () => MealioCartFlow.show(
                  c,
                  recipe: _recipe,
                  store: 'heb',
                  prepareCarts: ({String? store, required List<Recipe> recipes, String? zip, StepListener? onStep}) =>
                      client.prepareCart(store: store, recipes: recipes, zip: zip, onStep: onStep),
                ),
                child: const Text('go'),
              ),
            ),
          );
      await tester.pumpWidget(_app(nav, const ValueKey<int>(1), home()));
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final old = WebViewHost.current!;
      expect(old.flowOpen, isTrue);
      await tester.pumpWidget(_app(nav, const ValueKey<int>(2), home()));
      await tester.pump();
      await tester.pump();
      final now = WebViewHost.current!;
      expect(identical(old, now), isFalse);
      expect(now.flowOpen, isTrue);
      await tester.runAsync(() async {
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(now.login.value, isNotNull);
      expect(find.byType(MealioCartFlow), findsOneWidget);
      // Nothing was pushed over the sheet.
      expect(nav.currentState!.canPop(), isTrue);
      now.login.value!.cancel();
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
      await tester.pump(const Duration(milliseconds: 500));
    });
  });

  group('closing while a cart loads', () {
    testWidgets('stops the job: nothing more is sent and sign-in never shows', (WidgetTester tester) async {
      final gate = Completer<void>();
      final paths = <String>[];
      late MealioClient client;
      late Envelope first;
      await tester.runAsync(() async {
        first = await _env('j', 1, <Map<String, Object?>>[
          <String, Object?>{
            'op': 'show_login',
            'id': 'login-1',
            'url': 'https://www.heb.com/login',
            'title': 'Sign in please',
            'doneWhen': <Object?>[],
            'timeoutMs': 60000,
          },
        ]);
        client = MealioClient(
          ClientConfig(
            publishableKey: 'pk',
            getSessionToken: () async => 't',
            keys: testKeys,
            httpClient: MockClient((http.Request r) async {
              paths.add(r.url.path);
              await gate.future;
              return _json(<String, Object?>{'job': 'j', 'envelope': first.toJson()});
            }),
          ),
          _Scoped(),
        );
      });
      final nav = GlobalKey<NavigatorState>();
      await tester.pumpWidget(_app(
        nav,
        const ValueKey<int>(1),
        Builder(
          builder: (BuildContext c) => Scaffold(
            body: TextButton(
              onPressed: () => MealioCartFlow.show(
                c,
                recipe: _recipe,
                store: 'heb',
                prepareCarts: ({String? store, required List<Recipe> recipes, String? zip, StepListener? onStep}) =>
                    client.prepareCart(store: store, recipes: recipes, zip: zip, onStep: onStep),
              ),
              child: const Text('go'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      for (var i = 0; i < 10 && paths.isEmpty; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 5)));
        await tester.pump(const Duration(milliseconds: 1));
      }
      // The cart request is out when the user closes the sheet.
      expect(paths, hasLength(1));
      await tester.tap(find.bySemanticsLabel('Close').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('go'), findsOneWidget);
      await tester.runAsync(() async {
        gate.complete();
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('Sign in please'), findsNothing);
      expect(WebViewHost.current!.login.value, isNull);
      expect(paths, hasLength(1));
    });
  });
}
