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
    /// `onChange` is called each time the user's store changes. While
    /// `MealioCart.setUser(nil)` says nobody is signed in, it does not open:
    /// `onSignInRequired` (else `MealioCart.onSignInRequired`) is called instead.
    @MainActor
    func mealioStoreSettings(isPresented: Binding<Bool>,
                             onChange: ((StorePreferences) -> Void)? = nil,
                             onSignInRequired: (() -> Void)? = nil) -> some View {
        modifier(MealioStoreSettingsPresenter(isPresented: isPresented, onChange: onChange,
                                              onSignInRequired: onSignInRequired))
    }
}

/// Presents store settings, only while someone is signed in.
@MainActor
struct MealioStoreSettingsPresenter: ViewModifier {
    @Binding var isPresented: Bool
    let onChange: ((StorePreferences) -> Void)?
    let onSignInRequired: (() -> Void)?
    @ObservedObject private var users: MealioUsers
    /// What is actually presented: the partner's flag, while someone is signed in.
    @State private var shown = false

    init(isPresented: Binding<Bool>, onChange: ((StorePreferences) -> Void)?, onSignInRequired: (() -> Void)?) {
        self._isPresented = isPresented
        self.onChange = onChange
        self.onSignInRequired = onSignInRequired
        self._users = ObservedObject(wrappedValue: MealioCart.users)
    }

    func body(content: Content) -> some View {
        let onChange = self.onChange
        let onSignInRequired = self.onSignInRequired
        // VERIFY: same as mealioCartFlow, the sheet content closure is formed
        // in a @MainActor context, so the MealioStoreSettings init call is fine.
        return content
            .mealioPresent(isPresented: $shown) {
                MealioStoreSettings(onChange: onChange, onSignInRequired: onSignInRequired)
            }
            .onAppear { asked(isPresented) }
            .onChange(of: isPresented) { open in asked(open) }
            // Closed by a swipe or its own button: tell the partner's flag.
            .onChange(of: shown) { open in
                if !open && isPresented { isPresented = false }
            }
            .onChange(of: users.hasUser) { has in
                if !has {
                    shown = false
                    isPresented = false
                }
            }
    }

    /// The partner asked to open (or close) it.
    private func asked(_ open: Bool) {
        if open && !users.hasUser {
            isPresented = false
            (onSignInRequired ?? MealioCart.onSignInRequired)?()
            return
        }
        if shown != open { shown = open }
    }
}

/// The sheet's content. Present it with `.mealioStoreSettings(isPresented:)`
/// or your own `.sheet { MealioStoreSettings() }`.
@MainActor
public struct MealioStoreSettings: View {
    private let onChange: ((StorePreferences) -> Void)?
    private let onSignInRequired: (() -> Void)?

    @State private var stores: [StoreInfo]?
    @State private var prefs: StorePreferences?
    /// The Kroger family chain whose locations are showing.
    @State private var picking: StoreInfo?
    @State private var saving: String?
    @State private var problem: String?
    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) private var systemScheme

    /// - Parameters:
    ///   - onChange: Called each time the user's store changes.
    ///   - onSignInRequired: Called, and the sheet closes, when it opens while
    ///     nobody is signed in. Defaults to `MealioCart.onSignInRequired`.
    public init(onChange: ((StorePreferences) -> Void)? = nil, onSignInRequired: (() -> Void)? = nil) {
        self.onChange = onChange
        self.onSignInRequired = onSignInRequired
    }

    private var t: MealioTheme { MealioCart.resolvedTheme(for: systemScheme) }
    private var ui: MealioText { MealioCart.text }

    public var body: some View {
        VStack(spacing: 0) {
            MealioGrabber(t: t)
            MealioFlowHeader(t: t, recipeTitle: nil,
                             title: picking.map { ui.tr(.titleLocation, ["store": $0.name]) } ?? ui.tr(.titleSettings),
                             onClose: { dismiss() })
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .background(t.background.ignoresSafeArea())
        .mealioSheetSize()
        .task {
            guard MealioCart.hasUser else {
                (onSignInRequired ?? MealioCart.onSignInRequired)?()
                dismiss()
                return
            }
            await load()
        }
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
                                 back: MealioLocationPicker.Back(label: ui.tr(.backToStores),
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
                MealioCTA(t: t, title: ui.tr(.done), action: { dismiss() })
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
        let trailing: String? = isCurrent ? ui.tr(location != nil ? .change : .current) : nil
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
            problem = mealioProblem(error, ui.tr(.couldNotLoadYourStores))
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
                problem = mealioProblem(error, ui.tr(.couldNotSaveStore))
            }
            saving = nil
        }
    }
}
#endif
