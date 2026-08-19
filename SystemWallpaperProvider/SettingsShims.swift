import Foundation
import os.log

// Codable shims structurally identical to the Agent-side Swift types, so a
// keyed archive of ours unarchives as the private class after a class-name
// remap (contract §1.1). Field names and enum case names are the contract;
// unlabeled associated values encode under "_0".

struct SettingsViewModels: Codable {
    var desktop: SettingsViewModel?
    var screenSaver: SettingsViewModel?
}

struct SettingsViewModel: Codable {
    var groups: [SettingsGroup]
    var refreshPolicy: RefreshPolicy
    var isModificationDisabled: Bool
}

enum RefreshPolicy: Codable {
    case `default`
}

struct SettingsGroup: Codable {
    var id: GroupID
    var items: [SettingsItem]
    var localizedName: String
    var disposability: Disposability
    var sortOrder: Int
    var sortID: GroupSortID?
    var allChoiceID: ChoiceID?
    var shouldHideItemLabels: Bool?
    var contextMenu: ContextMenu?
    var thumbnail: Data?
}

struct GroupID: Codable { var id: String }
struct GroupSortID: Codable { var id: String }

struct ChoiceID: Codable {
    var id: String
    var descriptor: ChoiceIDDescriptor
}

struct ChoiceIDDescriptor: Codable {
    var provider: ChoiceProviderID
    var identifier: String
    var files: [URL]
    var configuration: Data
}

/// Encodes as a bare string (single-value container), not a keyed {rawValue:}.
struct ChoiceProviderID: Codable {
    var rawValue: String

    init(rawValue: String) { self.rawValue = rawValue }

    init(from decoder: Decoder) throws {
        rawValue = try decoder.singleValueContainer().decode(String.self)
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

struct SettingsItem: Codable {
    var id: ChoiceID
    var localizedName: String
    var thumbnail: Thumbnail
    var choice: ChoiceDescriptor
    var contentBadge: ContentBadge
    var showInTopLevel: Bool
    var sortOrder: Int
    var disposability: Disposability
}

struct ChoiceDescriptor: Codable {
    var id: ChoiceID
    var provider: ChoiceProviderID
    var identifier: String
    var name: String?
    var localizedDescription: String
    var thumbnail: Thumbnail
    var isDownloaded: Bool
    var options: [WallpaperOption]
}

struct WallpaperOption: Codable {}

enum Thumbnail: Codable {
    case image(url: URL)
    case customButton(CustomButton)
}

enum CustomButton: Codable {
    case addPhotoButton
    case addColorButton
    case shuffleColorsButton
}

enum ContentBadge: Codable {
    case none
    case video
    case dynamic
}

enum Disposability: Codable {
    case none
    case removable
    case purgeable
}

struct ContextMenu: Codable {
    var items: [ContextMenuItem]
}

struct ContextMenuItem: Codable {
    var identifier: String
    var name: String
}

/// Carrier whose keyed encoding matches what the private
/// `WallpaperSettingsViewModelsXPC` decodes: the Codable payload under the
/// fixed key "WallpaperSettingsViewModels". The archive never crosses a
/// process boundary before the remap, so secure coding is not required.
@objc(ShimViewModelsXPC)
final class ShimViewModelsXPC: NSObject, NSSecureCoding {
    static var supportsSecureCoding: Bool { false }

    let value: SettingsViewModels

    init(value: SettingsViewModels) {
        self.value = value
    }

    func encode(with coder: NSCoder) {
        guard let keyed = coder as? NSKeyedArchiver else { return }
        try? keyed.encodeEncodable(value, forKey: "WallpaperSettingsViewModels")
    }

    required init?(coder: NSCoder) { nil }
}

enum SettingsViewModelsEncoder {
    /// Archive the shim, then unarchive with the class name remapped to the
    /// private class — yielding a genuine `WallpaperSettingsViewModelsXPC`.
    static func makeXPCObject(_ models: SettingsViewModels) -> NSObject? {
        guard let privateClass = NSClassFromString("WallpaperSettingsViewModelsXPC") else {
            wpxLog.error("WallpaperSettingsViewModelsXPC class missing")
            return nil
        }
        do {
            let data = try NSKeyedArchiver.archivedData(
                withRootObject: ShimViewModelsXPC(value: models),
                requiringSecureCoding: false
            )
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: data)
            unarchiver.requiresSecureCoding = false
            unarchiver.setClass(privateClass, forClassName: "ShimViewModelsXPC")
            let object = unarchiver.decodeObject(forKey: NSKeyedArchiveRootObjectKey) as? NSObject
            unarchiver.finishDecoding()
            if object == nil { wpxLog.error("viewmodels unarchive returned nil") }
            return object
        } catch {
            wpxLog.error("viewmodels archive failed: \(String(describing: error), privacy: .public)")
            return nil
        }
    }
}
