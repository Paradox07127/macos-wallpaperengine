import SwiftUI

struct ScreenRenameMenu: ViewModifier {
    let screen: Screen

    @Environment(ScreenManager.self) private var screenManager
    @State private var isRenaming = false
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Rename") {
                    draft = screen.name
                    isRenaming = true
                }
                if screen.customName != nil {
                    Button("Use System Name") {
                        screenManager.setCustomName(nil, for: screen)
                    }
                }
            }
            .alert("Rename Display", isPresented: $isRenaming) {
                TextField("Display name", text: $draft)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { screenManager.setCustomName(draft, for: screen) }
            }
    }
}

extension View {
    func screenRenameMenu(for screen: Screen) -> some View {
        modifier(ScreenRenameMenu(screen: screen))
    }
}
