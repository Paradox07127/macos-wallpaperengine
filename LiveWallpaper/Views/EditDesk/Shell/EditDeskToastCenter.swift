import CoreGraphics
import Foundation
import LiveWallpaperCore
import Observation
import SwiftUI

@MainActor
@Observable
final class EditDeskToastCenter {
    struct Toast: Identifiable, Equatable {
        enum Style: Equatable {
            case info, success, failure
        }

        let id: UUID
        let text: String
        let style: Style
        var failure: WallpaperFailureSnapshot?
        var screenID: CGDirectDisplayID?
        var postedAt: Date
        /// Seconds on screen; nil keeps the toast until it is dismissed.
        let lifetime: TimeInterval?
        /// The undo step the toast's Undo button reverts; nil draws no button.
        var undoStepID: UUID?
        /// Set while the pointer rests on the toast, which stops its clock.
        var pausedAt: Date?
    }

    /// MOTION 18: at most two stacked, newest at bottom 24pt / older pushed to 68pt.
    static let visibleLimit = 2
    static let duration: TimeInterval = 1.8
    static let undoDuration: TimeInterval = 8
    /// For the result of an undo or redo and the displays it skipped.
    static let resultDuration: TimeInterval = 4

    private(set) var toasts: [Toast] = []

    @ObservationIgnored private let now: @Sendable () -> Date
    #if !LITE_BUILD
    @ObservationIgnored private var mirroredToken: Int?
    #endif

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    @discardableResult
    func post(
        _ text: String,
        style: Toast.Style,
        failure: WallpaperFailureSnapshot? = nil,
        screenID: CGDirectDisplayID? = nil,
        persistent: Bool = false,
        duration: TimeInterval = EditDeskToastCenter.duration,
        undoStepID: UUID? = nil
    ) -> Toast.ID {
        if let screenID {
            toasts.removeAll { $0.screenID == screenID && $0.style == .failure }
        }
        // One Undo toast at a time: an older one offers a step that is no longer the newest.
        if undoStepID != nil {
            toasts.removeAll { $0.undoStepID != nil }
        }
        let toast = Toast(
            id: UUID(), text: text, style: style, failure: failure, screenID: screenID, postedAt: now(),
            lifetime: style == .failure || persistent ? nil : (undoStepID == nil ? duration : Self.undoDuration),
            undoStepID: undoStepID
        )
        toasts.append(toast)
        if toasts.count > Self.visibleLimit {
            toasts.removeFirst(toasts.count - Self.visibleLimit)
        }
        return toast.id
    }

    func dismiss(_ id: Toast.ID) {
        toasts.removeAll { $0.id == id }
    }

    /// The pointer resting on an Undo toast stops its clock; leaving restarts it where it stopped.
    func setHovering(_ hovering: Bool, for id: Toast.ID) {
        guard let index = toasts.firstIndex(where: { $0.id == id }) else { return }
        if hovering {
            toasts[index].pausedAt = toasts[index].pausedAt ?? now()
        } else if let pausedAt = toasts[index].pausedAt {
            toasts[index].postedAt += now().timeIntervalSince(pausedAt)
            toasts[index].pausedAt = nil
        }
    }

    /// An undo or redo ran: its step's Undo toast goes, and the result and any displays it skipped are posted.
    func post(_ outcome: EditDeskUndoStack.Outcome) {
        toasts.removeAll { $0.undoStepID == outcome.stepID }
        for notice in outcome.notices {
            post(notice.text, style: notice.style, duration: Self.resultDuration)
        }
    }

    /// Pull-based on purpose: nothing owns a per-toast timer, so tests drive expiry with a
    /// fixed `date` instead of sleeping for real.
    func reap(at date: Date? = nil) {
        let cutoff = date ?? now()
        let expired: (Toast) -> Bool = { toast in
            toast.pausedAt == nil && toast.lifetime.map { cutoff.timeIntervalSince(toast.postedAt) >= $0 } ?? false
        }
        // `removeAll` publishes an observation whether or not it removed anything, and the host
        // calls this five times a second: an idle window would re-render forever.
        guard toasts.contains(where: expired) else { return }
        toasts.removeAll(where: expired)
    }

    #if !LITE_BUILD
    /// Guards against re-posting the same `WorkshopToastCenter` event on every observation tick.
    func mirror(_ event: WorkshopToastEvent) {
        guard event.token != mirroredToken else { return }
        mirroredToken = event.token
        let text = event.message.isEmpty ? event.title : "\(event.title) · \(event.message)"
        post(text, style: event.isSuccess ? .success : .failure, failure: event.failure, screenID: event.screenID)
    }
    #endif
}

struct EditDeskToastHost: View {
    let center: EditDeskToastCenter
    var onOpenFailure: (WallpaperFailureSnapshot, CGDirectDisplayID) -> Void = { _, _ in }
    var onOpenDisplay: (CGDirectDisplayID) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(EditDeskUndoStack.self) private var undo: EditDeskUndoStack?

    private static let newestBottomInset: CGFloat = 24
    private static let olderBottomInset: CGFloat = 68
    private static let reapInterval: Duration = .milliseconds(200)

    var body: some View {
        ZStack(alignment: .bottom) {
            ForEach(Array(center.toasts.enumerated()), id: \.element.id) { index, toast in
                toastView(toast)
                    .padding(.bottom, index == center.toasts.count - 1 ? Self.newestBottomInset : Self.olderBottomInset)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? .linear(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.82), value: center.toasts.map(\.id))
        .task {
            while !Task.isCancelled {
                center.reap()
                try? await Task.sleep(for: Self.reapInterval)
            }
        }
    }

    private func toastView(_ toast: EditDeskToastCenter.Toast) -> some View {
        HStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
            if toast.screenID != nil {
                Button { open(toast) } label: { message(toast) }
                    .buttonStyle(.plain)
            } else {
                message(toast)
            }
            if let stepID = toast.undoStepID, let undo {
                Button {
                    Task {
                        guard let outcome = await undo.undo(expecting: stepID) else { return }
                        center.post(outcome)
                    }
                } label: {
                    Text("Undo", comment: "Button on the toast after a wallpaper change in the Edit Desk; reverts that change.")
                        .font(DesignTokens.EditDesk.Typography.body)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(DesignTokens.EditDesk.Colors.link)
            }
            if toast.lifetime == nil {
                GlassIconButton("xmark", size: .small) { center.dismiss(toast.id) }
                    .help(Text("Dismiss"))
                    .accessibilityLabel(Text("Dismiss"))
            }
        }
        .padding(.horizontal, DesignTokens.EditDesk.Spacing.s14)
        .padding(.vertical, DesignTokens.EditDesk.Spacing.s8)
        .adaptiveGlassSurface(.capsule, tint: dotColor(toast.style))
        .onHover { hovering in
            if toast.undoStepID != nil {
                center.setHovering(hovering, for: toast.id)
            }
        }
    }

    private func message(_ toast: EditDeskToastCenter.Toast) -> some View {
        Text(verbatim: toast.text)
            .font(DesignTokens.EditDesk.Typography.body)
            .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
            .lineLimit(3)
    }

    private func open(_ toast: EditDeskToastCenter.Toast) {
        guard let screenID = toast.screenID else { return }
        if let failure = toast.failure {
            onOpenFailure(failure, screenID)
        } else {
            onOpenDisplay(screenID)
        }
        center.dismiss(toast.id)
    }

    private func dotColor(_ style: EditDeskToastCenter.Toast.Style) -> Color {
        switch style {
        case .info: DesignTokens.EditDesk.Colors.link
        case .success: DesignTokens.EditDesk.Colors.success
        case .failure: DesignTokens.EditDesk.Colors.danger
        }
    }
}
