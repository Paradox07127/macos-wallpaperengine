import Foundation
import os

/// Signpost intervals for the library-grid preview pipeline. Three rounds of work were spent arguing about which stage a hitch came from, and twice the structural theory turned out wrong when finally measured.
/// The render path has had `WPEFrame` signposts for exactly this reason; the grid did not, so an Animation Hitches trace could show the stall but not say whether it was the fetch, the queue, or the decode.
/// Always on: with no Instruments observer attached the emit cost is negligible, the same trade `WPEMetalSceneRenderer.frameSignposter` makes.
/// Read with the os_signpost template. `queued` around the wait for a `PreviewWorkGate` slot separates "we are behind other work" from "this decode is slow", the distinction the concurrency cap was added to control.
enum PreviewSignpost {
    static let signposter = OSSignposter(
        subsystem: Bundle.main.bundleIdentifier ?? "com.loomscreen.pro",
        category: "Preview"
    )

    /// Begin/end rather than a closure-taking helper: these intervals wrap
    /// `await`s inside actors and `@MainActor` types, and handing a closure
    /// across those boundaries is exactly the thing region isolation objects to.
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
