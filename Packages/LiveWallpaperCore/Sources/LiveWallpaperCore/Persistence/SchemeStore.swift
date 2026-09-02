import Foundation
import Observation

/// Persistence seam (SettingsManager in app; in-memory in tests).
@MainActor
public protocol SchemePersisting {
    func load() -> [ScreenScheme]
    func save(_ schemes: [ScreenScheme])
}

/// Saved per-display setups. App-wired `.shared` lives in SettingsManagerStoreBindings.swift.
@MainActor
@Observable
public final class SchemeStore {
    public private(set) var schemes: [ScreenScheme]
    @ObservationIgnored private let persistence: any SchemePersisting

    public init(persistence: any SchemePersisting) {
        self.persistence = persistence
        schemes = persistence.load()
    }

    @discardableResult
    public func add(
        name: String,
        configuration: ScreenConfiguration,
        overlay: MonitorOverlayConfiguration,
        sourceDisplayName: String? = nil
    ) -> ScreenScheme {
        let trimmedSource = sourceDisplayName?.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedName = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let scheme = ScreenScheme(
            name: trimmedName.isEmpty ? (trimmedSource ?? "") : trimmedName,
            configuration: configuration,
            overlay: overlay,
            sourceDisplayName: trimmedSource
        )
        schemes.append(scheme)
        persist()
        Logger.info("Scheme added: total \(schemes.count)", category: .ui)
        return scheme
    }

    public func remove(_ id: UUID) {
        let countBefore = schemes.count
        schemes.removeAll { $0.id == id }
        guard schemes.count != countBefore else { return }
        persist()
        Logger.info("Scheme removed: total \(schemes.count)", category: .ui)
    }

    public func rename(_ id: UUID, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let index = schemes.firstIndex(where: { $0.id == id }),
              schemes[index].name != trimmed else { return }
        schemes[index].name = trimmed
        schemes[index].updatedAt = Date()
        persist()
        Logger.info("Scheme renamed", category: .ui)
    }

    public func reload() {
        schemes = persistence.load()
    }

    public func resetAfterSettingsCleared() {
        schemes.removeAll()
    }

    /// A scheme is a third copy of a security-scoped grant, next to the live
    /// screen configuration and the bookmark library. When the system hands the
    /// app a refreshed grant those two get rewritten; without this the archived
    /// copy keeps the dead one and the scheme silently stops resolving.
    @discardableResult
    public func replaceHTMLBookmark(matching original: Data, with refreshed: Data) -> Int {
        var changed = 0
        for index in schemes.indices {
            guard let updated = schemes[index].configuration.replacingHTMLBookmark(
                matching: original,
                with: refreshed
            ) else { continue }
            schemes[index].configuration = updated
            changed += 1
        }
        if changed > 0 {
            persist()
        }
        return changed
    }

    @discardableResult
    public func replaceWPEOriginBookmark(
        workshopID: String,
        matching original: Data,
        with refreshed: Data
    ) -> Int {
        var changed = 0
        for index in schemes.indices {
            guard let updated = schemes[index].configuration.replacingWPEOriginBookmark(
                workshopID: workshopID,
                matching: original,
                with: refreshed
            ) else { continue }
            schemes[index].configuration = updated
            changed += 1
        }
        if changed > 0 {
            persist()
        }
        return changed
    }

    private func persist() {
        persistence.save(schemes)
    }
}
