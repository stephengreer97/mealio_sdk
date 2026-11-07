// What happens in the drop-in sheet, for a partner's analytics. Set `onEvent`
// once and every step arrives there. Nothing is sent to Mealio. Mirrors
// packages/core/src/events.ts.

/// Where the user is in the sheet. `name` is the same word as on React Native.
enum MealioSheetStep { loading, stores, location, signin, list, adding, done, error }

/// Receives every step of the sheet. Set it with `onEvent`, beside the theme.
typedef MealioEventListener = void Function(MealioEvent event);

/// One step of the sheet. Switch on the subclass for typed fields, or send
/// [type] and [toJson] straight to your analytics.
sealed class MealioEvent {
  const MealioEvent(this.type);

  /// The event's name, like `sheet_opened`. The same on every platform.
  final String type;

  Map<String, Object?> get _fields;

  /// [type] and the fields, with the same keys as on React Native.
  Map<String, Object?> toJson() => <String, Object?>{'type': type, ..._fields};

  @override
  String toString() => 'MealioEvent(${toJson()})';
}

/// The sheet opened with this many recipes.
final class MealioSheetOpened extends MealioEvent {
  const MealioSheetOpened({required this.recipes}) : super('sheet_opened');

  final int recipes;

  @override
  Map<String, Object?> get _fields => <String, Object?>{'recipes': recipes};
}

/// The user tapped a store in the store picker.
final class MealioStorePicked extends MealioEvent {
  const MealioStorePicked({required this.store}) : super('store_picked');

  final String store;

  @override
  Map<String, Object?> get _fields => <String, Object?>{'store': store};
}

/// The sheet asked which location of [store] the user shops at.
final class MealioLocationAsked extends MealioEvent {
  const MealioLocationAsked({required this.store}) : super('location_asked');

  final String store;

  @override
  Map<String, Object?> get _fields => <String, Object?>{'store': store};
}

/// The store's sign-in page appeared. [store] is null when the cart is using
/// the user's default store and has not said which one yet.
final class MealioSigninShown extends MealioEvent {
  const MealioSigninShown({required this.store}) : super('signin_shown');

  final String? store;

  @override
  Map<String, Object?> get _fields => <String, Object?>{'store': store};
}

/// The list appeared with this many items.
final class MealioListShown extends MealioEvent {
  const MealioListShown({required this.store, required this.items}) : super('list_shown');

  final String store;
  final int items;

  @override
  Map<String, Object?> get _fields => <String, Object?>{'store': store, 'items': items};
}

/// The user unchecked an item.
final class MealioItemUnchecked extends MealioEvent {
  const MealioItemUnchecked({required this.key}) : super('item_unchecked');

  final String key;

  @override
  Map<String, Object?> get _fields => <String, Object?>{'key': key};
}

/// The user checked an item again.
final class MealioItemChecked extends MealioEvent {
  const MealioItemChecked({required this.key}) : super('item_checked');

  final String key;

  @override
  Map<String, Object?> get _fields => <String, Object?>{'key': key};
}

/// The user tapped add, with this many items checked.
final class MealioAddStarted extends MealioEvent {
  const MealioAddStarted({required this.items}) : super('add_started');

  final int items;

  @override
  Map<String, Object?> get _fields => <String, Object?>{'items': items};
}

/// The store cart was filled.
final class MealioCartAdded extends MealioEvent {
  const MealioCartAdded({required this.store, required this.added, required this.failed}) : super('cart_added');

  final String store;
  final int added;
  final int failed;

  @override
  Map<String, Object?> get _fields => <String, Object?>{'store': store, 'added': added, 'failed': failed};
}

/// Preparing or adding failed. [code] is the `MealioException` code, or
/// `error` for anything else. [step] is `loading` or `adding`.
final class MealioErrorEvent extends MealioEvent {
  const MealioErrorEvent({required this.code, required this.step}) : super('error');

  final String code;
  final MealioSheetStep step;

  @override
  Map<String, Object?> get _fields => <String, Object?>{'code': code, 'step': step.name};
}

/// The sheet closed. [step] is where they left, so a count per step shows
/// where people drop off. [added] is 0 unless they left from the done screen.
final class MealioSheetClosed extends MealioEvent {
  const MealioSheetClosed({required this.step, required this.added}) : super('sheet_closed');

  final MealioSheetStep step;
  final int added;

  @override
  Map<String, Object?> get _fields => <String, Object?>{'step': step.name, 'added': added};
}

/// A partner's listener never breaks the sheet.
MealioEventListener mealioSafeListener(MealioEventListener? fn) {
  return (MealioEvent e) {
    if (fn == null) return;
    try {
      fn(e);
    } catch (_) {
      // Their code, their log.
    }
  };
}
