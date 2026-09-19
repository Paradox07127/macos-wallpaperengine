import Foundation

enum EditDeskFlag {
    static let key = "loomscreen.ui.editDesk.v1"

    static var isEnabled: Bool {
        UserDefaults.appScoped().bool(forKey: key)
    }
}
