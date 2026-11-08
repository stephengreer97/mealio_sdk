// Errors the SDK raises to the app. PROTOCOL.md "Errors the SDK raises to the
// app" lists the codes.

/// Error codes from PROTOCOL.md, plus a few the SDK uses for its own API.
abstract final class MealioErrorCode {
  static const String badEnvelope = 'bad_envelope';
  static const String blocked = 'blocked';
  static const String storeUnavailable = 'store_unavailable';
  static const String loginCancelled = 'login_cancelled';
  static const String sessionExpired = 'session_expired';
  static const String network = 'network';

  /// The session function (`sessionTokenProvider`) failed or took over 30
  /// seconds. `message` is its error's message.
  static const String sessionFailed = 'session_failed';

  /// `MealioCart.setUser(null)`: nobody is signed in, so no session is asked for.
  static const String notSignedIn = 'not_signed_in';

  /// A prepare or search was stopped: the sheet closed, or the user changed.
  static const String cancelled = 'cancelled';
  static const String unsupported = 'unsupported';

  /// No store was given and the user has no default store yet.
  static const String storeRequired = 'store_required';
  static const String storeNotAllowed = 'store_not_allowed';
  static const String cartCapReached = 'cart_cap_reached';
  static const String tooManyCarts = 'too_many_carts';

  /// A Kroger family store has no saved location for this user. Raised before
  /// any sign-in. `MealioCart.setStore` saves one.
  static const String locationRequired = 'location_required';

  /// `prepareCart` was given no recipe.
  static const String badRecipe = 'bad_recipe';

  /// `prepareCart` was given more than `maxRecipes` (10) recipes.
  static const String tooManyRecipes = 'too_many_recipes';

  /// Mealio answered with an error the protocol does not name.
  static const String server = 'server';

  /// `CartSession.choose` was given a key the cart does not have.
  static const String unknownItem = 'unknown_item';

  /// `CartSession.choose` was given a product that was not offered.
  static const String unknownProduct = 'unknown_product';

  /// No `MealioScope` is mounted, so there is no WebView to work in.
  static const String noScope = 'no_scope';

  /// `MealioCart.configure` has not been called.
  static const String notConfigured = 'not_configured';
}

/// Why a call failed with `cancelled` ([MealioException.reason]).
abstract final class MealioCancelReason {
  /// The signed-in user changed (`setUser`, or `resetSession` while the call
  /// waited for its session). Prepare again for the new user.
  static const String userChanged = 'user_changed';

  /// The sheet that started it closed.
  static const String closed = 'closed';

  /// Anything else: `cancelJobs`, a store sign-out, a new `configure`, your
  /// own `CancelToken`.
  static const String cancelled = 'cancelled';
}

/// Any failure the SDK reports to the app. `code` is one of
/// [MealioErrorCode], or a `fail` code the server sent.
class MealioException implements Exception {
  const MealioException(this.code, this.message, {this.reason});

  final String code;
  final String message;

  /// For `cancelled` only: why, one of [MealioCancelReason]. Null otherwise.
  final String? reason;

  @override
  String toString() => 'MealioException($code${reason == null ? '' : ', $reason'}): $message';
}
