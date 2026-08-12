#if !LITE_BUILD
    import Foundation

    struct WPESceneScriptBufferedVideoCommand: Sendable, Equatable {
        let objectID: String
        let command: WPELayerVideoCommand
    }

    /// Batch one-shot player mutations until traversal completes (fail-close can drop the batch).
    struct WPESceneScriptVideoCommandBuffer: Sendable {
        private(set) var isTransactionActive = false
        private(set) var pending: [WPESceneScriptBufferedVideoCommand] = []

        mutating func begin() {
            pending.removeAll(keepingCapacity: true)
            isTransactionActive = true
        }

        mutating func enqueue(
            _ commands: [WPELayerVideoCommand],
            objectID: String
        ) {
            guard isTransactionActive, !commands.isEmpty else { return }
            pending.append(contentsOf: commands.map {
                WPESceneScriptBufferedVideoCommand(objectID: objectID, command: $0)
            })
        }

        /// Returns commands only for a successful traversal. Ending an inactive
        /// or failed transaction is deliberately inert and always drains storage.
        mutating func finish(commit: Bool) -> [WPESceneScriptBufferedVideoCommand] {
            guard isTransactionActive else { return [] }
            let committed = commit ? pending : []
            pending.removeAll(keepingCapacity: true)
            isTransactionActive = false
            return committed
        }

        mutating func discard() {
            _ = finish(commit: false)
        }
    }
#endif
