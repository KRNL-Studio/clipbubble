import Foundation

/// iOS-only handoff for sharing while the app has a live session, and for files above the auto-fetch limit.
enum ShareSync {
    // Accessed only on SyncEngine.queue.
    private final class Link {
        weak var session: Session?
        var offered: Set<String> = []
        var reconciled = false

        init(_ session: Session) { self.session = session }
    }

    private static var links: [Link] = []

    static func observe(_ session: Session, over transport: SSHChannelTransport) {
        links.removeAll { $0.session?.closed != false }
        let link = Link(session)
        links.append(link)
        transport.didReceive = { [weak link] in
            guard let link, !link.reconciled, let s = link.session, s.summarized, !s.closed else { return }
            link.reconciled = true
            offerLargeFiles(to: [link])
        }
    }

    /// Local DB.changed is process-local. Replay the shared DB stamps against Session.known on wake.
    static func refresh() {
        SyncEngine.shared.queue.async {
            links.removeAll { $0.session?.closed != false }
            guard !links.isEmpty else { return }
            DB.changed?(DB().stamps().map(\.hash))
            offerLargeFiles(to: links)
        }
    }

    private static func offerLargeFiles(to links: [Link]) {
        let ready = links.filter { $0.session?.summarized == true }
        guard !ready.isEmpty else { return }
        let db = DB()
        let engine = SyncEngine.shared
        for clip in db.clips(limit: -1, kind: "file", source: ShareOutbox.source)
        where clip.source == ShareOutbox.source && clip.origin.isEmpty && !clip.remote {
            let sizes = clip.paths.compactMap {
                (try? FileManager.default.attributesOfItem(atPath: $0)[.size] as? NSNumber)?.int64Value
            }
            guard (Sync.blobSize(sizes) ?? .max) > Sync.autoFetchLimit else { continue }
            guard let stamp = db.stamp(hash: clip.hash), !stamp.deleted else { continue }
            for link in ready {
                guard let s = link.session, let peer = s.peer,
                      !link.offered.contains(clip.hash),
                      stamp.beats(s.known[clip.hash]) || s.fetchable[clip.hash] != nil else { continue }
                link.offered.insert(clip.hash)
                engine.send(clip.hash, toDevice: peer.device)
            }
        }
    }
}
