// A plain SwiftUI drop-in for a prepared cart: ready items, items the user
// must pick a product for, items the store does not have, and an Add button.
// Theme it with `accentColor`; for anything more, build your own view on
// CartSession (it is an ObservableObject).

#if canImport(SwiftUI) && canImport(UIKit)
import SwiftUI

@MainActor
public struct MealioCartSheet: View {
    @ObservedObject private var session: CartSession
    private let accentColor: Color
    private let title: String
    private let onFinished: (AddResult) -> Void
    private let onError: (Error) -> Void
    private let onCancel: (() -> Void)?

    @State private var adding = false
    @State private var errorText: String?
    @State private var preferenceAsk: PreferenceAsk?

    /// - Parameters:
    ///   - session: From `MealioCart.prepareCart`.
    ///   - accentColor: Buttons, checkmarks and the Add button.
    ///   - title: The navigation title.
    ///   - onFinished: Called with the result after the store cart is filled.
    ///   - onError: Called when filling the cart fails. The sheet also shows it.
    ///   - onCancel: Shows a Cancel button when set.
    public init(session: CartSession,
                accentColor: Color = .accentColor,
                title: String = "Add to cart",
                onFinished: @escaping (AddResult) -> Void,
                onError: @escaping (Error) -> Void = { _ in },
                onCancel: (() -> Void)? = nil) {
        self._session = ObservedObject(wrappedValue: session)
        self.accentColor = accentColor
        self.title = title
        self.onFinished = onFinished
        self.onError = onError
        self.onCancel = onCancel
    }

    public var body: some View {
        NavigationView {
            List {
                ForEach(session.needsChoice) { item in
                    Section(header: Text(item.ingredient)) {
                        ForEach(item.options ?? []) { product in
                            optionRow(item: item, product: product)
                        }
                        skipRow(item)
                    }
                }
                if !session.ready.isEmpty {
                    Section(header: Text("Ready")) {
                        ForEach(session.ready) { item in readyRow(item) }
                    }
                }
                if !session.unavailable.isEmpty {
                    Section(header: Text("Not available")) {
                        ForEach(session.unavailable) { item in unavailableRow(item) }
                    }
                }
                if let text = errorText {
                    Section {
                        Text(text).font(.footnote).foregroundColor(.red)
                    }
                }
            }
            .listStyle(.insetGrouped)
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if let onCancel = onCancel {
                        Button("Cancel") { onCancel() }
                    }
                }
            }
            .safeAreaInset(edge: .bottom) { addBar }
        }
        .navigationViewStyle(.stack)
        .tint(accentColor)
        .confirmationDialog(preferenceAsk?.product.name ?? "",
                            isPresented: Binding(get: { preferenceAsk != nil },
                                                 set: { if !$0 { preferenceAsk = nil } }),
                            titleVisibility: .visible,
                            presenting: preferenceAsk) { ask in
            ForEach(ask.product.preferences ?? []) { pref in
                Button(pref.label) {
                    try? session.choose(key: ask.item.key, productId: ask.product.id, preferenceId: pref.id)
                }
            }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: rows

    private func optionRow(item: CartItem, product: Product) -> some View {
        let pick = session.selection(for: item.key)
        let selected = pick?.productId == product.id
        let preference: ProductPreference? = selected ? product.preferences?.first(where: { $0.id == pick?.preferenceId }) : nil
        return Button {
            choose(item, product)
        } label: {
            HStack(spacing: 12) {
                ProductThumb(url: product.imageUrl)
                VStack(alignment: .leading, spacing: 2) {
                    Text(product.name).foregroundColor(.primary).lineLimit(2)
                    detailLine(product)
                    if let preference = preference {
                        Text(preference.label).font(.caption).foregroundColor(accentColor)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: selected ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(selected ? accentColor : .secondary)
            }
        }
        .disabled(product.outOfStock == true || adding)
    }

    private func skipRow(_ item: CartItem) -> some View {
        let skipped = session.selection(for: item.key).map { $0.productId == nil } ?? false
        return Button {
            session.skip(key: item.key)
        } label: {
            HStack {
                Text("Skip this item").foregroundColor(.secondary)
                Spacer()
                Image(systemName: skipped ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(skipped ? accentColor : .secondary)
            }
        }
        .disabled(adding)
    }

    private func readyRow(_ item: CartItem) -> some View {
        let included = session.selection(for: item.key)?.productId != nil
        return Button {
            if included {
                session.skip(key: item.key)
            } else if let chosen = item.chosen {
                try? session.choose(key: item.key, productId: chosen.id)
            }
        } label: {
            HStack(spacing: 12) {
                ProductThumb(url: item.chosen?.imageUrl)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.ingredient).font(.subheadline.weight(.semibold)).foregroundColor(.primary)
                    if let chosen = item.chosen {
                        Text(chosen.name).font(.caption).foregroundColor(.secondary).lineLimit(2)
                    }
                }
                Spacer(minLength: 8)
                Image(systemName: included ? "checkmark.circle.fill" : "circle")
                    .foregroundColor(included ? accentColor : .secondary)
            }
        }
        .disabled(adding)
    }

    private func unavailableRow(_ item: CartItem) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(item.ingredient).foregroundColor(.primary)
            Text(MealioCartSheet.reasonText(item.reason)).font(.caption).foregroundColor(.secondary)
        }
    }

    private func detailLine(_ product: Product) -> some View {
        var parts: [String] = []
        if let price = product.price, !price.isEmpty { parts.append(price) }
        if let size = product.size, !size.isEmpty { parts.append(size) }
        if product.outOfStock == true { parts.append("Out of stock") }
        if let badge = MealioCartSheet.badgeText(product.badge) { parts.append(badge) }
        return Text(parts.joined(separator: " · ")).font(.caption).foregroundColor(.secondary)
    }

    // MARK: add

    private var addBar: some View {
        let waiting = session.pending().count
        let count = session.selections().filter { $0.productId != nil }.count
        let canAdd = !adding && waiting == 0 && count > 0
        return VStack(spacing: 6) {
            if waiting > 0 {
                Text(waiting == 1 ? "1 item still needs a pick" : "\(waiting) items still need a pick")
                    .font(.footnote).foregroundColor(.secondary)
            }
            Button {
                add()
            } label: {
                HStack(spacing: 8) {
                    if adding { ProgressView().tint(.white) }
                    Text(adding ? "Adding…" : (count == 1 ? "Add 1 item to cart" : "Add \(count) items to cart")).bold()
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .foregroundColor(.white)
                .background(RoundedRectangle(cornerRadius: 12).fill(accentColor.opacity(canAdd || adding ? 1 : 0.4)))
            }
            .disabled(!canAdd)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.regularMaterial)
    }

    private func choose(_ item: CartItem, _ product: Product) {
        if let prefs = product.preferences, !prefs.isEmpty {
            preferenceAsk = PreferenceAsk(item: item, product: product)
            return
        }
        try? session.choose(key: item.key, productId: product.id)
    }

    private func add() {
        adding = true
        errorText = nil
        Task {
            do {
                let result = try await session.addToCart()
                adding = false
                onFinished(result)
            } catch {
                adding = false
                errorText = (error as? MealioError)?.message ?? error.localizedDescription
                onError(error)
            }
        }
    }

    // MARK: text

    static func badgeText(_ badge: String?) -> String? {
        switch badge ?? "" {
        case "picked_before": return "Picked before"
        case "popular": return "Popular"
        case "partner_pick": return "Recommended"
        default: return nil
        }
    }

    static func reasonText(_ reason: String?) -> String {
        let r = reason ?? ""
        switch r {
        case "no_results": return "No match at this store"
        case "": return "Not available at this store"
        default: return r.replacingOccurrences(of: "_", with: " ").capitalized
        }
    }
}

/// A product waiting on the user to pick one of its preferences.
private struct PreferenceAsk {
    let item: CartItem
    let product: Product
}

private struct ProductThumb: View {
    let url: String?

    var body: some View {
        Group {
            if let s = url, let u = URL(string: s) {
                AsyncImage(url: u) { image in
                    image.resizable().scaledToFill()
                } placeholder: {
                    Color.secondary.opacity(0.12)
                }
            } else {
                Color.secondary.opacity(0.12)
            }
        }
        .frame(width: 44, height: 44)
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }
}
#endif
