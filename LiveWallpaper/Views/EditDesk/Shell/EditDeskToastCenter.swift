import CoreGraphics
import Foundation
import LiveWallpaperCore
import Observation
import SwiftUI

@MainActor
@Observable
final class EditDeskToastCenter {
    struct Toast: Identifiable {
        enum Style: Equatable {
            case info, success, failure
        }

        /// A button beside the text; pressing it closes the toast and runs `perform`.
        struct Action {
            let title: String
            let perform: @MainActor () -> Void
        }

        let id: UUID
        let text: String
        let style: Style
        var screenID: CGDirectDisplayID?
        var postedAt: Date
        /// Seconds on screen; nil keeps the toast until it is dismissed.
        let lifetime: TimeInterval?
        /// The undo step the toast's Undo button reverts; nil draws no button.
        var undoStepID: UUID?
        /// Set while the pointer rests on the toast, which stops its clock.
        var pausedAt: Date?
        var action: Action?
    }

    /// MOTION 18: at most two stacked, newest just under the top bar and the older one below it.
    static let visibleLimit = 2
    static let duration: TimeInterval = 1.8
    static let undoDuration: TimeInterval = 8
    /// For the result of an undo or redo and the displays it skipped.
    static let resultDuration: TimeInterval = 4

    private(set) var toasts: [Toast] = []

    var nextExpiry: Date? {
        toasts.compactMap { toast in
            guard toast.pausedAt == nil, let lifetime = toast.lifetime else { return nil }
            return toast.postedAt.addingTimeInterval(lifetime)
        }.min()
    }

    @ObservationIgnored private let now: @Sendable () -> Date

    init(now: @escaping @Sendable () -> Date = Date.init) {
        self.now = now
    }

    @discardableResult
    func post(
        _ text: String,
        style: Toast.Style,
        screenID: CGDirectDisplayID? = nil,
        persistent: Bool = false,
        duration: TimeInterval = EditDeskToastCenter.duration,
        undoStepID: UUID? = nil,
        action: Toast.Action? = nil
    ) -> Toast.ID {
        if let screenID {
            toasts.removeAll { $0.screenID == screenID && $0.style == .failure }
        }
        // One Undo toast at a time: an older one offers a step that is no longer the newest.
        if undoStepID != nil {
            toasts.removeAll { $0.undoStepID != nil }
        }
        let toast = Toast(
            id: UUID(), text: text, style: style, screenID: screenID, postedAt: now(),
            lifetime: style == .failure || persistent ? nil : (undoStepID == nil ? duration : Self.undoDuration),
            undoStepID: undoStepID, action: action
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

    func performAction(_ id: Toast.ID) {
        guard let action = toasts.first(where: { $0.id == id })?.action else { return }
        dismiss(id)
        action.perform()
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
        // Avoid publishing an observation when no toast expired.
        guard toasts.contains(where: expired) else { return }
        toasts.removeAll(where: expired)
    }
}

struct EditDeskToastHost: View {
    let center: EditDeskToastCenter
    var onOpenDisplay: (CGDirectDisplayID) -> Void = { _ in }

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(EditDeskUndoStack.self) private var undo: EditDeskUndoStack?

    /// Below the tallest page top bar, so a toast never covers its buttons.
    private static let newestTopInset = max(DesignTokens.EditDesk.Spacing.topBar, DetailGeometry.topBarHeight)
        + DesignTokens.EditDesk.Spacing.s8
    var body: some View {
        VStack(spacing: DesignTokens.EditDesk.Spacing.s8) {
            ForEach(center.toasts.reversed()) { toast in
                toastView(toast)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .padding(.top, Self.newestTopInset)
        .animation(reduceMotion ? .linear(duration: 0.15) : .spring(response: 0.4, dampingFraction: 0.82), value: center.toasts.map(\.id))
        .task(id: center.nextExpiry) {
            while let deadline = center.nextExpiry {
                do {
                    try await Task.sleep(for: .seconds(max(0, deadline.timeIntervalSinceNow)))
                } catch {
                    return
                }
                guard !Task.isCancelled else { return }
                center.reap()
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
            if let action = toast.action {
                Button { center.performAction(toast.id) } label: {
                    Text(verbatim: action.title)
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
        onOpenDisplay(screenID)
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
