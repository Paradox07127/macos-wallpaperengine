#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

extension WPECacheManagementView {
    func refreshStats() async {
        isLoading = true
        isLoadingInventory = true
        reachableIDs = WPESceneReachability.referencedWorkshopIDs()
        isLoading = false
        await refreshInventory()
        workshopCacheBytes = await workshopServices.queryCache.sizeBytes()
        #if DEBUG
        await refreshTestArtifacts()
        #endif
        await refreshVideoStats()
    }

    /// `wpeHistoryDidChange` fires on every apply/bookmark edit, so passes stack up
    /// mid-walk. Newest generation wins; older ones are cancelled and their results
    /// dropped.
    private func refreshInventory() async {
        inventoryScan?.cancel()
        inventoryGeneration &+= 1
        let generation = inventoryGeneration
        isLoadingInventory = true

        let scan = Task { await WPEStorageInventory.compute(doctor: doctorService) }
        inventoryScan = scan
        let scanned = await scan.value

        guard generation == inventoryGeneration else { return }
        inventoryScan = nil
        inventory = scanned
        isLoadingInventory = false
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

    private func clearAllCaches() async {
        lastVideoFreedBytes = await WPEVideoTextureDiskCache.shared.purgeAll()
        await workshopServices.queryCache.clear()
        await refreshStats()
        NotificationCenter.default.post(name: .wpeHistoryDidChange, object: nil)
    }






    func confirmClearAllCaches() {
        let size = byteFormatter.string(fromByteCount: Int64(totalBytes))
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
