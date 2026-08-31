import Foundation
@testable import LiveWallpaper
import Testing

/// `dispatchPointerButtonEdges` snapshots `layerHoverStates` to decide which layer
/// a press landed on, and `dispatchLayerHoverEvents` is what fills that dictionary.
/// The two therefore have a required order inside one frame, and the order is not
/// visible at either call site: the button dispatch used to sit inside
/// `applyingLayerScriptTicks`, which `renderCurrentFrame` calls well before it
/// hit-tests hover, so a press was matched against the PREVIOUS frame's hover set.
/// Moving the pointer onto a layer and clicking in the same frame then recorded the
/// press on whatever was hovered last frame, and the release produced no
/// `cursorClick` — or one on the wrong layer.
///
/// Hover cannot simply move earlier: it deliberately runs after live transforms so
/// the hit rects come from this frame's geometry. So the button dispatch moves after
/// hover instead, and this pins it there.
@Suite("Pointer press is matched against this frame's hover state")
struct PointerEventOrderTests {
    /// Sliced to `renderCurrentFrame`'s own body on purpose: searching the whole
    /// file finds the hover call at its line and the button call at its line and
    /// says the order is fine, which is exactly the false pass that let the bug
    /// exist — the button call was textually later but executed earlier, from
    /// inside a helper invoked near the top of the frame.
    private func renderCurrentFrameBody() throws -> Substring {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Frame.swift"
        )
        let start = try #require(source.range(of: "func renderCurrentFrame("))
        let rest = source[start.upperBound...]
        let end = rest.range(of: "\n    private func ") ?? rest.range(of: "\n    func ")
        return end.map { rest[..<$0.lowerBound] } ?? rest
    }

    @Test("Button edges are dispatched after hover hit-testing, not before")
    func buttonEdgesFollowHoverHitTesting() throws {
        let body = try renderCurrentFrameBody()
        let hover = try #require(
            body.range(of: "dispatchLayerHoverEvents("),
            "renderCurrentFrame no longer hit-tests hover; this contract is meaningless"
        )
        let buttons = try #require(
            body.range(of: "dispatchPointerButtonEdges("),
            "renderCurrentFrame does not dispatch button edges, so they run from somewhere earlier"
        )
        #expect(
            hover.upperBound < buttons.lowerBound,
            "button edges are dispatched before hover state is refreshed, so a press in the same frame as a move is attributed to the previous frame's layer"
        )
    }

    /// The bug was structural: the dispatch was nested inside a helper whose own
    /// call site ran early. Keeping it out of that helper is what makes the order
    /// above readable at the one place it is decided.
    @Test("The button dispatch does not live inside the layer-script tick helper")
    func buttonDispatchIsNotNestedInTheTickHelper() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Frame.swift"
        )
        let helper = try #require(source.range(of: "private func applyingLayerScriptTicks("))
        let buttons = try #require(source.range(of: "dispatchPointerButtonEdges("))
        #expect(
            buttons.lowerBound < helper.lowerBound,
            "dispatchPointerButtonEdges is nested in applyingLayerScriptTicks again; that helper runs before hover hit-testing"
        )
    }
}
