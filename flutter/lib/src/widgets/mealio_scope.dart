// MealioScope: place once near the app root. It owns the WebViewHost and
// draws the hidden WebView that holds the user's store session.

import 'package:flutter/widgets.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../theme.dart';
import '../ui.dart';
import '../webview_host.dart';

/// Hosts the SDK's hidden WebView for the whole app.
///
/// Recommended placement, so the scope outlives every route and the login
/// sheet has a Navigator:
///
/// ```dart
/// final navigatorKey = GlobalKey<NavigatorState>();
///
/// MaterialApp(
///   navigatorKey: navigatorKey,
///   builder: (context, child) => MealioScope(navigatorKey: navigatorKey, child: child!),
///   home: const HomePage(),
/// );
/// ```
///
/// If the scope sits below your Navigator instead, `navigatorKey` can be
/// left out and the nearest Navigator is used.
class MealioScope extends StatefulWidget {
  const MealioScope({
    super.key,
    required this.child,
    this.navigatorKey,
    this.theme,
    this.darkTheme,
    this.colorScheme,
    this.strings,
    this.formatMoney,
    this.sheet,
  });

  final Widget child;

  /// Styles the drop-in widgets. Overrides `MealioCart.configure(theme: ...)`,
  /// as does each setting below that is not null.
  final MealioTheme? theme;

  /// Colors for dark mode. Only used when [colorScheme] is `dark`, or `auto`
  /// on a phone set to dark. Start from `MealioTheme.dark()`.
  final MealioTheme? darkTheme;

  /// `auto` follows the phone. Defaults to `light`.
  final MealioColorScheme? colorScheme;

  /// Change or translate any word. See `mealioDefaultStrings` for the keys.
  final Map<String, String>? strings;

  /// How prices read. Defaults to "\$12.50".
  final MealioMoneyFormat? formatMoney;

  /// How the sheet looks and behaves.
  final MealioSheetOptions? sheet;

  /// The Navigator the login sheet is pushed on. When null, the Navigator
  /// above this widget is used, if there is one.
  final GlobalKey<NavigatorState>? navigatorKey;

  /// The host of the mounted scope, or null.
  static WebViewHost? get host => WebViewHost.current;

  @override
  State<MealioScope> createState() => _MealioScopeState();
}

class _MealioScopeState extends State<MealioScope> {
  late final WebViewHost _host;

  @override
  void initState() {
    super.initState();
    _host = WebViewHost();
    _host.navigatorProvider = _navigator;
    _host.look = _look;
    WebViewHost.attach(_host);
  }

  @override
  void didUpdateWidget(MealioScope oldWidget) {
    super.didUpdateWidget(oldWidget);
    _host.look = _look;
  }

  MealioLook get _look => MealioLook(
        theme: widget.theme,
        darkTheme: widget.darkTheme,
        colorScheme: widget.colorScheme,
        strings: widget.strings,
        formatMoney: widget.formatMoney,
        sheet: widget.sheet,
      );

  NavigatorState? _navigator() {
    final fromKey = widget.navigatorKey?.currentState;
    if (fromKey != null) return fromKey;
    if (!mounted) return null;
    return Navigator.maybeOf(context);
  }

  @override
  void dispose() {
    _host.navigatorProvider = null;
    WebViewHost.detach(_host);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final Widget stack = Stack(
      // Non-directional alignment, so the Stack works even above the app's
      // Directionality (for example when MealioScope wraps MaterialApp).
      alignment: Alignment.topLeft,
      // The app gets exactly the constraints it would get without us.
      fit: StackFit.passthrough,
      children: <Widget>[
        widget.child,
        // The hidden WebView. It must be really laid out, attached and
        // composited, or the platform throttles or never starts it:
        // - Offstage does not paint its child, so the platform view is never
        //   composited. iOS then keeps the WKWebView out of the window
        //   (timers and JS are suspended) and Android may never create the
        //   surface.
        // - Opacity(0) has the same problem: Flutter's RenderOpacity skips
        //   painting a child whose alpha is 0, exactly like Offstage.
        // So it is a 1x1 box at 0.01 opacity: one physical-pixel-ish square
        // at alpha 3/255, invisible in practice, but painted.
        // VERIFY: on a real iOS and Android device that page_script timers run while hidden like this.
        Positioned(
          left: 0,
          top: 0,
          width: 1,
          height: 1,
          child: IgnorePointer(
            child: ExcludeSemantics(
              child: Opacity(
                opacity: 0.01,
                child: Directionality(
                  textDirection: TextDirection.ltr,
                  child: WebViewWidget(controller: _host.hidden),
                ),
              ),
            ),
          ),
        ),
      ],
    );
    return MealioThemeScope(
      theme: widget.theme,
      darkTheme: widget.darkTheme,
      colorScheme: widget.colorScheme,
      strings: widget.strings,
      formatMoney: widget.formatMoney,
      sheet: widget.sheet,
      child: stack,
    );
  }
}
