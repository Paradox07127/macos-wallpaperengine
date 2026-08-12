#if !LITE_BUILD
    import Foundation
    @testable import LiveWallpaper
    import os
    import Testing

    @Suite("AF-12: SteamCMD Doctor boundary characterization", .serialized)
    struct SteamCMDDoctorBoundaryCharacterizationTests {















        @Test("stdout download destination must be the exact approved item target")
        @MainActor
        func downloadPathContainment() throws {
            let fm = FileManager.default
            let root = temporaryRoot("download-containment")
            defer { try? fm.removeItem(at: root) }
            let appSupport = root.appendingPathComponent("Application Support", isDirectory: true)
            let workdir = root.appendingPathComponent("Workdir", isDirectory: true)
            let fixtureManager = DoctorFixtureFileManager(applicationSupport: appSupport, home: root)
            let inventory = SteamCMDWorkshopFileInventory(fileManager: fixtureManager)

            let containerItem = workshopContentRoot(appSupport: appSupport)
                .appendingPathComponent("100", isDirectory: true)
            let workdirItem = workdir
                .appendingPathComponent("steamapps/workshop/content/431960/200", isDirectory: true)
            let outsideItem = root.appendingPathComponent("outside/300", isDirectory: true)
            for item in [containerItem, workdirItem, outsideItem] {
                try fm.createDirectory(at: item, withIntermediateDirectories: true)
            }

            #expect(inventory.resolveDownloadedItemFolder(
                stdout: successLine(itemID: 100, destination: containerItem),
                itemID: 100,
                workdir: workdir
            ) == nil)
            #expect(inventory.resolveDownloadedItemFolder(
                stdout: successLine(itemID: 200, destination: workdirItem),
                itemID: 200,
                workdir: workdir
            )?.url.path == workdirItem.path)
            #expect(inventory.resolveDownloadedItemFolder(
                stdout: successLine(itemID: 300, destination: outsideItem),
                itemID: 300,
                workdir: workdir
            ) == nil)
            #expect(inventory.resolveDownloadedItemFolder(
                stdout: successLine(itemID: 100, destination: outsideItem),
                itemID: 100,
                workdir: workdir
            ) == nil)

            let external = root.appendingPathComponent("external-item", isDirectory: true)
            try fm.createDirectory(at: external, withIntermediateDirectories: true)
            let linkedItem = workdir
                .appendingPathComponent("steamapps/workshop/content/431960", isDirectory: true)
                .appendingPathComponent("400", isDirectory: true)
            try fm.createSymbolicLink(at: linkedItem, withDestinationURL: external)
            #expect(inventory.resolveDownloadedItemFolder(
                stdout: successLine(itemID: 400, destination: linkedItem),
                itemID: 400,
                workdir: workdir
            ) == nil)

            let rebasedSupport = root.appendingPathComponent("RebasedSupport", isDirectory: true)
            let outsideSteam = root.appendingPathComponent("OutsideSteam", isDirectory: true)
            let outsideSteamItem = outsideSteam
                .appendingPathComponent("steamapps/workshop/content/431960/500", isDirectory: true)
            try fm.createDirectory(at: rebasedSupport, withIntermediateDirectories: true)
            try fm.createDirectory(at: outsideSteamItem, withIntermediateDirectories: true)
            try fm.createSymbolicLink(
                at: rebasedSupport.appendingPathComponent("Steam", isDirectory: true),
                withDestinationURL: outsideSteam
            )
            let rebasedInventory = SteamCMDWorkshopFileInventory(
                fileManager: DoctorFixtureFileManager(applicationSupport: rebasedSupport, home: root)
            )
            #expect(rebasedInventory.resolveDownloadedItemFolder(
                stdout: successLine(itemID: 500, destination: outsideSteamItem),
                itemID: 500,
                workdir: workdir
            ) == nil)

            let validatedCandidate = try #require(inventory.resolveDownloadedItemFolder(
                stdout: successLine(itemID: 200, destination: workdirItem),
                itemID: 200,
                workdir: workdir
            ))
            #expect(inventory.revalidatedURL(
                for: validatedCandidate,
                requiringProjectJSON: false
            )?.path == workdirItem.path)
            let parkedItem = workdirItem.deletingLastPathComponent()
                .appendingPathComponent("200.original", isDirectory: true)
            try fm.moveItem(at: workdirItem, to: parkedItem)
            try fm.createSymbolicLink(at: workdirItem, withDestinationURL: outsideItem)
            var callbackInvoked = false
            if inventory.revalidatedURL(for: validatedCandidate, requiringProjectJSON: false) != nil {
                callbackInvoked = true
            }
            #expect(!callbackInvoked)
        }

        @Test("disk fallback finds a validated item directory when stdout never printed the success line")
        @MainActor
        func diskFallbackLocatesValidatedItemWithoutStdout() throws {
            let fm = FileManager.default
            let root = temporaryRoot("disk-fallback")
            defer { try? fm.removeItem(at: root) }
            let appSupport = root.appendingPathComponent("Application Support", isDirectory: true)
            let workdir = root.appendingPathComponent("Workdir", isDirectory: true)
            let inventory = SteamCMDWorkshopFileInventory(
                fileManager: DoctorFixtureFileManager(applicationSupport: appSupport, home: root)
            )

            #expect(inventory.validatedItemDirectory(itemID: 100, workdir: workdir) == nil)

            let containerItem = workshopContentRoot(appSupport: appSupport)
                .appendingPathComponent("100", isDirectory: true)
            try fm.createDirectory(at: containerItem, withIntermediateDirectories: true)
            #expect(inventory.validatedItemDirectory(itemID: 100, workdir: workdir) == nil)

            let workdirItem = workdir
                .appendingPathComponent("steamapps/workshop/content/431960/200", isDirectory: true)
            try fm.createDirectory(at: workdirItem, withIntermediateDirectories: true)
            let workdirResolved = try #require(inventory.validatedItemDirectory(itemID: 200, workdir: workdir))
            #expect(workdirResolved.url.path == workdirItem.path)

            #expect(inventory.validatedItemDirectory(itemID: 300, workdir: workdir) == nil)
        }

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

            let fm = FileManager.default
            let root = temporaryRoot("identity-branches")
            defer { try? fm.removeItem(at: root) }
            let appSupport = root.appendingPathComponent("Application Support", isDirectory: true)
            let workdir = root.appendingPathComponent("Workdir", isDirectory: true)
            let item = workdir
                .appendingPathComponent("steamapps/workshop/content/431960", isDirectory: true)
                .appendingPathComponent("100", isDirectory: true)
            try fm.createDirectory(at: item, withIntermediateDirectories: true)
            let fixtureManager = DoctorFixtureFileManager(applicationSupport: appSupport, home: root)

            func candidate(
                using inventory: SteamCMDWorkshopFileInventory
            ) -> SteamCMDValidatedWorkshopItem? {
                inventory.resolveDownloadedItemFolder(
                    stdout: successLine(itemID: 100, destination: item),
                    itemID: 100,
                    workdir: workdir
                )
            }

            let primaryInventory = SteamCMDWorkshopFileInventory(
                fileManager: fixtureManager,
                identityReader: { _, _, _ in primary }
            )
            let primaryCandidate = try #require(candidate(using: primaryInventory))
            #expect(primaryInventory.revalidatedURL(
                for: primaryCandidate,
                requiringProjectJSON: false
            )?.path == item.path)

            let fallbackInventory = SteamCMDWorkshopFileInventory(
                fileManager: fixtureManager,
                identityReader: { _, _, _ in fallback }
            )
            let fallbackCandidate = try #require(candidate(using: fallbackInventory))
            #expect(fallbackInventory.revalidatedURL(
                for: fallbackCandidate,
                requiringProjectJSON: false
            )?.path == item.path)

            let unavailableInventory = SteamCMDWorkshopFileInventory(
                fileManager: fixtureManager,
                identityReader: { _, _, _ in nil }
            )
            #expect(candidate(using: unavailableInventory) == nil)
            let invalidFallbackInventory = SteamCMDWorkshopFileInventory(
                fileManager: fixtureManager,
                identityReader: { _, _, _ in .deviceAndInode(deviceID: 7, inode: 0) }
            )
            #expect(candidate(using: invalidFallbackInventory) == nil)

            let identityReadCount = OSAllocatedUnfairLock(initialState: 0)
            let mismatchInventory = SteamCMDWorkshopFileInventory(
                fileManager: fixtureManager,
                identityReader: { _, _, _ in
                    identityReadCount.withLock { count in
                        count += 1
                        return count == 1 ? primary : fallback
                    }
                }
            )
            let mismatchedCandidate = try #require(candidate(using: mismatchInventory))
            #expect(mismatchInventory.revalidatedURL(
                for: mismatchedCandidate,
                requiringProjectJSON: false
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

        private func containerScopedFixtureRoot(_ label: String) -> URL {
            URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
                .appendingPathComponent(
                    "Library/Caches/LiveWallpaper-AF12-\(label)-\(UUID().uuidString)",
                    isDirectory: true
                )
        }

        private func workshopContentRoot(appSupport: URL) -> URL {
            appSupport.appendingPathComponent(
                "Steam/steamapps/workshop/content/431960",
                isDirectory: true
            )
        }

        private func successLine(itemID: UInt64, destination: URL) -> String {
            "Success. Downloaded item \(itemID) to \"\(destination.path(percentEncoded: false))\" (1 bytes after 1 chunks)"
        }

        private func pathContains(_ child: URL, in parent: URL) -> Bool {
            let childPath = child.standardizedFileURL.resolvingSymlinksInPath().path
            let parentPath = parent.standardizedFileURL.resolvingSymlinksInPath().path
            return childPath == parentPath || childPath.hasPrefix(parentPath + "/")
        }

        @MainActor
        private func makeDoctor(applicationSupport: URL, home: URL) -> SteamCMDDoctorService {
            let suiteName = "AF12.Doctor.\(UUID().uuidString)"
            let defaults = UserDefaults(suiteName: suiteName)!
            defaults.removePersistentDomain(forName: suiteName)
            return SteamCMDDoctorService(
                defaults: defaults,
                fileManager: DoctorFixtureFileManager(applicationSupport: applicationSupport, home: home)
            )
        }

        private func doctorSource() throws -> String {
            try productionSource(
                "LiveWallpaper/Infrastructure/Workshop/Doctor/SteamCMDDoctorService.swift"
            )
        }

        private func operationsSource() throws -> String {
            try productionSource(
                "LiveWallpaper/Infrastructure/Workshop/Doctor/SteamCMDDoctorOperations.swift"
            )
        }

        private func productionSource(_ relativePath: String) throws -> String {
            let projectRoot = URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
            return try String(
                contentsOf: projectRoot.appendingPathComponent(relativePath),
                encoding: .utf8
            )
        }

        private func slice(_ source: String, from start: String, until end: String) throws -> String {
            let startRange = try #require(source.range(of: start))
            let endRange = try #require(source.range(of: end, range: startRange.upperBound ..< source.endIndex))
            return String(source[startRange.lowerBound ..< endRange.lowerBound])
        }
    }

    private final class DoctorFixtureFileManager: FileManager, @unchecked Sendable {
        private let applicationSupport: URL
        private let home: URL

        init(applicationSupport: URL, home: URL) {
            self.applicationSupport = applicationSupport
            self.home = home
            super.init()
        }

        override func url(
            for directory: FileManager.SearchPathDirectory,
            in domain: FileManager.SearchPathDomainMask,
            appropriateFor url: URL?,
            create shouldCreate: Bool
        ) throws -> URL {
            if directory == .applicationSupportDirectory {
                return applicationSupport
            }
            return try super.url(for: directory, in: domain, appropriateFor: url, create: shouldCreate)
        }

        override var homeDirectoryForCurrentUser: URL {
            home
        }
    }
#endif
