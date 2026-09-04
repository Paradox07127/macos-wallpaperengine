import Foundation
@testable import LiveWallpaper
import Testing

@Suite("Inspector resize stepping for keyboard and VoiceOver")
struct InspectorResizeStepTests {
    private let minWidth: CGFloat = 260
    private let maxWidth: CGFloat = 520

    @Test("A step moves by exactly one increment in each direction")
    func stepsByOneIncrement() {
        let start: CGFloat = 400
        #expect(
            InspectorResizeStep.stepped(from: start, .wider, step: 24, minWidth: minWidth, maxWidth: maxWidth)
                == 424
        )
        #expect(
            InspectorResizeStep.stepped(from: start, .narrower, step: 24, minWidth: minWidth, maxWidth: maxWidth)
                == 376
        )
    }

    @Test("Stepping clamps at both bounds instead of overshooting")
    func clampsAtBounds() {
        #expect(
            InspectorResizeStep.stepped(from: maxWidth - 5, .wider, step: 24, minWidth: minWidth, maxWidth: maxWidth)
                == maxWidth
        )
        #expect(
            InspectorResizeStep.stepped(from: minWidth + 5, .narrower, step: 24, minWidth: minWidth, maxWidth: maxWidth)
                == minWidth
        )
    }

    @Test("At a bound the step is a no-op, so the caller commits nothing")
    func atBoundStepIsIdempotent() {
        #expect(
            InspectorResizeStep.stepped(from: maxWidth, .wider, step: 24, minWidth: minWidth, maxWidth: maxWidth)
                == maxWidth
        )
        #expect(
            InspectorResizeStep.stepped(from: minWidth, .narrower, step: 24, minWidth: minWidth, maxWidth: maxWidth)
                == minWidth
        )
    }

    /// A drag arms the close and shows it before release; a keypress commits at
    /// once. Narrowing by keyboard must therefore stop at `minWidth` rather than
    /// fall through a close threshold the user never saw arming.
    @Test("Narrowing by keyboard never crosses below the minimum into a close")
    func keyboardNarrowingNeverReachesCloseThreshold() {
        var width = maxWidth
        for _ in 0 ..< 200 {
            width = InspectorResizeStep.stepped(
                from: width, .narrower, step: 24, minWidth: minWidth, maxWidth: maxWidth
            )
        }
        #expect(width == minWidth)
    }

    @Test("The shipped default step is what the view uses")
    func defaultStepIsUsedByDefault() {
        #expect(
            InspectorResizeStep.stepped(from: 400, .wider, minWidth: minWidth, maxWidth: maxWidth)
                == 400 + InspectorResizeStep.defaultStep
        )
    }
}
