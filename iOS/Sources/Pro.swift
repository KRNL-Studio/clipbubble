import StoreKit
import SwiftUI

/// ClipBubble Pro: one purchase, kept forever, shared with Family Sharing. It unlocks every computer and the whole
/// 7-day history (see `Tier`).
@MainActor
final class Pro: ObservableObject {
    static let shared = Pro()
    static let productID = "studio.krnl.clipbubble.pro"
    /// The last build from before Pro (2.0.0). Whoever first downloaded one of these keeps everything for free. If 2.0.0
    /// ships with a later build, raise this to it.
    static let lastFreeBuild = 2611281017

    /// Why the upgrade screen opened, which sets what it leads with.
    enum Reason: String, Identifiable {
        case computers, history, settings
        var id: Self { self }
    }

    @Published private(set) var unlocked = Tier.unlocked
    @Published private(set) var product: Product?
    @Published private(set) var busy = false

    private var updates: Task<Void, Never>?

    private init() {
        #if DEBUG
        // `-demo YES` shows three computers and the whole week for App Store screenshots; `-pro YES` or `-pro NO` forces it.
        let args = UserDefaults.standard
        if args.bool(forKey: "demo") || args.object(forKey: "pro") != nil {
            set(args.object(forKey: "pro") == nil || args.bool(forKey: "pro"))
            return
        }
        #endif
        // Purchases made on another device, Ask to Buy approvals and refunds arrive here.
        updates = Task { [weak self] in
            for await result in Transaction.updates {
                if case .verified(let t) = result { await t.finish() }
                await self?.refresh()
            }
        }
        Task { await refresh(); await load() }
    }

    var price: String { product?.displayPrice ?? "$4.99" }

    func load() async {
        guard product == nil else { return }
        product = try? await Product.products(for: [Self.productID]).first
    }

    func refresh() async {
        var owned = false
        for await result in Transaction.currentEntitlements {
            if case .verified(let t) = result, t.productID == Self.productID, t.revocationDate == nil { owned = true }
        }
        if !owned {
            do {
                if case .verified(let app) = try await AppTransaction.shared,
                   let build = Int(app.originalAppVersion), build <= Self.lastFreeBuild { owned = true }
            } catch {
                // Offline or signed out: keep what we knew rather than take things away.
                owned = unlocked
            }
        }
        set(owned)
    }

    /// Buys Pro. Returns what to tell the person, or nil when they cancelled.
    func buy() async -> String? {
        await load()
        guard let product else { return "The App Store isn't reachable. Try again in a moment." }
        busy = true
        defer { busy = false }
        do {
            switch try await product.purchase() {
            case .success(.verified(let t)):
                await t.finish()
                set(true)
                return nil
            case .success(.unverified):
                return "The App Store couldn't confirm that purchase."
            case .pending:
                return "Waiting for approval. Pro unlocks as soon as it's approved."
            case .userCancelled:
                return nil
            @unknown default:
                return nil
            }
        } catch {
            return error.localizedDescription
        }
    }

    /// Restore Purchases: asks the App Store for what this Apple Account owns.
    func restore() async -> String {
        busy = true
        defer { busy = false }
        try? await AppStore.sync()
        await refresh()
        return unlocked ? "Pro restored" : "No Pro purchase on this Apple Account"
    }

    private func set(_ on: Bool) {
        Tier.unlocked = on
        if unlocked != on { unlocked = on }
    }
}

/// The upgrade screen.
struct Paywall: View {
    let reason: Pro.Reason
    @EnvironmentObject private var model: Model
    @ObservedObject private var pro = Pro.shared
    @Environment(\.dismiss) private var dismiss
    @State private var note: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                header
                VStack(spacing: 12) {
                    feature("laptopcomputer.and.iphone", Brand.sky, "Every computer you use",
                            "Link as many Macs, Windows PCs and Linux computers as you like. Free links one.")
                    feature("clock.arrow.circlepath", Brand.lavender, "Your whole week",
                            "Recent, Library, search and the keyboard show all 7 days ClipBubble keeps. Free shows the last 24 hours.")
                    feature("heart.fill", Brand.peach, "Pay once, keep it",
                            "No subscription, no account, no ads. Family Sharing included.")
                }
                if reason == .computers && !pro.unlocked {
                    Text("Or remove the computer you've linked in Settings, then link a different one for free.")
                        .font(.footnote).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .center).multilineTextAlignment(.center)
                }
            }
            .padding(24).padding(.top, 8)
        }
        .background(alignment: .top) {
            Circle().fill(Brand.sky.opacity(0.4)).frame(width: 440).blur(radius: 100).offset(x: 130, y: -220)
                .accessibilityHidden(true)
        }
        .background(Brand.background)
        .safeAreaInset(edge: .bottom) { actions }
        .overlay(alignment: .topTrailing) {
            Button { dismiss() } label: {
                Image(systemName: "xmark").font(.footnote.weight(.bold)).foregroundStyle(.secondary)
                    .frame(width: 30, height: 30).background(.thinMaterial, in: Circle())
                    .frame(width: 44, height: 44)
            }
            .padding(10)
            .accessibilityLabel("Close")
        }
        .task { await pro.load() }
        .onChange(of: pro.unlocked) { if pro.unlocked { model.say("Pro unlocked. Thank you!") } }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 12) {
            Mascot(size: 56)
                .frame(width: 84, height: 84)
                .background(Brand.gradient, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
                .shadow(color: Brand.sky.opacity(0.45), radius: 16, y: 8)
            HStack(spacing: 8) {
                Text("ClipBubble").font(.system(.largeTitle, design: .rounded).weight(.heavy))
                Text("PRO").font(.system(.subheadline, design: .rounded).weight(.heavy)).foregroundStyle(Brand.ink)
                    .padding(.horizontal, 9).padding(.vertical, 4)
                    .background(Brand.butter, in: Capsule())
            }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isHeader)
            Text(pro.unlocked ? "You have Pro. Thank you for supporting ClipBubble!" : headline)
                .font(.title3.weight(.medium)).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var headline: String {
        switch reason {
        case .computers: return "Free ClipBubble links one computer. Pro links all of them."
        case .history: return "Get back everything from the last 7 days, not just today."
        case .settings: return "Every computer and your whole week, for one small price."
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            if pro.unlocked {
                Button { dismiss() } label: { Text("Done").frame(maxWidth: .infinity) }.buttonStyle(GlowButton())
            } else {
                Button {
                    Task {
                        note = await pro.buy()
                        if pro.unlocked { dismiss() }
                    }
                } label: {
                    HStack(spacing: 8) {
                        if pro.busy { ProgressView().tint(Brand.ink) }
                        Text("Unlock Pro for \(pro.price)")
                    }
                    .frame(maxWidth: .infinity)
                }
                .buttonStyle(GlowButton())
                .disabled(pro.busy)
                Text("One-time purchase").font(.caption.weight(.medium)).foregroundStyle(.secondary)
                Button("Restore Purchase") { Task { note = await pro.restore() } }
                    .font(.subheadline.weight(.semibold)).foregroundStyle(Brand.tint)
                    .frame(minHeight: 44)
                    .disabled(pro.busy)
            }
            if let note {
                Text(note).font(.footnote).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .padding(.horizontal, 24).padding(.top, 12).padding(.bottom, 4)
        .background(Brand.background)
    }

    private func feature(_ symbol: String, _ color: Color, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            IconTile(symbol: symbol, color: color, size: 40, filled: true)
            VStack(alignment: .leading, spacing: 4) {
                Text(title).font(.headline).fontDesign(.rounded)
                Text(detail).font(.subheadline).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .brandCard()
        .accessibilityElement(children: .combine)
    }
}

/// At the end of a list on the free tier: how much more Pro would show.
struct LockedHistory: View {
    let count: Int
    let unlock: () -> Void

    var body: some View {
        Button(action: unlock) {
            HStack(spacing: 14) {
                IconTile(symbol: "lock.fill", color: Brand.butter, size: 40, filled: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(count == 1 ? "1 older item" : "\(count) older items").font(.headline).fontDesign(.rounded)
                        .foregroundStyle(.primary)
                    Text("Free shows the last 24 hours. Pro shows all 7 days.")
                        .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.leading)
                }
                Spacer(minLength: 0)
                Text("Unlock").font(.subheadline.weight(.bold)).fontDesign(.rounded).foregroundStyle(Brand.ink)
                    .padding(.horizontal, 14).padding(.vertical, 8)
                    .background(Brand.sky, in: Capsule())
            }
            .brandCard()
        }
        .buttonStyle(Pressable())
        .accessibilityHint("Opens ClipBubble Pro")
    }
}
