/// Mealio Cart SDK for Flutter.
///
/// Call [MealioCart.configure] once, place [MealioScope] near the app root,
/// then drop in a [MealioCartButton]. It runs the whole flow (store sign-in,
/// the list, adding, done) in one sheet. [MealioCartFlow.show] opens the same
/// sheet from your own button; [CartSession] is the model under it for apps
/// that build their own UI.
library;

export 'src/allowlist.dart';
export 'src/cart_session.dart';
export 'src/client.dart'
    show
        ClientConfig,
        JobQueue,
        MealioClient,
        MealioStep,
        StepListener,
        defaultBaseUrl,
        mealioSdkVersion,
        requestTimeout,
        runCancellable,
        sdkCoreVersion,
        stepOf;
export 'src/errors.dart';
export 'src/events.dart';
export 'src/guard.dart';
export 'src/host.dart';
export 'src/keys.dart';
export 'src/matcher.dart';
export 'src/mealio_cart.dart';
export 'src/protocol.dart';
export 'src/runner.dart';
export 'src/strings.dart';
export 'src/theme.dart' hide MealioLook, mealioCarryScope;
export 'src/ui.dart';
export 'src/verify.dart';
export 'src/webview_host.dart' show MealioLoginView, WebViewHost, bridgeChannelName, bridgeInjection, bridgeUnwrap, fetchResultType;
export 'src/widgets/cart_flow.dart';
export 'src/widgets/cart_list.dart';
export 'src/widgets/cart_sheet.dart';
export 'src/widgets/location_picker.dart' show LoadLocations, SaveStore;
export 'src/widgets/mealio_scope.dart';
export 'src/widgets/store_settings.dart';
