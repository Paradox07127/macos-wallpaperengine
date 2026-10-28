#if !MAS_BUILD
import AppKit
import LiveWallpaperCore
import SwiftUI

/// Per-display follow status under the status card; rows exist only for connected displays Loomscreen follows.
@available(macOS 26.0, *)
struct SystemWallpaperDisplayList: View {
    let service: WallpaperExportService
    let onRecord: () -> Void

    private var rows: [(status: SystemWallpaperDisplayStatus, name: String)] {
        guard let coordinator = service.followCoordinator else { return [] }
        let names = Dictionary(NSScreen.screens.compactMap { screen -> (UInt32, String)? in
            guard let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? UInt32 else { return nil }
            return (id, screen.localizedName)
        }, uniquingKeysWith: { first, _ in first })
        return SystemWallpaperDisplayStatus.evaluate(
            follow: coordinator.followState,
            showsTile: service.showsSelectedTile(on:),
            playbackFailures: service.heartbeat?.playbackFailures ?? [:],
            preparationProgress: service.preparationProgress
        ).compactMap { status in names[status.displayID].map { (status, $0) } }
    }

    var body: some View {
        let rows = rows
        if !rows.isEmpty {
            GroupBox {
                VStack(alignment: .leading, spacing: DesignTokens.Spacing.md) {
                    ForEach(rows, id: \.status.id) { row in
                        DisplayRow(status: row.status, name: row.name, service: service, onRecord: onRecord)
                    }
                }
            }
            .groupBoxStyle(ContainerGroupBoxStyle())
        }
    }
}

@available(macOS 26.0, *)
private struct DisplayRow: View {
    let status: SystemWallpaperDisplayStatus
    let name: String
    let service: WallpaperExportService
    let onRecord: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: DesignTokens.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignTokens.Spacing.xxs) {
                Text(verbatim: name)
                    .font(DesignTokens.Typography.bodyEmphasized)
                Text(verbatim: status.title)
                    .font(DesignTokens.Typography.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
            VStack(alignment: .trailing, spacing: DesignTokens.Spacing.xxs) {
                stateLabel
                    .font(DesignTokens.Typography.body)
                detail
            }
            action
        }
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch status.state {
        case .playing:
            label("Selected by macOS", symbol: "checkmark.circle.fill", tint: DesignTokens.Colors.Status.active)
        case let .preparing(progress):
            if let progress {
                label("Generating \(progress.formatted(.percent.precision(.fractionLength(0))))",
                      symbol: "gearshape.2", tint: DesignTokens.Colors.Status.info)
            } else {
                label("Generating", symbol: "gearshape.2", tint: DesignTokens.Colors.Status.info)
            }
        case .queued:
            label("Waiting to generate", symbol: "clock", tint: .secondary)
        case .cancelled:
            label("Generation cancelled", symbol: "xmark.circle", tint: .secondary)
        case .needsRecording:
            #if LITE_BUILD
            label("This version can’t record web wallpapers", symbol: "minus.circle", tint: .secondary)
            #else
            label("Needs a recorded video copy", symbol: "record.circle", tint: DesignTokens.Colors.Status.caution)
            #endif
        case .preparationFailed:
            label("Couldn’t generate the copy", symbol: "exclamationmark.triangle.fill", tint: DesignTokens.Colors.Status.warning)
        case .playbackFailed:
            label("macOS couldn’t play this copy", symbol: "exclamationmark.triangle.fill", tint: DesignTokens.Colors.Status.warning)
        case .notUsingTile:
            label("Uses another system wallpaper", symbol: "minus.circle", tint: .secondary)
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch status.state {
        case let .preparationFailed(message):
            Text(verbatim: message)
                .font(DesignTokens.Typography.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.trailing)
        case let .playbackFailed(code):
            ErrorCodeChip(code: code, tint: DesignTokens.Colors.Status.warning)
        default:
            EmptyView()
        }
    }

    @ViewBuilder
    private var action: some View {
        switch status.state {
        #if !LITE_BUILD
        case .needsRecording:
            Button("Record Video Copy", action: onRecord)
                .buttonStyle(.bordered)
                .controlSize(.small)
        #endif
        case .preparationFailed, .cancelled:
            Button("Retry") { service.followCoordinator?.retry(displayID: status.displayID) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        default:
            EmptyView()
        }
    }

    private func label(_ title: LocalizedStringKey, symbol: String, tint: some ShapeStyle) -> some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: symbol)
                .foregroundStyle(tint)
        }
    }
}
#endif
