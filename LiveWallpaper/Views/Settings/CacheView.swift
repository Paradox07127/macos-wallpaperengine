#if !LITE_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

@MainActor
struct WPECacheManagementView: View {
    @State var linkedSources: [StorageLinkedSource] = []
    @State var unresolvedSources = 0
    @State var storageMeasurements: [AppStorageMeasurement] = []
    @State var storageScan: Task<[AppStorageMeasurement], Never>?
    @State var isClearing = false
    @State var pendingCache: AppStorageMeasurement?
    @State var lastStorageFreedBytes: UInt64?
    @State var isLoading: Bool = true
    @State var errorMessage: String?
    @State var pendingDestructive: PendingDestructive?
    @State var videoStats: WPEVideoCacheStats?
    @State var isLoadingVideo: Bool = true
    @State var lastVideoFreedBytes: UInt64?
    /// Applied / bookmarked / recent / deps scene ids.
    @State var reachableIDs: Set<String> = []
    /// App-managed engine assets only (Steam Workshop tree is external source data).
    @State var inventory: WPEStorageInventory?
    @State var isLoadingInventory: Bool = true
    /// Only the newest inventory pass may commit; see `refreshInventory()`.
    @State var inventoryGeneration: UInt64 = 0
    @State var inventoryScan: Task<WPEStorageInventory, Never>?
    @Binding private var pendingSearchAnchor: SettingsSearchAnchor?

    @State var hoveredItemID: String?
    @State var selectedItemID: String?

    #if DEBUG
    @State var testArtifacts: TestTempArtifacts.Summary = .empty
    @State var lastTestArtifactFreedBytes: UInt64?
    #endif

    /// Workshop browse JSON cache (folded into Storage total + Clear All).
    @Environment(WorkshopServices.self) var workshopServices
    @Environment(SteamCMDDoctorService.self) var doctorService
    /// Includes the separate video copies used by macOS System Wallpaper.
    @Environment(WallpaperExportService.self) var exportService
    @State var workshopCacheBytes: Int64 = 0

    init(
        pendingSearchAnchor: Binding<SettingsSearchAnchor?> = .constant(nil)
    ) {
        _pendingSearchAnchor = pendingSearchAnchor
    }

    var body: some View {
        Form {
            storageSection
            testArtifactsSection
        }
        .settingsFormChrome()
        .settingsSearchAnchorScroller(page: .storage, pendingSearchAnchor: $pendingSearchAnchor)
        .onAppear {
            exportService.refresh()
            Task { await refreshStats() }
        }
        .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in
            Task { await refreshStats() }
        }
        .onDisappear {
            inventoryGeneration &+= 1
            inventoryScan?.cancel()
            storageScan?.cancel()
        }
        .confirmationDialog("Clear this cache?", isPresented: Binding(
            get: { pendingCache != nil },
            set: {
                if !$0 {
                    pendingCache = nil
                }
            }
        ), titleVisibility: .visible, presenting: pendingCache) { measurement in
            Button("Clear Cache") {
                pendingCache = nil
                Task { await clearCache(measurement.location.kind) }
            }
            Button("Cancel", role: .cancel) { pendingCache = nil }
        } message: { measurement in
            Text(measurement.location.kind.title)
                + Text(verbatim: " · " + byteFormatter.string(fromByteCount: Int64(clamping: measurement.bytes)))
                + Text(verbatim: "\n\n")
                + Text(measurement.location.kind.detail)
        }
        .confirmDestructive($pendingDestructive)
        .errorAlert("Cache Error", message: $errorMessage)
    }

    func infoNote(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(DesignTokens.Typography.caption)
            .foregroundStyle(DesignTokens.Colors.textSecondary)
            .frame(maxWidth: 300, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    private static let storageByteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB, .useTB]
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    var byteFormatter: ByteCountFormatter {
        Self.storageByteFormatter
    }
}
#endif
