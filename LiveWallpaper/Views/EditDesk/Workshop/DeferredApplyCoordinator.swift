#if !LITE_BUILD
import CoreGraphics
import Foundation
import Observation

@MainActor
protocol DeferredApplyScreenResolving {
    var screens: [Screen] { get }
    func isCurrentTransition(_ generation: Int, for screenID: CGDirectDisplayID) -> Bool
}

extension ScreenManager: DeferredApplyScreenResolving {}

@MainActor
@Observable
final class DeferredApplyCoordinator {
    @MainActor
    struct Target: Equatable {
        let screenID: CGDirectDisplayID
        let displayFingerprint: String
        /// The generation returned by the host's explicit selection; this coordinator never advances it.
        let selectionGeneration: Int

        init(screen: Screen, selectionGeneration: Int) {
            screenID = screen.id
            displayFingerprint = screen.displayFingerprint
            self.selectionGeneration = selectionGeneration
        }
    }

    enum Invalidation: Equatable {
        case superseded
        case newerSelection
        case screenUnavailable
        case cancelled
    }

    enum State: Equatable {
        case waiting
        case applying
        case downloadOnly(WorkshopDownloadOutcome)
        case finished(ApplyReport)
        case invalidated(Invalidation)

        /// No further transition is possible; the ticket now only waits to be replaced.
        var isSettled: Bool {
            switch self {
            case .waiting, .applying: false
            case .downloadOnly, .finished, .invalidated: true
            }
        }
    }

    @MainActor
    @Observable
    final class Ticket: Identifiable {
        let id = UUID()
        let attempt: WorkshopDownloadAttempt
        fileprivate(set) var target: Target
        fileprivate(set) var state: State = .waiting

        fileprivate init(attempt: WorkshopDownloadAttempt, target: Target) {
            self.attempt = attempt
            self.target = target
        }
    }

    private let manager: any DeferredApplyScreenResolving
    private let router: ApplyRouter
    /// One ticket per item, kept after it settles so a view that comes back still finds the result.
    private(set) var tickets: [UInt64: Ticket] = [:]
    @ObservationIgnored private var tasks: [UUID: Task<Void, Never>] = [:]

    /// The host retains this owner beyond the modal's lifetime; tickets expose observable results.
    init(manager: any DeferredApplyScreenResolving, router: ApplyRouter) {
        self.manager = manager
        self.router = router
    }

    isolated deinit {
        for task in tasks.values {
            task.cancel()
        }
    }

    @discardableResult
    func submit(attempt: WorkshopDownloadAttempt, target: Target) -> Ticket {
        if let previous = tickets[attempt.itemID], !previous.state.isSettled {
            invalidate(previous, reason: .superseded)
        }
        let ticket = Ticket(attempt: attempt, target: target)
        tickets[attempt.itemID] = ticket
        let outcomes = attempt.outcomes()
        tasks[ticket.id] = Task { [weak self, weak ticket] in
            for await outcome in outcomes {
                guard !Task.isCancelled, let ticket else { return }
                await self?.complete(ticket, outcome: outcome)
                return
            }
        }
        return ticket
    }

    /// The ticket a view should render for one item, live or already settled.
    func ticket(for itemID: UInt64) -> Ticket? {
        tickets[itemID]
    }

    @discardableResult
    func updateTarget(_ target: Target, for ticket: Ticket) -> Bool {
        guard tickets[ticket.attempt.itemID] === ticket, ticket.state == .waiting else { return false }
        ticket.target = target
        return true
    }

    func cancel(_ ticket: Ticket) {
        guard tickets[ticket.attempt.itemID] === ticket else { return }
        invalidate(ticket, reason: .cancelled)
    }

    private func invalidate(_ ticket: Ticket, reason: Invalidation) {
        ticket.state = .invalidated(reason)
        tasks.removeValue(forKey: ticket.id)?.cancel()
    }

    private func complete(_ ticket: Ticket, outcome: WorkshopDownloadOutcome) async {
        guard tickets[ticket.attempt.itemID] === ticket, ticket.state == .waiting else { return }
        defer { tasks[ticket.id] = nil }
        guard case let .succeeded(entry) = outcome else {
            ticket.state = outcome == .cancelled ? .invalidated(.cancelled) : .downloadOnly(outcome)
            return
        }
        let target = ticket.target
        guard let screen = manager.screens.first(where: {
            $0.id == target.screenID && $0.displayFingerprint == target.displayFingerprint
        }) else {
            invalidate(ticket, reason: .screenUnavailable)
            return
        }
        guard manager.isCurrentTransition(target.selectionGeneration, for: screen.id) else {
            invalidate(ticket, reason: .newerSelection)
            return
        }
        ticket.state = .applying
        let report = await router.apply(.installedWorkshop(entry), to: screen)
        guard !Task.isCancelled, tickets[ticket.attempt.itemID] === ticket else { return }
        ticket.state = .finished(report)
    }
}
#endif
