import Foundation

enum BundleIdentity {
    static let productDisplayName: String = {
        if let display = Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String,
           !display.isEmpty {
            return display
        }
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.isEmpty {
            return name
        }
        return "Loomscreen Pro"
    }()
}
