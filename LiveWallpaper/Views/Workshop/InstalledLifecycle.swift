#if !LITE_BUILD
    import Foundation

    @MainActor
    final class InstalledPageLifecycleOwner {
        struct UpdateTicket: Equatable, Sendable {
            let generation: UInt64
            fileprivate let token: UUID
        }

        struct UpdateResult<Value: Sendable>: Sendable {
            fileprivate let ticket: UpdateTicket
            let value: Value
        }

        private struct UpdateHandle: Sendable {
            let ticket: UpdateTicket
            let cancel: @Sendable () -> Void
        }

        private var updateGeneration: UInt64 = 0
        private var updateHandle: UpdateHandle?

        deinit {
            updateHandle?.cancel()
        }

        #if DEBUG
        // Test-only introspection; no production reader.
        var hasActiveUpdate: Bool {
            updateHandle != nil
        }
        #endif

        /// Replaces any previous check. The returned result remains uncommitted and
        /// keeps its ticket live until `commitUpdate` validates it synchronously.
        func replaceUpdate<Value: Sendable>(
            operation: @escaping @MainActor (UpdateTicket) async -> Value?
        ) async -> UpdateResult<Value>? {
            cancelUpdate()
            updateGeneration &+= 1
            let ticket = UpdateTicket(generation: updateGeneration, token: UUID())
            let task = Task { @MainActor in
                await operation(ticket)
            }
            updateHandle = UpdateHandle(ticket: ticket, cancel: { task.cancel() })

            let value = await withTaskCancellationHandler {
                await task.value
            } onCancel: {
                task.cancel()
            }

            guard canContinue(ticket), let value else {
                finishUpdate(ticket)
                return nil
            }
            return UpdateResult(ticket: ticket, value: value)
        }

        /// Validation, state publication and ticket retirement are one MainActor
        /// turn, so replacement cannot interleave with a partially committed cache.
        @discardableResult
        func commitUpdate<Value: Sendable>(
            _ result: UpdateResult<Value>,
            commit: (Value) -> Void
        ) -> Bool {
            guard updateHandle?.ticket == result.ticket, !Task.isCancelled else {
                finishUpdate(result.ticket)
                return false
            }
            commit(result.value)
            finishUpdate(result.ticket)
            return true
        }

        func canContinue(_ ticket: UpdateTicket) -> Bool {
            updateHandle?.ticket == ticket && !Task.isCancelled
        }

        func cancelUpdate() {
            updateGeneration &+= 1
            let handle = updateHandle
            updateHandle = nil
            handle?.cancel()
        }

        func tearDown() {
            cancelUpdate()
        }

        private func finishUpdate(_ ticket: UpdateTicket) {
            guard updateHandle?.ticket == ticket else { return }
            updateHandle = nil
        }
    }
#endif
