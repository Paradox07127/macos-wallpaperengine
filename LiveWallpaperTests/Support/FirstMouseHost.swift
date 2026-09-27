import AppKit
import SwiftUI

/// The test app is not active, so AppKit spends each click as an activating first click, which only Buttons accept;
/// gestures and taps on anything else would never see it.
final class FirstMouseHost<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for _: NSEvent?) -> Bool {
        true
    }
}
