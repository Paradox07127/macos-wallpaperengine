#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

extension WPECacheManagementView {
    func refreshStats() async {
        isLoading = true
        isLoadingInventory = true
        reachableIDs = WPESceneReachability.referencedWorkshopIDs()
        isLoading = false
        // The engine-assets root now resolves from a main-actor bookmark, so the
        // walk cannot start off-main; the byte walk itself stays cheap because
        // only one directory is measured.
        inventory = WPEStorageInventory.compute(doctor: doctorService)
        isLoadingInventory = false
        workshopCacheBytes = await workshopServices.queryCache.sizeBytes()
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
