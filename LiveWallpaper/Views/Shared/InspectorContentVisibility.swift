import SwiftUI

extension EnvironmentValues {
    /// False while an inspector subtree is mounted but collapsed to zero width.
    /// `isMounted` deliberately keeps that subtree built, so `onDisappear` never
    /// fires for anything inside it — media that decodes on its own (GIF previews)
    /// has no other way to learn it stopped being on screen.
    @Entry var inspectorContentIsVisible: Bool = true
}
