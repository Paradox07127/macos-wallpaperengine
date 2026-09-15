import Foundation

/// Keeps an already-authorized folder readable while a decoder outlives its caller.
final class OggSourceAccess: @unchecked Sendable {
    private let release: @Sendable () -> Void

    init(root: URL) {
        let didStart = root.startAccessingSecurityScopedResource()
        release = {
            if didStart {
                root.stopAccessingSecurityScopedResource()
            }
        }
    }

    init(release: @escaping @Sendable () -> Void) {
        self.release = release
    }

    deinit { release() }
}
