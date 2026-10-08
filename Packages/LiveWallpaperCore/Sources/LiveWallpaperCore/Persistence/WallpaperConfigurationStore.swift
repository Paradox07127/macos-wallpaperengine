import Foundation
import CoreGraphics

@MainActor
public protocol ScreenConfigurationPersisting {
    /// Latest in-memory row, independent of disk durability; nil opts out.
    func configurationRevision(for screenID: CGDirectDisplayID) -> UInt64?
    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration?
    func saveConfiguration(_ configuration: ScreenConfiguration)
    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID)
    func loadConfigurations() -> [ScreenConfiguration]
    func replaceAllConfigurations(_ configurations: [ScreenConfiguration])
}

public extension ScreenConfigurationPersisting {
    func configurationRevision(for _: CGDirectDisplayID) -> UInt64? {
        nil
    }
}

@MainActor
public final class WallpaperConfigurationStore {
    /// Semantic revision for prepared wallpaper CAS; advances even on equal value.
    private var revisions: [CGDirectDisplayID: UInt64] = [:]
    private var persistenceRevisions: [CGDirectDisplayID: UInt64] = [:]
    private let persistence: any ScreenConfigurationPersisting

    public init(persistence: any ScreenConfigurationPersisting) {
        self.persistence = persistence
    }

    public func get(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        synchronizePersistenceRevision(for: screenID)
        return persistence.getConfiguration(for: screenID)
    }

    /// Prefer display ID; miss → fingerprint match and migrate to current ID.
    public func get(
        for screenID: CGDirectDisplayID,
        fingerprint: String?
    ) -> ScreenConfiguration? {
        if let direct = get(for: screenID) {
            // ID recycled onto a different panel: trust fingerprint, not ID.
            if let fingerprint, !fingerprint.isUnknownDisplayFingerprint,
               let storedFingerprint = direct.displayFingerprint,
               !storedFingerprint.isUnknownDisplayFingerprint,
               storedFingerprint != fingerprint {
                return migrateByFingerprint(to: screenID, fingerprint: fingerprint)
            }
            if let fingerprint, !fingerprint.isUnknownDisplayFingerprint,
               direct.displayFingerprint != fingerprint {
                var stamped = direct
                stamped.displayFingerprint = fingerprint
                save(stamped)
                return stamped
            }
            return direct
        }

        guard let fingerprint, !fingerprint.isUnknownDisplayFingerprint else {
            return nil
        }

        return migrateByFingerprint(to: screenID, fingerprint: fingerprint)
    }

    /// Re-keys one display's stored configuration when the fingerprint format changes
    /// (EDID → per-display UUID). Refuses when the new key already has a config; with two
    /// rows under one legacy key the row whose `screenID` matches wins, and a tie is refused.
    @discardableResult
    public func migrateFingerprint(
        from legacy: String,
        to current: String,
        preferring screenID: CGDirectDisplayID? = nil
    ) -> Bool {
        guard legacy != current,
              !legacy.isUnknownDisplayFingerprint,
              !current.isUnknownDisplayFingerprint else { return false }

        var all = persistence.loadConfigurations()
        guard !all.contains(where: { $0.displayFingerprint == current }) else { return false }

        let candidates = all.indices.filter { all[$0].displayFingerprint == legacy }
        guard let index = candidates.first(where: { all[$0].screenID == screenID })
                ?? (candidates.count == 1 ? candidates.first : nil)
        else { return false }

        all[index].displayFingerprint = current
        let migrated = all[index]
        persistence.replaceAllConfigurations(all)
        bumpRevision(for: migrated.screenID)
        acknowledgePersistenceRevision(for: migrated.screenID)
        return true
    }

    /// Parked configs use `kCGNullDirectDisplay` so they cannot shadow a live ID.
    public static let parkedScreenID: CGDirectDisplayID = 0

    private func migrateByFingerprint(
        to screenID: CGDirectDisplayID,
        fingerprint: String
    ) -> ScreenConfiguration? {
        let all = persistence.loadConfigurations()
        guard let matchIndex = all.firstIndex(where: { $0.displayFingerprint == fingerprint }) else {
            return nil
        }
        var match = all[matchIndex]
        let oldScreenID = match.screenID
        match.screenID = screenID
        match.displayFingerprint = fingerprint

        var updated = all
        updated.remove(at: matchIndex)

        // ID collision with another panel's config: park so fingerprint can reclaim.
        if let displacedIndex = updated.firstIndex(where: { $0.screenID == screenID }),
           let displacedFingerprint = updated[displacedIndex].displayFingerprint,
           !displacedFingerprint.isUnknownDisplayFingerprint,
           displacedFingerprint != fingerprint {
            var parked = updated[displacedIndex]
            parked.screenID = Self.parkedScreenID
            // Fresher parked copy wins for the same panel.
            updated.removeAll {
                $0.screenID == Self.parkedScreenID && $0.displayFingerprint == displacedFingerprint
            }
            updated.removeAll { $0.screenID == screenID }
            updated.append(parked)
        } else {
            // Unknown/equal fingerprint: legacy replace-by-screenID.
            updated.removeAll { $0.screenID == screenID }
        }
        updated.append(match)
        persistence.replaceAllConfigurations(updated)

        bumpRevision(for: screenID)
        acknowledgePersistenceRevision(for: screenID)
        if oldScreenID != screenID {
            bumpRevision(for: oldScreenID)
            acknowledgePersistenceRevision(for: oldScreenID)
        }
        return match
    }

    public func save(_ config: ScreenConfiguration) {
        bumpRevision(for: config.screenID)
        persistence.saveConfiguration(config)
        acknowledgePersistenceRevision(for: config.screenID)
    }

    public func remove(for screenID: CGDirectDisplayID) {
        bumpRevision(for: screenID)
        persistence.cleanSettingsForScreen(screenID)
        acknowledgePersistenceRevision(for: screenID)
    }

    /// CAS snapshot for async wallpaper prepare; commit only if revision still matches.
    public func revision(for screenID: CGDirectDisplayID) -> UInt64 {
        synchronizePersistenceRevision(for: screenID)
        return revisions[screenID] ?? 0
    }

    private func synchronizePersistenceRevision(for screenID: CGDirectDisplayID) {
        guard let current = persistence.configurationRevision(for: screenID) else { return }
        if let previous = persistenceRevisions.updateValue(current, forKey: screenID), previous != current {
            bumpRevision(for: screenID)
        }
    }

    private func acknowledgePersistenceRevision(for screenID: CGDirectDisplayID) {
        persistenceRevisions[screenID] = persistence.configurationRevision(for: screenID)
    }

    private func synchronizePersistenceRevisions() {
        for screenID in Set(revisions.keys).union(persistenceRevisions.keys) {
            synchronizePersistenceRevision(for: screenID)
        }
    }

    private func bumpRevision(for screenID: CGDirectDisplayID) {
        revisions[screenID] = (revisions[screenID] ?? 0) &+ 1
    }

    public func loadAll() -> [ScreenConfiguration] {
        let configs = persistence.loadConfigurations()
        synchronizePersistenceRevisions()
        for config in configs {
            acknowledgePersistenceRevision(for: config.screenID)
        }
        Self.warnOnDuplicateScreenIDs(configs)
        return configs
    }

    /// Duplicate screenIDs are logged, never trapped on: they can reach disk and must not stop launch.
    private static func warnOnDuplicateScreenIDs(_ configs: [ScreenConfiguration]) {
        let shadowed = configs.count - Set(configs.map(\.screenID)).count
        if shadowed > 0 {
            Logger.warning(
                "Duplicate screenID entries in persisted configurations (\(shadowed) shadowed)",
                category: .settings
            )
        }
    }

    public func pruneInvalidResourceConfigurations(using validator: (CGDirectDisplayID) -> Bool) -> [CGDirectDisplayID] {
        let candidateIDs = persistence
            .loadConfigurations()
            .filter(Self.requiresResourceValidation)
            .map(\.screenID)

        let invalidIDs = Set(candidateIDs.filter { !validator($0) })

        guard !invalidIDs.isEmpty else {
            _ = loadAll()
            return []
        }

        let postValidationConfigs = persistence.loadConfigurations()
        let pruned = Self.removingInvalidResourceConfigurations(
            from: postValidationConfigs,
            invalidScreenIDs: invalidIDs
        )

        synchronizePersistenceRevisions()
        Self.warnOnDuplicateScreenIDs(pruned)
        persistence.replaceAllConfigurations(pruned)
        for screenID in invalidIDs {
            bumpRevision(for: screenID)
            acknowledgePersistenceRevision(for: screenID)
        }

        return Array(invalidIDs)
    }

    public nonisolated static func removingInvalidResourceConfigurations(
        from configs: [ScreenConfiguration],
        invalidScreenIDs: Set<CGDirectDisplayID>
    ) -> [ScreenConfiguration] {
        configs.filter { config in
            guard invalidScreenIDs.contains(config.screenID),
                  requiresResourceValidation(config) else {
                return true
            }
            return false
        }
    }

    nonisolated private static func requiresResourceValidation(_ config: ScreenConfiguration) -> Bool {
        guard let definition = WallpaperSessionDefinition(configuration: config) else {
            return true
        }

        switch definition {
        case .video:
            return true
        case .html(let source, _):
            if case .file = source { return true }
            if case .folder = source { return true }
            return false
        case .scene:
            return false
        }
    }
}
