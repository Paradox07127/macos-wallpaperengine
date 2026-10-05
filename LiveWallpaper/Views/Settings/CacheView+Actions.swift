#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

extension WPECacheManagementView {
    func refreshStats() async {
        await refreshInventory()
    }

    private func refreshInventory() async {
        inventoryScan?.cancel()
        storageScan?.cancel()
        inventoryGeneration &+= 1
        let generation = inventoryGeneration
        isLoading = true
        isLoadingInventory = true
        let locations = AppStorageLocation.current(systemWallpaperRoot: exportService.videosDirectory.deletingLastPathComponent())
        let externalRoots = [
            exportService.videosDirectory,
            WPEEngineAssetsLibrary.shared.resolveAuthorizedRoot(),
            (try? doctorService.resolveWorkdirURL())?.appendingPathComponent("steamapps/workshop/content/431960", isDirectory: true),
        ].compactMap(\.self)
        let protectedRoots = locations.filter {
            [.steamProfiles, .credentials, .application, .configuration, .preferences, .webData, .steamTools, .systemMetadata].contains($0.kind)
        }.map(\.url)
        let linked = StorageLinkedSources.current(excluding: externalRoots + protectedRoots)
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
        await refreshVideoStats()
    }

    private func refreshVideoStats() async {
        isLoadingVideo = true
        videoStats = await WPEVideoTextureDiskCache.shared.stats()
        isLoadingVideo = false
    }

    private func purgeVideoCache() async {
        let freed = await WPEVideoTextureDiskCache.shared.purgeAll()
        lastVideoFreedBytes = freed
        await refreshVideoStats()
    }

    func clearCache(_ kind: AppStorageLocation.Kind) async {
        guard !isClearing else { return }
        isClearing = true
        defer { isClearing = false }
        let before = totalBytes
        do { try await performClear(kind) } catch { errorMessage = error.localizedDescription }
        await refreshStats()
        lastStorageFreedBytes = before > totalBytes ? before - totalBytes : 0
    }

    private func performClear(_ kind: AppStorageLocation.Kind) async throws {
        switch kind {
        case .video: lastVideoFreedBytes = await WPEVideoTextureDiskCache.shared.purgeAll()
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
        let before = totalBytes
        for kind in AppStorageLocation.Kind.allCases where kind.canClear {
            do { try await performClear(kind) } catch { errorMessage = error.localizedDescription }
        }
        await refreshStats()
        lastStorageFreedBytes = before > totalBytes ? before - totalBytes : 0
    }

    func confirmClearAllCaches() {
        let size = byteFormatter.string(fromByteCount: Int64(clamping: clearableBytes))
        pendingDestructive = PendingDestructive(.clearAllStorageCaches(byteSize: size)) {
            Task { await clearAllCaches() }
        }
    }

    func confirmPurgeVideoCache() {
        let bytes = videoStats?.totalBytes ?? 0
        let size = byteFormatter.string(fromByteCount: Int64(bytes))
        pendingDestructive = PendingDestructive(.clearSceneVideoCache(byteSize: size)) {
            Task { await purgeVideoCache() }
        }
    }
}
#endif
