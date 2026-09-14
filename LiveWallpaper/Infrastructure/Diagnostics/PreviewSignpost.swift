import Foundation
import os

enum PreviewSignpost {
    static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.loomscreen.pro",
        category: "Preview"
    )

    /// Begin/end rather than a closure-taking helper: these intervals wrap `await`s inside actors and `@MainActor` types, and a closure across those boundaries is what region isolation objects to.
    @inline(__always)
    static func begin(_ name: StaticString) -> OSSignpostIntervalState {
        signposter.beginInterval(name, id: signposter.makeSignpostID())
    }

    @inline(__always)
    static func end(_ name: StaticString, _ state: OSSignpostIntervalState) {
        signposter.endInterval(name, state)
    }

    @inline(__always)
    static func event(_ name: StaticString) {
        signposter.emitEvent(name, id: signposter.makeSignpostID())
    }
}
