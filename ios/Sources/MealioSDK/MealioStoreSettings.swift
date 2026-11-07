// Change the user's store outside a cart: the same store list and the same zip
// and location screens as the cart sheet.
// Mirrors packages/react-native/src/MealioStoreSettings.tsx.

#if canImport(SwiftUI) && canImport(UIKit) && canImport(WebKit)
import SwiftUI

public extension View {
    /// Present the sheet where the user changes their store or zip. Put it on
    /// your settings screen.
    ///
    ///     .mealioStoreSettings(isPresented: $showStore)
    ///
    /// `onChange` is called each time the user's store changes.
    @MainActor
    func mealioStoreSettings(isPresented: Binding<Bool>,
                             onChange: ((StorePreferences) -> Void)? = nil) -> some View {
        // VERIFY: same as mealioCartFlow, the sheet content closure is formed
        // in a @MainActor function, so the MealioStoreSettings init call is fine.
        sheet(isPresented: isPresented) {
            MealioStoreSettings(onChange: onChange)
        }
    }
}

/// The sheet's content. Present it with `.mealioStoreSettings(isPresented:)`
/// or your own `.sheet { MealioStoreSettings() }`.
@MainActor
public struct MealioStoreSettings: View {
    private let onChange: ((StorePreferences) -> Void)?

    @State private var stores: [StoreInfo]?
    @State private var prefs: StorePreferences?
    /// The Kroger family chain whose locations are showing.
    @State private var picking: StoreInfo?
    @State private var saving: String?
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss

    /// - Parameter onChange: Called each time the user's store changes.
    public init(onChange: ((StorePreferences) -> Void)? = nil) {
        self.onChange = onChange
    }

    private var t: MealioTheme { MealioCart.theme }

    public var body: some View {
        VStack(spacing: 0) {
            Capsule()
                .fill(t.border)
                .frame(width: 36, height: 5)
                .padding(.top, 8)
                .accessibilityHidden(true)
            MealioFlowHeader(t: t, recipeTitle: nil,
                             title: picking.map { "Find your \($0.name)" } ?? "Your grocery store",
                             onClose: { dismiss() })
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(t.background.ignoresSafeArea())
        .task { await load() }
    }

    @ViewBuilder
    private var content: some View {
        if let picking = picking {
            MealioLocationPicker(t: t, store: picking.id, storeName: picking.name,
                                 zip: samePick?.zip, current: samePick?.id,
                                 onPicked: { location in
                                     changed(StorePreferences(defaultStore: picking.id, location: location))
                                     self.picking = nil
                                 },
                                 back: MealioLocationPicker.Back(label: "Back to your stores",
                                                                 action: { self.picking = nil }))
        } else if let stores = stores {
            VStack(spacing: 0) {
                ScrollView {
                    VStack(alignment: .leading, spacing: 10) {
                        if let problem = problem {
                            Text(problem)
                                .font(t.font(15))
                                .foregroundColor(t.text)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        ForEach(stores) { st in
                            row(st)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 2)
                    .padding(.bottom, 24)
                }
                MealioCTA(t: t, title: "Done", action: { dismiss() })
                    .padding(.horizontal, 16)
                    .padding(.vertical, 12)
                    .overlay(alignment: .top) { Rectangle().fill(t.border).frame(height: 1) }
            }
        } else {
            ProgressView()
                .progressViewStyle(.circular)
                .tint(t.accent)
                .frame(maxWidth: .infinity)
                .padding(20)
        }
    }

    private func row(_ st: StoreInfo) -> some View {
        let isCurrent = st.id == prefs?.defaultStore
        let location = isCurrent ? prefs?.location : nil
        let trailing: String? = isCurrent ? (location != nil ? "Change" : "Current") : nil
        return MealioStoreOption(t: t, title: st.name,
                                 detail: location.map { "\($0.name), \($0.address)" },
                                 selected: isCurrent, saving: saving == st.id, trailing: trailing,
                                 disabled: saving != nil, action: { choose(st) })
            .accessibilityIdentifier("mealio-store-\(st.id)")
    }

    /// The saved location, when the chain on screen is the user's own.
    private var samePick: StoreLocation? {
        guard let picking = picking, prefs?.defaultStore == picking.id else { return nil }
        return prefs?.location
    }

    private func load() async {
        problem = nil
        do {
            async let list = MealioCart.stores()
            async let current = MealioCart.storePreferences()
            let (loaded, saved) = try await (list, current)
            stores = loaded
            prefs = saved
        } catch {
            stores = []
            problem = (error as? MealioError)?.message ?? "Could not load your stores."
        }
    }

    private func changed(_ next: StorePreferences) {
        prefs = next
        onChange?(next)
    }

    private func choose(_ store: StoreInfo) {
        // A Kroger family store is a chain: the user still has to say which one.
        if store.via == "kroger_api" {
            picking = store
            return
        }
        saving = store.id
        problem = nil
        Task { @MainActor in
            do {
                let next = try await MealioCart.setStore(store.id)
                changed(next)
            } catch {
                problem = (error as? MealioError)?.message ?? "Could not save that store. Try again."
            }
            saving = nil
        }
    }
}
#endif
