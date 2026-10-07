#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

extension WPECacheManagementView {
    func refreshStats() async {
        await refreshInventory()
    }

    private var storageLocations: [AppStorageLocation] {
        AppStorageLocation.current(systemWallpaperRoot: exportService.videosDirectory.deletingLastPathComponent())
    }

    private func refreshInventory() async {
        inventoryScan?.cancel()
        storageScan?.cancel()
        inventoryGeneration &+= 1
        let generation = inventoryGeneration
        isLoading = true
        isLoadingInventory = true
        let locations = storageLocations
        let externalRoots = [
            exportService.videosDirectory,
            WPEEngineAssetsLibrary.shared.resolveAuthorizedRoot(),
            (try? doctorService.resolveWorkdirURL())?.appendingPathComponent("steamapps/workshop/content/431960", isDirectory: true),
        ].compactMap(\.self)
        let protectedRoots = locations.filter {
            [.steamProfiles, .credentials, .application, .configuration, .preferences, .webData, .steamTools, .systemMetadata].contains($0.kind)
        }.map(\.url)
        let linked = await StorageLinkedSources.current(excluding: externalRoots + protectedRoots)
        guard generation == inventoryGeneration, !Task.isCancelled else { return }
        let appScan = Task { await StorageLinkedSources.scan(linked.sources, locations: locations, excluding: externalRoots) }
        let scan = Task { await WPEStorageInventory.compute(doctor: doctorService) }
        storageScan = appScan
        inventoryScan = scan
        let measured = await appScan.value
        let scanned = await scan.value
        guard generation == inventoryGeneration else { return }
        guard !Task.isCancelled else { return }
        storageMeasurements = measured
        inventory = scanned
        linkedSources = linked.sources
        unresolvedSources = linked.unresolved
        inventoryScan = nil
        storageScan = nil
        isLoading = false
        isLoadingInventory = false
        #if DEBUG
        await refreshTestArtifacts()
        #endif
    }

    private func measureCaches(_ kinds: Set<AppStorageLocation.Kind>) async -> [AppStorageMeasurement] {
        let locations = storageLocations
        let targets = locations.filter { kinds.contains($0.kind) }
        let others = locations.filter { !kinds.contains($0.kind) }.map(\.url)
        return await AppStorageScanner.shared.scan(targets, excluding: others)
    }

    func clearCache(_ kind: AppStorageLocation.Kind) async {
        guard !isClearing else { return }
        isClearing = true
        defer { isClearing = false }
        let before = await measureCaches([kind])
        do { try await performClear(kind) } catch { errorMessage = error.localizedDescription }
        let after = await measureCaches([kind])
        lastStorageFreedBytes = Self.freedBytes(of: [kind], before: before, after: after)
        await refreshStats()
    }

    private func performClear(_ kind: AppStorageLocation.Kind) async throws {
        switch kind {
        case .video: _ = await WPEVideoTextureDiskCache.shared.purgeAll()
        case .query: await workshopServices.queryCache.clear()
        case .previews: await WorkshopPreviewDiskCache.shared.clear()
        case .shaders:
            try await Task.detached(priority: .utility) { try WPEShaderTranslationCache.shared.clearCache() }.value
        case .audio: try await OggAudioTranscoder.shared.clearCache()
        case .webCache:
            await WebCacheMaintenance.clear()
        default: break
        }
    }

    private func clearAllCaches() async {
        guard !isClearing else { return }
        isClearing = true
        defer { isClearing = false }
        let kinds = Set(AppStorageLocation.Kind.allCases.filter(\.canClear))
        let before = await measureCaches(kinds)
        for kind in AppStorageLocation.Kind.allCases where kind.canClear {
            do { try await performClear(kind) } catch { errorMessage = error.localizedDescription }
        }
        let after = await measureCaches(kinds)
        lastStorageFreedBytes = Self.freedBytes(of: kinds, before: before, after: after)
        await refreshStats()
    }

    /// Sums each target location's shrink only, so caches that grow during the clear do not offset it.
    /// nil = a target could not be read in full before or after the clear, so no figure is exact.
    static func freedBytes(
        of kinds: Set<AppStorageLocation.Kind>, before: [AppStorageMeasurement], after: [AppStorageMeasurement]
    ) -> UInt64? {
        let targets = before.filter { kinds.contains($0.location.kind) }
        let targetsAfter = after.filter { kinds.contains($0.location.kind) }
        guard !targets.contains(where: { $0.status == .partial || $0.status == .unavailable }),
              !targetsAfter.contains(where: { $0.status == .partial || $0.status == .unavailable }) else { return nil }
        let remaining = Dictionary(targetsAfter.map { ($0.id, $0.bytes) }, uniquingKeysWith: +)
        return targets.reduce(0) { freed, measurement in
            let left = remaining[measurement.id] ?? 0
            return freed + (measurement.bytes > left ? measurement.bytes - left : 0)
        }
    }

    func confirmClearAllCaches() {
        let size = byteFormatter.string(fromByteCount: Int64(clamping: clearableBytes))
        pendingDestructive = PendingDestructive(.clearAllStorageCaches(byteSize: size)) {
            Task { await clearAllCaches() }
        }
    }
}
#endif
