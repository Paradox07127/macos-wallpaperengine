import AppKit

@MainActor
extension NSOpenPanel {
    func presentSheetOrModal(completion: @escaping ([URL]) -> Void) {
        if let parent = NSApp.keyWindow ?? NSApp.mainWindow {
            beginSheetModal(for: parent) { response in
                guard response == .OK else { return }
                completion(self.urls)
            }
        } else {
            guard runModal() == .OK else { return }
            completion(urls)
        }
    }
}
