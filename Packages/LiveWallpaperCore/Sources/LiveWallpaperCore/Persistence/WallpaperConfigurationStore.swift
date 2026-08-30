import Foundation
import CoreGraphics

/// Persistence seam (SettingsManager in app; in-memory in tests).
@MainActor
public protocol ScreenConfigurationPersisting {
    func getConfiguration(for screenID: CGDirectDisplayID) -> ScreenConfiguration?
    func saveConfiguration(_ configuration: ScreenConfiguration)
    func cleanSettingsForScreen(_ screenID: CGDirectDisplayID)
    func loadConfigurations() -> [ScreenConfiguration]
    func replaceAllConfigurations(_ configurations: [ScreenConfiguration])
}

/// In-memory per-screen config cache; persistence via injected protocol.
@MainActor
public final class WallpaperConfigurationStore {
    private var cache: [CGDirectDisplayID: ScreenConfiguration] = [:]
    /// Semantic revision for prepared wallpaper CAS; advances even on equal value.
    private var revisions: [CGDirectDisplayID: UInt64] = [:]
    private let persistence: any ScreenConfigurationPersisting

    public init(persistence: any ScreenConfigurationPersisting) {
        self.persistence = persistence
    }

    public func get(for screenID: CGDirectDisplayID) -> ScreenConfiguration? {
        if let cached = cache[screenID] {
            return cached
        }

        guard let configuration = persistence.getConfiguration(for: screenID) else {
            return nil
        }

        cache[screenID] = configuration
        return configuration
    }

    /// Prefer display ID; miss → fingerprint match and migrate to current ID.
    public func get(
        for screenID: CGDirectDisplayID,
        fingerprint: String?
    ) -> ScreenConfiguration? {
        if let direct = get(for: screenID) {
            // ID recycled onto a different panel: trust fingerprint, not ID;
            // evict stale binding and fall through to fingerprint scan.
            if let fingerprint, !fingerprint.isUnknownDisplayFingerprint,
               let cachedFingerprint = direct.displayFingerprint,
               !cachedFingerprint.isUnknownDisplayFingerprint,
               cachedFingerprint != fingerprint {
                cache.removeValue(forKey: screenID)
                return migrateByFingerprint(to: screenID, fingerprint: fingerprint)
            }
            // Missing/unknown fingerprint: reuse ID slot and back-fill.
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

    /// Re-key one display's stored configuration when its fingerprint format changes (EDID →
    /// per-display UUID). Runs once per display; refuses to act when the new key already has a
    /// config, so two panels that used to share an ambiguous EDID key cannot both claim it.
    /// `screenID` is the display doing the migrating. Two identical serial-0 panels stored one row
    /// each under the same legacy key, so row order alone would hand one panel the other's
    /// wallpaper; the row whose `screenID` matches wins, and a tie with no match is refused rather
    /// than guessed.
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
        cache[migrated.screenID] = migrated
        bumpRevision(for: migrated.screenID)
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

        cache[screenID] = match
        bumpRevision(for: screenID)
        if oldScreenID != screenID {
            cache.removeValue(forKey: oldScreenID)
            bumpRevision(for: oldScreenID)
        }
        return match
    }

    public func save(_ config: ScreenConfiguration) {
        bumpRevision(for: config.screenID)
        cache[config.screenID] = config
        persistence.saveConfiguration(config)
    }

    public func remove(for screenID: CGDirectDisplayID) {
        bumpRevision(for: screenID)
        cache.removeValue(forKey: screenID)
        persistence.cleanSettingsForScreen(screenID)
    }

    /// CAS snapshot for async wallpaper prepare; commit only if revision still matches.
    public func revision(for screenID: CGDirectDisplayID) -> UInt64 {
        revisions[screenID] ?? 0
    }

    private func bumpRevision(for screenID: CGDirectDisplayID) {
        revisions[screenID] = (revisions[screenID] ?? 0) &+ 1
    }

    public func clearCache() {
        cache.removeAll()
    }

    public func loadAll() -> [ScreenConfiguration] {
        let configs = persistence.loadConfigurations()
        cache = Self.cacheKeyedByScreenID(configs)
        return configs
    }

    /// Duplicate screenIDs: keep later entry + log (must not trap at launch).
    private static func cacheKeyedByScreenID(
        _ configs: [ScreenConfiguration]
    ) -> [CGDirectDisplayID: ScreenConfiguration] {
        let keyed = Dictionary(configs.map { ($0.screenID, $0) }, uniquingKeysWith: { _, later in later })
        if keyed.count != configs.count {
            Logger.warning(
                "Duplicate screenID entries in persisted configurations (\(configs.count - keyed.count) shadowed); keeping the later entry",
                category: .settings
            )
        }
        return keyed
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

        cache = Self.cacheKeyedByScreenID(pruned)
        persistence.replaceAllConfigurations(pruned)
        for screenID in invalidIDs {
            bumpRevision(for: screenID)
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
