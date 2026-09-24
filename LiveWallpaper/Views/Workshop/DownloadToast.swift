#if !LITE_BUILD
import LiveWallpaperCore
import SwiftUI

/// Observes the shared `WorkshopToastCenter` so it fires even after the detail
/// sheet or panel that started the action has been dismissed.
struct DownloadToastHost: View {
    private let center = WorkshopToastCenter.shared
    @State private var shown: WorkshopToastEvent?
    @State private var hovering = false
    private enum Control: Hashable { case details, dismiss }
    @FocusState private var focused: Control?
    var visibleDisplayID: CGDirectDisplayID?
    /// A folder import in flight; its card stays above the latest event until the batch ends.
    var activity: WorkshopFolderImportCoordinator.Progress?
    var onOpenFailure: (WallpaperFailureSnapshot, CGDirectDisplayID) -> Void = { _, _ in }

    var body: some View {
        VStack {
            if let activity {
                activityToast(activity)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
            if let event = shown {
                toast(event)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: shown?.token)
        .animation(.easeOut(duration: 0.2), value: activity == nil)
        .onChange(of: center.lastEvent?.token) { _, _ in
            if let event = center.lastEvent {
                shown = event.failure != nil && event.screenID == visibleDisplayID ? nil : event
            }
        }
        .onChange(of: visibleDisplayID) {
            if shown?.failure != nil, shown?.screenID == visibleDisplayID {
                shown = nil
            }
        }
        .onHover { hovering = $0 }
        .task(id: "\(shown?.token ?? 0):\(hovering):\(focused != nil)") {
            guard let event = shown, !hovering, focused == nil else { return }
            do { try await Task.sleep(for: .seconds(event.isSuccess ? 4 : 8)) } catch { return }
            guard !Task.isCancelled, shown?.token == event.token else { return }
            withAnimation(.easeOut(duration: 0.2)) { shown = nil }
        }
    }

    private func activityToast(_ activity: WorkshopFolderImportCoordinator.Progress) -> some View {
        let event = WorkshopToastEvent(
            token: 0,
            headline: String(localized: "Importing from folder…", bundle: .appLanguage),
            title: activity.title,
            message: String(
                localized: "\(activity.completed) of \(activity.total) projects", bundle: .appLanguage,
                comment: "Folder import progress card. Placeholders are the projects tried so far and the projects found."
            ),
            isSuccess: true
        )
        return toast(event, progress: Double(activity.completed) / Double(activity.total))
    }

    /// `progress` (0…1) puts a ring in the icon slot and drops the dismiss button: that card ends with its batch.
    private func toast(_ event: WorkshopToastEvent, progress: Double? = nil) -> some View {
        let tint = event.isSuccess ? DesignTokens.Colors.Status.active : DesignTokens.Colors.Status.danger
        return HStack(spacing: 10) {
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.circular)
                    .controlSize(.small)
                    .frame(width: 28, height: 28)
            } else {
                ZStack {
                    Circle().fill(tint.opacity(0.18)).frame(width: 28, height: 28)
                    Image(systemName: event.isSuccess ? "checkmark" : "exclamationmark.triangle.fill")
                        .font(DesignTokens.Typography.bodyEmphasized)
                        .foregroundStyle(tint)
                }
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: event.headline)
                    .font(DesignTokens.Typography.bodyEmphasized)
                Text(verbatim: event.title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(verbatim: event.message)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: 240, alignment: .leading)

            if let failure = event.failure, let screenID = event.screenID {
                Button("View Details") { onOpenFailure(failure, screenID); shown = nil }
                    .buttonStyle(.bordered)
                    .focused($focused, equals: .details)
            }
            if progress == nil {
                Button {
                    withAnimation(.easeOut(duration: 0.2)) { shown = nil }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .focused($focused, equals: .dismiss)
                .accessibilityLabel(Text("Dismiss"))
            }
        }
        .padding(.horizontal, DesignTokens.Spacing.cardInset)
        .padding(.vertical, 10)
        .adaptiveGlassSurface(.roundedRectangle(DesignTokens.Corner.xl))
        .shadow(color: .black.opacity(DesignTokens.Card.shadowOpacity), radius: 14, x: 0, y: 6)
        .accessibilityElement(children: .contain)
        .accessibilityLabel(Text(verbatim: "\(event.headline): \(event.title). \(event.message)"))
    }
}
#endif
