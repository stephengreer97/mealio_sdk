/// Mealio Cart SDK for Flutter.
///
/// Place [MealioScope] once near the app root, call [MealioCart.configure],
/// then [MealioCart.prepareCart] and show the result with [MealioCartSheet]
/// or your own UI on top of [CartSession].
library;

export 'src/allowlist.dart';
export 'src/cart_session.dart';
export 'src/client.dart'
    show ClientConfig, MealioClient, defaultBaseUrl, mealioSdkVersion, sdkCoreVersion;
export 'src/errors.dart';
export 'src/guard.dart';
export 'src/host.dart';
export 'src/keys.dart';
export 'src/matcher.dart';
export 'src/mealio_cart.dart';
export 'src/protocol.dart';
export 'src/runner.dart';
export 'src/verify.dart';
export 'src/webview_host.dart' show WebViewHost, bridgeChannelName, bridgeInjection, fetchResultType;
export 'src/widgets/cart_sheet.dart';
export 'src/widgets/mealio_scope.dart';
