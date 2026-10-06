#if !LITE_BUILD
import Foundation
@testable import LiveWallpaper
import Testing

@Suite("appworkshop acf installed ids — strict entries authorize deletions")
struct SteamWorkshopManifestACFTests {
    private func acf(installed body: String) -> String {
        """
        "AppWorkshop"
        {
        \t"appid"\t\t"431960"
        \t"SizeOnDisk"\t\t"20"
        \t"WorkshopItemsInstalled"
        \t{
        \(body)
        \t}
        \t"WorkshopItemDetails"
        \t{
        \t\t"333"
        \t\t{
        \t\t\t"manifest"\t\t"7"
        \t\t\t"subscribedby"\t\t"1"
        \t\t}
        \t}
        }

        """
    }

    private let entry111 = "\t\t\"111\"\n\t\t{\n\t\t\t\"size\"\t\t\"10\"\n\t\t\t\"timeupdated\"\t\t\"1700000000\"\n\t\t}"
    private let entry222 = "\t\t\"222\"\n\t\t{\n\t\t\t\"size\"\t\t\"10\"\n\t\t\t\"manifest\"\t\t\"9\"\n\t\t}"

    @Test("Standard entries parse; details block ignored; empty block is empty; missing block is nil")
    func standardShapes() {
        #expect(SteamWorkshopManifest.installedIDs(fromACF: acf(installed: entry111 + "\n" + entry222)) == ["111", "222"])
        #expect(SteamWorkshopManifest.installedIDs(fromACF: acf(installed: "")) == [])
        let withoutInstalled = "\"AppWorkshop\"\n{\n\t\"appid\"\t\t\"431960\"\n}\n"
        #expect(SteamWorkshopManifest.installedIDs(fromACF: withoutInstalled) == nil)
    }

    @Test("A key followed by a quoted value is not an entry")
    func keyWithValueIsRejected() {
        let body = "\t\t\"111\"\t\t\"0\"\n" + entry222
        #expect(SteamWorkshopManifest.installedIDs(fromACF: acf(installed: body)) == nil)
    }

    @Test("A non-numeric key is rejected")
    func nonNumericKeyIsRejected() {
        let body = entry111 + "\n\t\t\"abc\"\n\t\t{\n\t\t\t\"size\"\t\t\"1\"\n\t\t}"
        #expect(SteamWorkshopManifest.installedIDs(fromACF: acf(installed: body)) == nil)
    }

    @Test("An unquoted key is rejected rather than skipped")
    func unquotedKeyIsRejected() {
        let body = "\t\t111\n\t\t{\n\t\t}\n" + entry222
        #expect(SteamWorkshopManifest.installedIDs(fromACF: acf(installed: body)) == nil)
    }

    @Test("Line comments between key and block are trivia, CRLF included")
    func lineCommentsAreSkipped() {
        let body = "\t\t// pinned\n\t\t\"111\"\n\t\t// note\n\t\t{\n\t\t}\n" + entry222
        #expect(SteamWorkshopManifest.installedIDs(fromACF: acf(installed: body)) == ["111", "222"])
        let crlf = acf(installed: body).replacingOccurrences(of: "\n", with: "\r\n")
        #expect(SteamWorkshopManifest.installedIDs(fromACF: crlf) == ["111", "222"])
    }

    @Test("A key without a block is rejected")
    func keyWithoutBlockIsRejected() {
        #expect(SteamWorkshopManifest.installedIDs(fromACF: acf(installed: entry111 + "\n\t\t\"222\"")) == nil)
    }

    @Test("A brace inside a line comment does not close the installed block")
    func commentedBraceDoesNotCloseBlock() {
        let text = "\"AppWorkshop\"\n{\n\"WorkshopItemsInstalled\"\n{\n// } x\n\"111\" { }\n}\n}"
        #expect(SteamWorkshopManifest.installedIDs(fromACF: text) == ["111"])
    }

    @Test("An installed block nested below the root, before or after the real one, fails the whole set")
    func nestedInstalledBlockIsRejected() {
        let nested = "\t\"Junk\"\n\t{\n\t\t\"WorkshopItemsInstalled\"\n\t\t{\n\t\t}\n\t}\n"
        let before = acf(installed: entry111).replacingOccurrences(of: "\t\"SizeOnDisk\"", with: nested + "\t\"SizeOnDisk\"")
        #expect(SteamWorkshopManifest.installedIDs(fromACF: before) == nil)
        let onlyNested = "\"AppWorkshop\"\n{\n" + nested + "}\n"
        #expect(SteamWorkshopManifest.installedIDs(fromACF: onlyNested) == nil)
        let twice = acf(installed: entry111).replacingOccurrences(
            of: "\t\"WorkshopItemDetails\"", with: "\t\"WorkshopItemsInstalled\"\n\t{\n\t}\n\t\"WorkshopItemDetails\""
        )
        #expect(SteamWorkshopManifest.installedIDs(fromACF: twice) == nil)
    }

    @Test("Malformed content around a complete installed block fails the whole set", arguments: [
        "unclosed root", "stray close", "trailing token", "dangling key",
    ])
    func malformedEnclosingDocumentIsRejected(damage: String) throws {
        let whole = acf(installed: entry111)
        let rootClose = try #require(whole.range(of: "}", options: .backwards))
        let text = switch damage {
        case "unclosed root": String(whole[..<rootClose.lowerBound])
        case "stray close": whole + "}\n"
        case "trailing token": whole + "garbage\n"
        default: whole.replacingOccurrences(of: "\t\"WorkshopItemDetails\"", with: "\t\"Orphan\"\n\t}\n\t\"WorkshopItemDetails\"")
        }
        #expect(SteamWorkshopManifest.installedIDs(fromACF: text) == nil)
    }

    @Test("The installed key followed by a value instead of a block is rejected")
    func installedKeyWithValueIsRejected() {
        #expect(SteamWorkshopManifest.installedIDs(fromACF: "\"WorkshopItemsInstalled\" \"bad\" \"Other\" {}") == nil)
    }

    @Test("The installed key inside a comment or a value is not the key")
    func installedKeyOutsideKeyPositionIsIgnored() {
        let commented = "// \"WorkshopItemsInstalled\" {}\n" + acf(installed: entry111)
        #expect(SteamWorkshopManifest.installedIDs(fromACF: commented) == ["111"])
        let asValue = "\"Note\" \"WorkshopItemsInstalled\"\n" + acf(installed: entry111)
        #expect(SteamWorkshopManifest.installedIDs(fromACF: asValue) == ["111"])
    }

    @Test("The walk stops at the entry budget and counts only what it visited")
    func allocatedBytesStopsAtEntryBudget() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("acf-budget-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let entryLimit = 20
        for index in 0 ..< entryLimit + 50 {
            try Data(repeating: 1, count: 1000).write(to: root.appendingPathComponent("file\(index)"))
        }
        #expect(SteamDirectorySize.allocatedBytes(at: root, entryLimit: entryLimit) == UInt64(entryLimit * 1000))
    }
}
#endif
