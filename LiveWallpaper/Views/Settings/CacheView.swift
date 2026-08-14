#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI
import AppKit

/// Unified "Storage" tab.
@MainActor
struct WPECacheManagementView: View {
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
    @Binding private var pendingSearchAnchor: SettingsSearchAnchor?

    #if DEBUG
    /// DEBUG-only temp dirs left by test runs.
    @State var testArtifacts: TestTempArtifacts.Summary = .empty
    @State var lastTestArtifactFreedBytes: UInt64?
    #endif

    /// Workshop browse JSON cache (folded into Storage total + Clear All).
    @Environment(WorkshopServices.self) var workshopServices
    /// Steam library sizes need the Doctor security-scoped bookmark.
    @Environment(SteamCMDDoctorService.self) var doctorService
    @State var workshopCacheBytes: Int64 = 0

    let dashboardColumns = [
        GridItem(.flexible(minimum: 220), spacing: DesignTokens.Spacing.md),
        GridItem(.flexible(minimum: 220), spacing: DesignTokens.Spacing.md)
    ]

    init(
        pendingSearchAnchor: Binding<SettingsSearchAnchor?> = .constant(nil)
    ) {
        _pendingSearchAnchor = pendingSearchAnchor
    }

    var body: some View {
        Form {
            storageDashboardSection


            testArtifactsSection
        }
        .settingsFormChrome()
        .settingsSearchAnchorScroller(
            pendingSearchAnchor: $pendingSearchAnchor,
            anchors: [
                .storageDashboard,
                .storageCaches
            ]
        )
        .onAppear { Task { await refreshStats() } }
        .onReceive(NotificationCenter.default.publisher(for: .wpeHistoryDidChange)) { _ in
            Task { await refreshStats() }
        }
        .confirmDestructive($pendingDestructive)
        .errorAlert("Cache Error", message: $errorMessage)
    }

    @ViewBuilder
    func infoNote(_ key: LocalizedStringKey) -> some View {
        Text(key)
            .font(.caption)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 300, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
    }

    // Shared formatters — list refreshes often; don't rebuild per row.
    var byteFormatter: ByteCountFormatter { Self.sharedByteFormatter }

    private static let sharedByteFormatter: ByteCountFormatter = {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useKB, .useMB, .useGB]
        f.countStyle = .file
        f.includesUnit = true
        return f
    }()
}
#endif
