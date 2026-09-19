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
        let postedAt: Date
    }

    /// MOTION 18: at most two stacked, newest at bottom 24pt / older pushed to 68pt.
    static let visibleLimit = 2
    static let duration: TimeInterval = 1.8

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
        screenID: CGDirectDisplayID? = nil
    ) -> Toast.ID {
        let toast = Toast(id: UUID(), text: text, style: style, failure: failure, screenID: screenID, postedAt: now())
        toasts.append(toast)
        if toasts.count > Self.visibleLimit {
            toasts.removeFirst(toasts.count - Self.visibleLimit)
        }
        return toast.id
    }

    /// Pull-based on purpose: nothing owns a per-toast timer, so tests drive expiry with a
    /// fixed `date` instead of sleeping for real.
    func reap(at date: Date? = nil) {
        let cutoff = date ?? now()
        // `removeAll` publishes an observation whether or not it removed anything, and the host
        // calls this five times a second: an idle window would re-render forever.
        guard toasts.contains(where: { cutoff.timeIntervalSince($0.postedAt) >= Self.duration }) else { return }
        toasts.removeAll { cutoff.timeIntervalSince($0.postedAt) >= Self.duration }
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

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        Text(verbatim: toast.text)
            .font(DesignTokens.EditDesk.Typography.body)
            .foregroundStyle(DesignTokens.EditDesk.Colors.textPrimary)
            .padding(.horizontal, DesignTokens.EditDesk.Spacing.s14)
            .padding(.vertical, DesignTokens.EditDesk.Spacing.s8)
            .adaptiveGlassSurface(.capsule, tint: dotColor(toast.style))
            .onTapGesture {
                if let failure = toast.failure, let screenID = toast.screenID {
                    onOpenFailure(failure, screenID)
                }
            }
    }

    private func dotColor(_ style: EditDeskToastCenter.Toast.Style) -> Color {
        switch style {
        case .info: DesignTokens.EditDesk.Colors.link
        case .success: DesignTokens.EditDesk.Colors.success
        case .failure: DesignTokens.EditDesk.Colors.danger
        }
    }
}
