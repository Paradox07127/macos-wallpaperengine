import Foundation

/// Back off when logs are quiet. Liveness sampling has a separate, slower clock.
struct AgentPollingPolicy {
    private var quietTicks = 0

    mutating func interval(changed: Bool, working: Bool, catchingUp: Bool = false) -> TimeInterval {
        if catchingUp {
            quietTicks = 0; return 0.25
        }
        if changed {
            quietTicks = 0; return 0.75
        }
        quietTicks = min(quietTicks + 1, 8)
        return working ? min(3, 0.75 * Double(quietTicks + 1)) : min(10, 2 * Double(quietTicks + 1))
    }
}

/// A bounded sweep complements the fast recent-date scan. Resumed sessions keep
/// their original date shard, so a date-only discovery can never find them.
final class AgentHistoryDiscovery {
    private var enumerator: FileManager.DirectoryEnumerator?
    private var known: Set<URL> = []
    private let root: URL

    init(root: URL) {
        self.root = root
    }

    func scan(now: Date, budget: Int = 256) -> [URL] {
        guard (try? root.resourceValues(forKeys: [.isSymbolicLinkKey]))?.isSymbolicLink == false else { return [] }
        if enumerator == nil {
            enumerator = FileManager.default.enumerator(
                at: root, includingPropertiesForKeys: [.isSymbolicLinkKey, .isRegularFileKey],
                options: [.skipsHiddenFiles], errorHandler: { _, _ in true }
            )
        }
        for _ in 0 ..< budget {
            guard let url = enumerator?.nextObject() as? URL else { enumerator = nil; break }
            let values = try? url.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey])
            if values?.isSymbolicLink == true {
                enumerator?.skipDescendants(); continue
            }
            if values?.isRegularFile == true, url.pathExtension == "jsonl", url.lastPathComponent.hasPrefix("rollout-") {
                known.insert(url)
            }
        }
        // Re-stat cached URLs: URL resource values themselves cache stale mtimes.
        let cutoff = now.addingTimeInterval(-48 * 3600)
        known = Set(known.filter {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: $0.path),
                  let modified = attrs[.modificationDate] as? Date else { return false }
            return modified >= cutoff
        }.sorted { $0.path < $1.path }.prefix(256))
        return Array(known)
    }
}
