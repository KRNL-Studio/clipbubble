import Foundation

/// A best-effort, time-bounded delivery of clips that are already durable.
@MainActor
enum Courier {
    private static var receipts: [UUID: (String, String) -> Void] = [:]
    private static var previousOnApplied: ((String, String) -> Void)?

    /// Adds the items, waits for a link, and returns once a computer has them on its clipboard or `timeout` passes.
    /// Whatever didn't make it still syncs the next time ClipBubble opens.
    static func deliver(timeout: Double = 25, status: @escaping (String) -> Void = { _ in },
                        add: @escaping () async -> [String]) async -> String {
        guard !Task.isCancelled else { return "Delivery stopped." }
        let engine = SyncEngine.shared
        guard !SyncEngine.enabledHosts.isEmpty else {
            let hashes = await add()
            guard !Task.isCancelled else { return "Delivery stopped." }
            return hashes.isEmpty ? "Couldn't save that." : "Saved. Link a computer in ClipBubble to send it there."
        }
        let discovery = SyncEngine.enabledHosts.contains(where: DirectPeers.isDirect) ? Pairing.browseNearby() : nil
        defer { discovery?.stop() }
        engine.hold(true)
        defer { engine.hold(false) }
        engine.start()
        status("Connecting…")
        // Saved before the wait, so you can walk away from the share sheet with nothing lost.
        let hashes = await add()
        guard !Task.isCancelled else { return "Delivery stopped." }
        guard !hashes.isEmpty else { return "Couldn't save that." }
        let wasLinked = engine.statuses.values.contains { $0.ok }
        let linked = await until(seconds: 10) { engine.statuses.values.contains { $0.ok } }
        guard !Task.isCancelled else { return "Delivery stopped." }
        // A computer only takes what's just been copied onto its clipboard, so the wait mustn't count against it.
        if linked, !wasLinked {
            let now = Date().timeIntervalSince1970
            hashes.forEach { DB().bump(hash: $0, to: now) }
        }
        guard linked else {
            // Connecting or offline needs nothing from you; anything else (an untrusted host, a missing key) does.
            if let (alias, state) = engine.statuses.first(where: { !$0.value.ok }) {
                switch state {
                case .connecting, .offline: break
                default: return "Saved. \(state.phoneText(for: alias)). It goes over once that's fixed."
                }
            }
            return "Saved. It goes to your computer next time ClipBubble connects."
        }
        let peers = engine.linked
        let names = Set(peers.map(\.name))
        let destinations = Set(peers.map(Pairing.displayName(of:))).sorted().joined(separator: ", ")
        status("Sending to \(destinations)…")
        // Each item and computer that confirmed it, so two of three photos arriving isn't reported as all of them.
        var got: Set<String> = []
        let (wasApplied, wasTransfers) = (engine.onApplied, engine.onTransfers)
        engine.onApplied = { hash, peer in wasApplied(hash, peer); if hashes.contains(hash) { got.insert(hash + "\n" + peer) } }
        engine.onTransfers = { t in
            wasTransfers(t)
            let sending = t.values.filter(\.sending)
            if !sending.isEmpty {
                let done = sending.map(\.done).reduce(0, +), total = max(1, sending.map(\.total).reduce(0, +))
                status("Sending… \(Int(Double(done) / Double(total) * 100))%")
            }
        }
        defer {
            engine.onApplied = wasApplied
            engine.onTransfers = wasTransfers
        }
        // Big files wait for Get on the computer; sending them from here means you want them there now.
        for h in hashes where h.hasPrefix("f:") { engine.linked.forEach { engine.send(h, toDevice: $0.device) } }
        _ = await until(seconds: timeout) { got.count >= names.count * hashes.count }
        guard !Task.isCancelled else { return "Delivery stopped." }
        // No answer yet doesn't mean it arrived: it's saved here and syncs again next time.
        if got.isEmpty { return "Saved. Still waiting for \(destinations) to confirm." }
        if names.allSatisfy({ name in hashes.allSatisfy { got.contains($0 + "\n" + name) } }) {
            return "On the clipboard of \(destinations)."
        }
        return "Saved. Some items are still on their way to \(destinations)."
    }

    private static func until(seconds: Double, _ cond: () -> Bool) async -> Bool {
        let clock = ContinuousClock()
        let end = clock.now + .seconds(seconds)
        while !Task.isCancelled, clock.now < end {
            if cond() { return true }
            try? await Task.sleep(nanoseconds: 100_000_000)
        }
        return !Task.isCancelled && cond()
    }

    static func deliverSaved(_ hashes: [String], timeout: Double = 8) async -> String {
        let hashes = Set(hashes)
        guard !hashes.isEmpty else { return "Couldn't save that." }
        guard !SyncEngine.enabledHosts.isEmpty else { return "Saved in ClipBubble. Link a computer to sync." }
        let saved = "Saved in ClipBubble. It will sync when connected."
        guard !Task.isCancelled, !SyncEngine.paused else { return saved }

        let engine = SyncEngine.shared
        let discovery = SyncEngine.enabledHosts.contains(where: DirectPeers.isDirect) ? Pairing.browseNearby() : nil
        defer { discovery?.stop() }
        var applied: [String: Set<String>] = [:]
        let id = UUID()
        if receipts.isEmpty {
            previousOnApplied = engine.onApplied
            engine.onApplied = { hash, peer in
                previousOnApplied?(hash, peer)
                for receipt in receipts.values { receipt(hash, peer) }
            }
        }
        receipts[id] = { hash, peer in
            if hashes.contains(hash) { applied[peer, default: []].insert(hash) }
        }
        engine.hold(true)
        engine.suspend(true)
        defer {
            engine.hold(false)
            receipts[id] = nil
            if receipts.isEmpty, let previousOnApplied {
                engine.onApplied = previousOnApplied
                self.previousOnApplied = nil
            }
        }

        engine.start()
        let clock = ContinuousClock()
        let deadline = clock.now + .seconds(timeout)
        while !Task.isCancelled, clock.now < deadline {
            let peers = engine.linked
            let names = Set(peers.map(\.name))
            if peers.count == names.count, !names.isEmpty,
               names.allSatisfy({ applied[$0] == hashes }) {
                let destinations = peers.map(Pairing.displayName(of:)).sorted().joined(separator: ", ")
                return "On the clipboard of \(destinations)."
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
        return saved
    }
}
