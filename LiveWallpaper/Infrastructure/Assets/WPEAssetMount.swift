#if !LITE_BUILD
import Foundation

struct WPEAssetMount: Equatable, Sendable {
    enum Backing: Equatable, Sendable {
        case directory(URL)
        case package(URL)
    }

    let workshopID: String
    let backing: Backing

    init(workshopID: String, rootURL: URL) {
        self.workshopID = workshopID
        self.backing = .directory(rootURL.standardizedFileURL.resolvingSymlinksInPath())
    }

    init(workshopID: String, packageURL: URL) {
        self.workshopID = workshopID
        self.backing = .package(packageURL.standardizedFileURL.resolvingSymlinksInPath())
    }

    var rootURL: URL? {
        if case .directory(let url) = backing { return url }
        return nil
    }
}
#endif
