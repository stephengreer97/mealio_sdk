// What happens in the drop-in sheet, for a partner's analytics. Set `onEvent`
// once and every step arrives here. Nothing is sent to Mealio.
// Mirrors packages/core/src/events.ts.

import Foundation

public enum MealioEvent: Equatable {
    case sheetOpened(recipes: Int)
    case storePicked(store: String)
    case locationAsked(store: String)
    case signinShown(store: String?)
    case listShown(store: String, items: Int)
    case itemUnchecked(key: String)
    case itemChecked(key: String)
    case addStarted(items: Int)
    case cartAdded(store: String, added: Int, failed: Int)
    case error(code: String, step: MealioSheetStep)
    /// `step` is where they left, so a count per step shows where people drop off.
    case sheetClosed(step: MealioSheetStep, added: Int)

    /// The event's name, the same on every Mealio SDK ("sheet_opened").
    public var type: String {
        switch self {
        case .sheetOpened: return "sheet_opened"
        case .storePicked: return "store_picked"
        case .locationAsked: return "location_asked"
        case .signinShown: return "signin_shown"
        case .listShown: return "list_shown"
        case .itemUnchecked: return "item_unchecked"
        case .itemChecked: return "item_checked"
        case .addStarted: return "add_started"
        case .cartAdded: return "cart_added"
        case .error: return "error"
        case .sheetClosed: return "sheet_closed"
        }
    }
}

public enum MealioSheetStep: String, Equatable, CaseIterable {
    case loading, stores, location, signin, list, adding, done, error
}

public typealias MealioEventListener = @MainActor (MealioEvent) -> Void
