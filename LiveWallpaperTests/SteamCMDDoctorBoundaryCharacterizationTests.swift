#if !LITE_BUILD
    import Foundation
    @testable import LiveWallpaper
    import Testing

    @Suite("AF-12: SteamCMD Doctor boundary characterization", .serialized)
    struct SteamCMDDoctorBoundaryCharacterizationTests {















        @Test("identity selection is branch-stable and fails closed when unavailable")
        @MainActor
        func identitySelectionAndBranchMismatch() throws {
            let primary = SteamCMDWorkshopDirectoryIdentity.resource(
                fileResourceIdentifier: Data("resource".utf8),
                volumeIdentifier: Data("volume".utf8)
            )
            let fallback = SteamCMDWorkshopDirectoryIdentity.deviceAndInode(deviceID: 7, inode: 11)
            #expect(SteamCMDWorkshopFileInventory.selectIdentity(
                fileResourceIdentifier: Data("resource".utf8),
                volumeIdentifier: Data("volume".utf8),
                deviceID: 7,
                inode: 11,
                attributesAreDirectory: true
            ) == primary)
            #expect(SteamCMDWorkshopFileInventory.selectIdentity(
                fileResourceIdentifier: nil,
                volumeIdentifier: nil,
                deviceID: 7,
                inode: 11,
                attributesAreDirectory: true
            ) == fallback)
            #expect(SteamCMDWorkshopFileInventory.selectIdentity(
                fileResourceIdentifier: Data("resource".utf8),
                volumeIdentifier: nil,
                deviceID: 7,
                inode: 11,
                attributesAreDirectory: true
            ) == fallback)
            #expect(SteamCMDWorkshopFileInventory.selectIdentity(
                fileResourceIdentifier: nil,
                volumeIdentifier: nil,
                deviceID: 7,
                inode: 0,
                attributesAreDirectory: true
            ) == nil)
            #expect(SteamCMDWorkshopFileInventory.selectIdentity(
                fileResourceIdentifier: nil,
                volumeIdentifier: nil,
                deviceID: 7,
                inode: 11,
                attributesAreDirectory: false
            ) == nil)
        }

        @Test("inventory returns only numeric direct targets and rejects symlinks")
        @MainActor
        func targetOnlyInventoryEnumeration() throws {
            let fm = FileManager.default
            let root = temporaryRoot("inventory-targets")
            defer { try? fm.removeItem(at: root) }
            let steamRoot = root.appendingPathComponent("Steam", isDirectory: true)
            let content = steamRoot.appendingPathComponent(
                "steamapps/workshop/content/431960",
                isDirectory: true
            )
            let external = root.appendingPathComponent("external", isDirectory: true)
            try fm.createDirectory(at: content, withIntermediateDirectories: true)
            try fm.createDirectory(at: external, withIntermediateDirectories: true)
            try Data("external".utf8).write(to: external.appendingPathComponent("project.json"))

            func createProject(id: String) throws -> URL {
                let item = content.appendingPathComponent(id, isDirectory: true)
                try fm.createDirectory(at: item, withIntermediateDirectories: true)
                try Data(id.utf8).write(to: item.appendingPathComponent("project.json"))
                return item
            }

            let first = try createProject(id: "100")
            _ = try createProject(id: "not-an-id")
            let missingProject = content.appendingPathComponent("200", isDirectory: true)
            try fm.createDirectory(at: missingProject, withIntermediateDirectories: true)
            try fm.createSymbolicLink(
                at: content.appendingPathComponent("300", isDirectory: true),
                withDestinationURL: external
            )
            let linkedManifestItem = content.appendingPathComponent("400", isDirectory: true)
            try fm.createDirectory(at: linkedManifestItem, withIntermediateDirectories: true)
            try fm.createSymbolicLink(
                at: linkedManifestItem.appendingPathComponent("project.json"),
                withDestinationURL: external.appendingPathComponent("project.json")
            )

            let inventory = SteamCMDWorkshopFileInventory(fileManager: fm)
            let candidates = inventory.projectFolders(
                under: steamRoot,
                anchoredTo: steamRoot,
                skipping: []
            )
            #expect(candidates.map(\.url.path) == [first.path])
            #expect(inventory.projectFolders(
                under: steamRoot,
                anchoredTo: steamRoot,
                skipping: ["100"]
            ).isEmpty)

            let rebasedRoot = root.appendingPathComponent("RebasedSteam", isDirectory: true)
            try fm.createDirectory(at: rebasedRoot, withIntermediateDirectories: true)
            try fm.createSymbolicLink(
                at: rebasedRoot.appendingPathComponent("steamapps", isDirectory: true),
                withDestinationURL: external
            )
            #expect(inventory.projectFolders(
                under: rebasedRoot,
                anchoredTo: rebasedRoot,
                skipping: []
            ).isEmpty)

            let rebasedSupport = root.appendingPathComponent("RebasedSupport", isDirectory: true)
            let outsideSteam = root.appendingPathComponent("OutsideSteam", isDirectory: true)
            let outsideProject = outsideSteam
                .appendingPathComponent("steamapps/workshop/content/431960/500", isDirectory: true)
            try fm.createDirectory(at: rebasedSupport, withIntermediateDirectories: true)
            try fm.createDirectory(at: outsideProject, withIntermediateDirectories: true)
            try Data("outside".utf8).write(to: outsideProject.appendingPathComponent("project.json"))
            try fm.createSymbolicLink(
                at: rebasedSupport.appendingPathComponent("Steam", isDirectory: true),
                withDestinationURL: outsideSteam
            )
            #expect(inventory.projectFolders(
                under: rebasedSupport.appendingPathComponent("Steam", isDirectory: true),
                anchoredTo: rebasedSupport,
                skipping: []
            ).isEmpty)

            let validatedCandidate = try #require(candidates.first)
            #expect(inventory.revalidatedURL(
                for: validatedCandidate,
                requiringProjectJSON: true
            )?.path == first.path)
            let parkedItem = first.deletingLastPathComponent()
                .appendingPathComponent("100.original", isDirectory: true)
            try fm.moveItem(at: first, to: parkedItem)
            try fm.createSymbolicLink(at: first, withDestinationURL: external)
            var bodyInvoked = false
            if inventory.revalidatedURL(for: validatedCandidate, requiringProjectJSON: true) != nil {
                bodyInvoked = true
            }
            #expect(!bodyInvoked)
        }


        // MARK: - Test support

        private func temporaryRoot(_ label: String) -> URL {
            FileManager.default.temporaryDirectory
                .appendingPathComponent("AF12-\(label)-\(UUID().uuidString)", isDirectory: true)
        }

    }
#endif
