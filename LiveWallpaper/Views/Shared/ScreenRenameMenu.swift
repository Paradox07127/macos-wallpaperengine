import SwiftUI

struct ScreenRenameMenu: ViewModifier {
    let screen: Screen

    @Environment(ScreenManager.self) private var screenManager
    @State private var renaming: Screen?

    func body(content: Content) -> some View {
        content
            .contextMenu {
                Button("Rename") { renaming = screen }
                if screen.customName != nil {
                    Button("Use System Name") {
                        screenManager.setCustomName(nil, for: screen)
                    }
                }
            }
            .screenRenameAlert(renaming: $renaming)
    }
}

struct ScreenRenameAlert: ViewModifier {
    /// The display being renamed; nil hides the alert.
    @Binding var renaming: Screen?

    @Environment(ScreenManager.self) private var screenManager
    @State private var draft = ""

    func body(content: Content) -> some View {
        content
            .alert(
                "Rename Display",
                isPresented: Binding(get: { renaming != nil }, set: { isPresented in
                    if !isPresented {
                        renaming = nil
                    }
                }),
                presenting: renaming
            ) { screen in
                TextField("Display name", text: $draft)
                Button("Cancel", role: .cancel) {}
                Button("Rename") { screenManager.setCustomName(draft, for: screen) }
            }
            .onChange(of: renaming) { _, screen in
                if let screen {
                    draft = screen.name
                }
            }
    }
}

extension View {
    func screenRenameMenu(for screen: Screen) -> some View {
        modifier(ScreenRenameMenu(screen: screen))
    }

    func screenRenameAlert(renaming: Binding<Screen?>) -> some View {
        modifier(ScreenRenameAlert(renaming: renaming))
    }
}
