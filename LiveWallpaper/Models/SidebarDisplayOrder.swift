import CoreGraphics
import Foundation

enum SidebarDisplayOrder {
    static let preferencesKey = "loomscreen.sidebar.displayOrder.v1"

    struct Entry: Codable, Equatable {
        let displayID: CGDirectDisplayID
        let fingerprint: String

        init(displayID: CGDirectDisplayID, fingerprint: String) {
            self.displayID = displayID
            self.fingerprint = fingerprint
        }

        init(screen: Screen) {
            self.init(displayID: screen.id, fingerprint: screen.displayFingerprint)
        }
    }

    /// Match on display ID plus fingerprint: identical serial-0 panels shared one legacy fingerprint.
    static func rekeyed(
        _ entries: [Entry],
        displayID: CGDirectDisplayID,
        from legacy: String,
        to current: String
    ) -> [Entry] {
        entries.map { entry in
            guard entry.displayID == displayID, entry.fingerprint == legacy else { return entry }
            return Entry(displayID: entry.displayID, fingerprint: current)
        }
    }

    static func decode(_ data: Data) -> [Entry] {
        guard !data.isEmpty else { return [] }
        return (try? JSONDecoder().decode([Entry].self, from: data)) ?? []
    }

    static func encode(_ entries: [Entry]) -> Data {
        (try? JSONEncoder().encode(entries)) ?? Data()
    }

    static func orderedDisplayIDs(from available: [Entry], storedOrder: [Entry]) -> [CGDirectDisplayID] {
        var remaining = available
        var ordered = [Entry]()
        let availableFingerprintCounts = Dictionary(grouping: available, by: \.fingerprint).mapValues(\.count)
        let storedFingerprintCounts = Dictionary(grouping: storedOrder, by: \.fingerprint).mapValues(\.count)

        for storedEntry in storedOrder {
            let exactMatch = remaining.firstIndex { candidate in
                candidate.displayID == storedEntry.displayID
                    && candidate.fingerprint == storedEntry.fingerprint
            }
            // Fingerprint fallback is truthful only when it identifies one row on both sides; count from the original collections.
            let canUseFingerprintFallback = !isUnknownFingerprint(storedEntry.fingerprint)
                && availableFingerprintCounts[storedEntry.fingerprint] == 1
                && storedFingerprintCounts[storedEntry.fingerprint] == 1
            let fingerprintMatch = canUseFingerprintFallback
                ? remaining.firstIndex { candidate in
                    candidate.fingerprint == storedEntry.fingerprint
                        && !isUnknownFingerprint(candidate.fingerprint)
                }
                : nil

            guard let index = exactMatch ?? fingerprintMatch else { continue }
            ordered.append(remaining.remove(at: index))
        }

        ordered.append(contentsOf: remaining)
        return ordered.map(\.displayID)
    }

    private static func isUnknownFingerprint(_ fingerprint: String) -> Bool {
        fingerprint.hasPrefix("unknown:")
    }
}
