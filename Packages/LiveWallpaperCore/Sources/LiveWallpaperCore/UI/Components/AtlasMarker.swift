import AppKit
import SwiftUI

public extension View {
    /// Tags a design-system component for the UI Atlas. A Debug build launched with LOOMSCREEN_ATLAS set backs it
    /// with a view the QA control plane lists (role, label, window frame); otherwise the view is returned unchanged.
    @ViewBuilder
    func atlasRole(_ role: String, label: String? = nil) -> some View {
        #if DEBUG
        if AtlasMarker.isEnabled {
            background(AtlasMarker.Anchor(role: role, label: label))
        } else {
            self
        }
        #else
        self
        #endif
    }
}

#if DEBUG
public enum AtlasMarker {
    public static let isEnabled = ProcessInfo.processInfo.environment["LOOMSCREEN_ATLAS"] != nil
    @MainActor public static let views = NSHashTable<MarkerView>.weakObjects()

    public final class MarkerView: NSView {
        public fileprivate(set) var role = ""
        /// nil = the component carries no identifying text or symbol.
        public fileprivate(set) var label: String?

        override public func hitTest(_: NSPoint) -> NSView? {
            nil
        }
    }

    struct Anchor: NSViewRepresentable {
        let role: String
        let label: String?

        func makeNSView(context _: Context) -> MarkerView {
            let view = MarkerView()
            AtlasMarker.views.add(view)
            return view
        }

        func updateNSView(_ view: MarkerView, context _: Context) {
            view.role = role
            view.label = label
        }
    }
}
#endif
