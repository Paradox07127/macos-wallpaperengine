import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Pointer press is matched against this frame's hover state")
struct PointerEventOrderTests {
    /// Slice to renderCurrentFrame's own body: a whole-file search finds both calls
    /// and passes even when the button call executes earlier from inside a helper.
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

    @Test("The button dispatch does not live inside the layer-script tick helper")
    func buttonDispatchIsNotNestedInTheTickHelper() throws {
        let source = try RepositoryRoot.source(
            "LiveWallpaper/Runtime/Metal/WPEMetalSceneRenderer+Frame.swift"
        )
        let helper = try #require(source.range(of: "private func tickLayerPresentationScripts("))
        let buttons = try #require(source.range(of: "dispatchPointerButtonEdges("))
        #expect(
            buttons.lowerBound < helper.lowerBound,
            "dispatchPointerButtonEdges is nested in tickLayerPresentationScripts again; that helper runs before hover hit-testing"
        )
    }
}
