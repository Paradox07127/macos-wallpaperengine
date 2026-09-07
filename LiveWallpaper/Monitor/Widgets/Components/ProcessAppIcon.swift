import AppKit
import SwiftUI

/// Small local application identities, shared across process rows and redraws.
@MainActor
final class ProcessAppIconCache {
    static let shared = ProcessAppIconCache()

    private final class Entry {
        let image: NSImage?
        let loadedAt = Date()
        init(_ image: NSImage?) {
            self.image = image
        }
    }

    private let entries = NSCache<NSString, Entry>()
    private let resolve: @MainActor (String) -> NSImage?

    init(resolve: @escaping @MainActor (String) -> NSImage? = ProcessAppIconCache.load) {
        self.resolve = resolve
        entries.countLimit = 64
    }

    func icon(bundleID: String?) -> NSImage? {
        guard let bundleID, !bundleID.isEmpty else { return nil }
        let key = bundleID as NSString
        if let entry = entries.object(forKey: key),
           entry.image != nil || Date().timeIntervalSince(entry.loadedAt) < 30 {
            return entry.image
        }
        let icon = resolve(bundleID)
        entries.setObject(Entry(icon), forKey: key)
        return icon
    }

    private static func load(_ bundleID: String) -> NSImage? {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID),
              url.pathExtension.lowercased() == "app" else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }
}

struct ProcessAppIcon: View {
    let bundleID: String?
    let size: CGFloat

    var body: some View {
        if let icon = ProcessAppIconCache.shared.icon(bundleID: bundleID) {
            Image(nsImage: icon)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .accessibilityHidden(true)
        }
    }
}
