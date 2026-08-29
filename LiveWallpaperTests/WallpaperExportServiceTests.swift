import AVFoundation
import Foundation
import LiveWallpaperCore
import Testing

@testable import LiveWallpaper

/// File-system effects and status machine of the system-wallpaper publish
/// path, against an injected temp root (plan §4.5 / §4.6). Thumbnails are
/// stubbed — no real video decoding in unit tests.
@MainActor
@Suite("WallpaperExportService")
struct WallpaperExportServiceTests {
    private static let referenceNow = Date(timeIntervalSince1970: 1_760_000_000)

    private struct Rig {
        let service: WallpaperExportService
        let root: URL
        let sourceDirectory: URL

        var manifestURL: URL { root.appendingPathComponent("manifest.json") }
        var heartbeatURL: URL { root.appendingPathComponent("heartbeat.json") }
        var videosDirectory: URL { root.appendingPathComponent("Videos") }

        func makeVideoBookmark(
            named fileName: String = "clip.mp4",
            bytes: Data = Data("fake-video-bytes".utf8),
            label: String = "Sunset"
        ) throws -> WallpaperBookmark {
            let url = sourceDirectory.appendingPathComponent(fileName)
            try bytes.write(to: url)
            // The stub resolver decodes the path back out of the bookmark data.
            return WallpaperBookmark(
                label: label,
                content: .video(bookmarkData: Data(url.path.utf8), packageEntryName: nil)
            )
        }


        /// Mirrors what the Workshop importer produces: the bookmark points at
        /// `scene.pkg` and the video lives inside it under `entryName`.
        func makePackagedVideoBookmark(
            entryName: String = "video.mp4",
            bytes: Data = Data("packaged-video-bytes".utf8),
            label: String = "Workshop Clip"
        ) throws -> (bookmark: WallpaperBookmark, payload: Data) {
            func u32(_ value: UInt32) -> Data {
                withUnsafeBytes(of: value.littleEndian) { Data($0) }
            }
            let magic = "PKGV0001"
            var header = Data()
            header.append(u32(UInt32(magic.utf8.count)))
            header.append(contentsOf: magic.utf8)
            header.append(u32(1))
            let nameBytes = Array(entryName.utf8)
            header.append(u32(UInt32(nameBytes.count)))
            header.append(contentsOf: nameBytes)
            header.append(u32(0))
            header.append(u32(UInt32(bytes.count)))

            let url = sourceDirectory.appendingPathComponent("scene.pkg")
            try (header + bytes).write(to: url)
            return (
                WallpaperBookmark(
                    label: label,
                    content: .video(bookmarkData: Data(url.path.utf8), packageEntryName: entryName)
                ),
                bytes
            )
        }

        func writeHeartbeat(_ heartbeat: SystemWallpaperHeartbeat) throws {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
            try JSONEncoder().encode(heartbeat).write(to: heartbeatURL)
        }

        func manifestOnDisk() throws -> SystemWallpaperManifest {
            try JSONDecoder().decode(SystemWallpaperManifest.self, from: Data(contentsOf: manifestURL))
        }
    }

    /// Lets a test run code at the one moment a publish has yielded the main
    /// actor — between the staged copy and the commit — which is the window a
    /// concurrent remove has to land in.
    @MainActor
    private final class PublishHook {
        var run: (() -> Void)?
        /// Fires once: the setup publish a test does first must not trip it.
        func fire() {
            let pending = run
            run = nil
            pending?()
        }
    }

    private func makeRig(
        osSupported: Bool = true,
        thumbnailJPEG: Data? = Data([0xFF, 0xD8, 0xFF, 0xE0]),
        now: Date = referenceNow,
        duringThumbnail: PublishHook? = nil
    ) throws -> Rig {
        let base = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("WallpaperExportServiceTests-\(UUID().uuidString)")
        let root = base.appendingPathComponent("SystemWallpaper")
        let sources = base.appendingPathComponent("Sources")
        try FileManager.default.createDirectory(at: sources, withIntermediateDirectories: true)

        let resolver = SecurityScopedBookmarkResolver(
            resolveData: { data in
                guard let path = String(data: data, encoding: .utf8) else {
                    throw CocoaError(.fileReadCorruptFile)
                }
                return (URL(fileURLWithPath: path), false)
            },
            refreshData: { _ in Data() }
        )
        let service = WallpaperExportService(dependencies: .init(
            sharedRoot: root,
            resolver: resolver,
            now: { now },
            makeThumbnailJPEG: { _ in
                if let duringThumbnail { await MainActor.run { duringThumbnail.fire() } }
                return thumbnailJPEG
            },
            osSupported: osSupported
        ))
        return Rig(service: service, root: root, sourceDirectory: sources)
    }

    // MARK: - Publish

    @Test("Shared removal deletes both files — the path the system's own Remove takes")
    func sharedRemovalDeletesFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SharedRemoval-\(UUID().uuidString)")
        let videos = root.appendingPathComponent("Videos")
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        let video = videos.appendingPathComponent("clip.mp4")
        let thumbnail = videos.appendingPathComponent("clip.jpg")
        try Data("v".utf8).write(to: video)
        try Data("t".utf8).write(to: thumbnail)

        let manifest = SystemWallpaperManifest(
            version: SystemWallpaperManifest.currentVersion,
            items: [
                .init(id: "keep", title: "Keep", fileName: "other.mp4", thumbnailFileName: nil, addedAt: Self.referenceNow),
                .init(id: "drop", title: "Drop", fileName: "clip.mp4", thumbnailFileName: "clip.jpg", addedAt: Self.referenceNow)
            ]
        )

        var persisted: SystemWallpaperManifest?
        let updated = try #require(try SystemWallpaperLibrary.remove(
            id: "drop", from: manifest, videosDirectory: videos,
            persist: { persisted = $0 }
        ))

        #expect(updated.items.map(\.id) == ["keep"])
        #expect(persisted?.items.map(\.id) == ["keep"], "the shrunk manifest must be persisted")
        #expect(!FileManager.default.fileExists(atPath: video.path), "the video must not be left on disk")
        #expect(!FileManager.default.fileExists(atPath: thumbnail.path), "the thumbnail must not be left on disk")
    }

    @Test("A failed manifest persist deletes nothing — no entry may ever point at a missing file")
    func sharedRemovalKeepsFilesWhenPersistFails() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SharedRemovalPersistFail-\(UUID().uuidString)")
        let videos = root.appendingPathComponent("Videos")
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        let video = videos.appendingPathComponent("clip.mp4")
        try Data("v".utf8).write(to: video)
        let manifest = SystemWallpaperManifest(
            version: SystemWallpaperManifest.currentVersion,
            items: [.init(id: "drop", title: "Drop", fileName: "clip.mp4", thumbnailFileName: nil, addedAt: Self.referenceNow)]
        )

        struct Boom: Error {}
        #expect(throws: Boom.self) {
            try SystemWallpaperLibrary.remove(
                id: "drop", from: manifest, videosDirectory: videos,
                persist: { _ in throw Boom() }
            )
        }
        #expect(FileManager.default.fileExists(atPath: video.path),
                "persist failed, so the file must survive")
    }

    @Test("Removing an id that is not in the manifest is a no-op, not an empty rewrite")
    func sharedRemovalIgnoresUnknownID() throws {
        let manifest = SystemWallpaperManifest(
            version: SystemWallpaperManifest.currentVersion,
            items: [.init(id: "keep", title: "Keep", fileName: "a.mp4", thumbnailFileName: nil, addedAt: Self.referenceNow)]
        )
        var persistCalls = 0
        #expect(try SystemWallpaperLibrary.remove(
            id: "ghost",
            from: manifest,
            videosDirectory: URL(fileURLWithPath: NSTemporaryDirectory()),
            persist: { _ in persistCalls += 1 }
        ) == nil)
        #expect(persistCalls == 0)
    }

    @Test("The orphan sweep reclaims old unreferenced files and spares young and referenced ones")
    func sweepOrphansReclaimsOldUnreferencedFiles() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OrphanSweep-\(UUID().uuidString)")
        let videos = root.appendingPathComponent("Videos")
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        let referenced = videos.appendingPathComponent("keep.mp4")
        let oldOrphan = videos.appendingPathComponent("orphan.mp4")
        let youngOrphan = videos.appendingPathComponent("young.mp4")
        for url in [referenced, oldOrphan, youngOrphan] { try Data("x".utf8).write(to: url) }
        let past = Self.referenceNow.addingTimeInterval(-7200)
        for url in [referenced, oldOrphan] {
            try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: url.path)
        }
        let manifest = SystemWallpaperManifest(
            version: SystemWallpaperManifest.currentVersion,
            items: [.init(id: "keep", title: "Keep", fileName: "keep.mp4", thumbnailFileName: nil, addedAt: past)]
        )

        SystemWallpaperLibrary.sweepOrphans(
            manifest: manifest, videosDirectory: videos, now: Self.referenceNow
        )

        #expect(FileManager.default.fileExists(atPath: referenced.path), "referenced files stay")
        #expect(!FileManager.default.fileExists(atPath: oldOrphan.path), "old orphans are reclaimed")
        #expect(FileManager.default.fileExists(atPath: youngOrphan.path),
                "a fresh file may be a publish mid-copy — the age guard spares it")
    }

    @Test("A staging file mid-copy survives the sweep even when the source was old")
    func sweepSparesStagingWithAncientSourceMtime() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OrphanSweepStaging-\(UUID().uuidString)")
        let videos = root.appendingPathComponent("Videos")
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)

        // `copyItem` carries the source's mtime over, so a staging file for a
        // year-old video reads as ancient the whole time the copy is running.
        let staging = videos.appendingPathComponent(
            SystemWallpaperLibrary.stagingFileName(itemID: "pending", ext: "mp4", now: Self.referenceNow)
        )
        try Data("partial".utf8).write(to: staging)
        try FileManager.default.setAttributes(
            [.modificationDate: Self.referenceNow.addingTimeInterval(-365 * 86400)],
            ofItemAtPath: staging.path
        )

        SystemWallpaperLibrary.sweepOrphans(
            manifest: .empty, videosDirectory: videos, now: Self.referenceNow
        )

        #expect(FileManager.default.fileExists(atPath: staging.path),
                "the sweep must key off the staging file's own age, not the copied mtime")
    }

    @Test("An abandoned staging file is still reclaimed once it is far too old to be live")
    func sweepReclaimsAbandonedStaging() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OrphanSweepStale-\(UUID().uuidString)")
        let videos = root.appendingPathComponent("Videos")
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        let staging = videos.appendingPathComponent(
            SystemWallpaperLibrary.stagingFileName(
                itemID: "crashed", ext: "mp4",
                now: Self.referenceNow.addingTimeInterval(-48 * 3600)
            )
        )
        try Data("partial".utf8).write(to: staging)

        SystemWallpaperLibrary.sweepOrphans(
            manifest: .empty, videosDirectory: videos, now: Self.referenceNow
        )

        #expect(!FileManager.default.fileExists(atPath: staging.path),
                "a staging file from two days ago cannot still be copying")
    }

    @Test("The manifest lock fails closed — an unlockable root must not run unserialized")
    func lockFailsClosedRatherThanRunningUnserialized() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("LockFailClosed-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        // A directory where the lock file belongs makes `open(…, O_WRONLY)`
        // fail with EISDIR — the stand-in for any environment where the lock
        // cannot be taken.
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("manifest.lock"), withIntermediateDirectories: true
        )

        var ran = false
        #expect(throws: (any Error).self) {
            try SystemWallpaperLock.withExclusiveLock(root: root) { ran = true }
        }
        #expect(!ran, "running the mutation unlocked is the lost update this lock exists to prevent")
    }

    @Test("A corrupt manifest fails the publish instead of rewriting the library away")
    func corruptManifestDoesNotSwallowExistingItems() async throws {
        let rig = try makeRig()
        let bookmark = try rig.makeVideoBookmark(named: "first.mp4", label: "First")
        try await rig.service.publish(bookmark: bookmark)
        let before = try rig.manifestOnDisk()
        #expect(before.items.count == 1)
        let survivingFile = before.items[0].fileName

        try Data("{ not json".utf8).write(to: rig.manifestURL)

        let second = try rig.makeVideoBookmark(named: "second.mp4", label: "Second")
        await #expect(throws: (any Error).self) {
            try await rig.service.publish(bookmark: second)
        }
        #expect(
            FileManager.default.fileExists(
                atPath: rig.root.appendingPathComponent("Videos/\(survivingFile)").path),
            "a corrupt manifest must never turn already-published videos into sweepable orphans"
        )
    }

    /// `chmod 000`: present, and `Data(contentsOf:)` fails with a read error
    /// rather than "no such file" — the case that used to be read as an empty
    /// library. An atomic write would still succeed here, so the manifest is
    /// checked afterwards rather than assuming the write must fail.
    private func denyReads(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0], ofItemAtPath: url.path)
    }

    private func allowReads(_ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: url.path)
    }

    @Test("A manifest that exists but cannot be read fails the publish like a corrupt one")
    func unreadableManifestFailsPublish() async throws {
        let rig = try makeRig()
        let first = try rig.makeVideoBookmark(named: "first.mp4", label: "First")
        try await rig.service.publish(bookmark: first)
        try denyReads(rig.manifestURL)

        let second = try rig.makeVideoBookmark(named: "second.mp4", label: "Second")
        await #expect(throws: (any Error).self) {
            try await rig.service.publish(bookmark: second)
        }

        try allowReads(rig.manifestURL)
        let manifest = try rig.manifestOnDisk()
        #expect(
            manifest.items.map(\.id) == [first.id.uuidString],
            "an unreadable manifest must not be rewritten from scratch: \(manifest.items.map(\.title))"
        )
    }

    @Test("A republish that fails after the swap restores the video it displaced")
    func failedRepublishRestoresPreviousFiles() async throws {
        let rig = try makeRig()
        let original = Data("original-payload".utf8)
        let first = try rig.makeVideoBookmark(named: "first.mp4", bytes: original, label: "First")
        try await rig.service.publish(bookmark: first)
        let published = rig.videosDirectory.appendingPathComponent("\(first.id.uuidString).mp4")
        let thumbnail = rig.videosDirectory.appendingPathComponent("\(first.id.uuidString).jpg")

        // Same bookmark ID → republish. The manifest read is the step that
        // fails, which lands after the live copy has already been swapped.
        let replacement = WallpaperBookmark(
            label: "First",
            content: try rig.makeVideoBookmark(
                named: "second.mp4", bytes: Data("replacement-payload".utf8), label: "First"
            ).content,
            id: first.id
        )
        try denyReads(rig.manifestURL)
        await #expect(throws: (any Error).self) {
            try await rig.service.publish(bookmark: replacement)
        }
        try allowReads(rig.manifestURL)

        #expect(
            try Data(contentsOf: published) == original,
            "a failed republish must leave the copy the manifest still points at"
        )
        #expect(FileManager.default.fileExists(atPath: thumbnail.path))
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: rig.videosDirectory.path)
            .filter { $0.contains("backup-") }
        #expect(leftovers.isEmpty, "the restore must not leave its backup behind: \(leftovers)")
    }

    @Test("A republish under a new extension keeps the thumbnail the old entry points at")
    func failedRepublishWithNewExtensionKeepsThumbnail() async throws {
        let rig = try makeRig()
        let bookmark = try rig.makeVideoBookmark(named: "first.mp4", bytes: Data("original".utf8))
        try await rig.service.publish(bookmark: bookmark)
        let itemID = bookmark.id.uuidString
        let publishedVideo = rig.videosDirectory.appendingPathComponent("\(itemID).mp4")
        let thumbnail = rig.videosDirectory.appendingPathComponent("\(itemID).jpg")

        // Same item, different container: the destination is `<id>.mov`, which
        // does not exist yet, while the thumbnail keeps its one name.
        let replacement = WallpaperBookmark(
            label: "First",
            content: try rig.makeVideoBookmark(
                named: "second.mov", bytes: Data("replacement".utf8)
            ).content,
            id: bookmark.id
        )
        try denyReads(rig.manifestURL)
        await #expect(throws: (any Error).self) {
            try await rig.service.publish(bookmark: replacement)
        }
        try allowReads(rig.manifestURL)

        #expect(FileManager.default.fileExists(atPath: thumbnail.path),
                "the manifest still names this thumbnail — deleting it erases the tile from the panel")
        #expect(try Data(contentsOf: publishedVideo) == Data("original".utf8))
        #expect(!FileManager.default.fileExists(
            atPath: rig.videosDirectory.appendingPathComponent("\(itemID).mov").path),
            "the half-published new copy must be taken back")
    }

    @Test("A republish under a new extension drops the copy the old entry named")
    func republishWithNewExtensionRemovesOldVideo() async throws {
        let rig = try makeRig()
        let bookmark = try rig.makeVideoBookmark(named: "first.mp4", bytes: Data("original".utf8))
        try await rig.service.publish(bookmark: bookmark)
        let itemID = bookmark.id.uuidString

        let replacement = WallpaperBookmark(
            label: "First",
            content: try rig.makeVideoBookmark(
                named: "second.mov", bytes: Data("replacement".utf8)
            ).content,
            id: bookmark.id
        )
        try await rig.service.publish(bookmark: replacement)

        #expect(rig.service.items.map(\.fileName) == ["\(itemID).mov"])
        #expect(!FileManager.default.fileExists(
            atPath: rig.videosDirectory.appendingPathComponent("\(itemID).mp4").path),
            "nothing references the old copy any more, and it is a whole video")
    }

    @Test("A remove that lands mid-publish keeps the entry removed")
    func removeDuringPublishIsNotUndone() async throws {
        let hook = PublishHook()
        let rig = try makeRig(duringThumbnail: hook)
        let bookmark = try rig.makeVideoBookmark(bytes: Data("original".utf8))
        try await rig.service.publish(bookmark: bookmark)
        let itemID = bookmark.id.uuidString

        // The user hits Remove while the republish is still copying: the
        // commit happens after, and used to write the entry straight back.
        hook.run = { try? rig.service.remove(itemID: itemID) }
        let replacement = WallpaperBookmark(
            label: "Replacement",
            content: try rig.makeVideoBookmark(
                named: "second.mp4", bytes: Data("replacement".utf8)
            ).content,
            id: bookmark.id
        )
        await #expect(throws: (any Error).self) {
            try await rig.service.publish(bookmark: replacement)
        }

        #expect(rig.service.items.isEmpty, "the removed entry must not come back")
        #expect(try rig.manifestOnDisk().items.isEmpty)
        let leftovers = try FileManager.default
            .contentsOfDirectory(atPath: rig.videosDirectory.path)
            .filter { $0 != "manifest.lock" }
        #expect(leftovers.isEmpty, "nor its files: \(leftovers)")
    }

    @Test("A failure in the middle of a multi-file import is not erased by a later success")
    func batchPublishKeepsMidListFailure() async throws {
        let rig = try makeRig()
        let first = rig.sourceDirectory.appendingPathComponent("one.mp4")
        let third = rig.sourceDirectory.appendingPathComponent("three.mp4")
        for url in [first, third] { try Data("bytes".utf8).write(to: url) }
        let missing = rig.sourceDirectory.appendingPathComponent("two.mp4")

        await rig.service.publish(fileURLs: [first, missing, third])

        #expect(rig.service.items.count == 2, "the readable files still publish")
        let reported = try #require(rig.service.lastError)
        #expect(reported.contains("two.mp4"),
                "the middle failure must survive the later success: \(reported)")
    }

    @Test("A republish's displaced backup outlives a concurrent sweep")
    func sweepSparesRepublishBackup() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("OrphanSweepBackup-\(UUID().uuidString)")
        let videos = root.appendingPathComponent("Videos")
        try FileManager.default.createDirectory(at: videos, withIntermediateDirectories: true)
        // The backup *is* the previously published video, so it carries that
        // file's mtime — months old for anything published a while ago.
        let backup = videos.appendingPathComponent(
            SystemWallpaperLibrary.transientBackupName(
                itemID: "live", ext: "mp4", tag: UUID(), now: Self.referenceNow
            )
        )
        try Data("displaced".utf8).write(to: backup)
        try FileManager.default.setAttributes(
            [.modificationDate: Self.referenceNow.addingTimeInterval(-365 * 86400)],
            ofItemAtPath: backup.path
        )

        SystemWallpaperLibrary.sweepOrphans(
            manifest: .empty, videosDirectory: videos, now: Self.referenceNow
        )

        #expect(FileManager.default.fileExists(atPath: backup.path),
                "sweeping the rollback copy away mid-republish makes the rollback lose the video")
    }

    @Test("A manifest entry whose file name escapes Videos/ is dropped at decode")
    func manifestDropsTraversalFileNames() throws {
        let json = """
        {"version":1,"items":[
          {"id":"evil","title":"Evil","fileName":"../../escape.mp4","addedAt":0},
          {"id":"ok","title":"OK","fileName":"fine.mp4","addedAt":0},
          {"id":"evilthumb","title":"T","fileName":"fine2.mp4","thumbnailFileName":"../t.jpg","addedAt":0}
        ]}
        """
        let manifest = try JSONDecoder().decode(SystemWallpaperManifest.self, from: Data(json.utf8))
        #expect(manifest.items.map(\.id) == ["ok"],
                "both the traversal fileName and the traversal thumbnail must be dropped")
    }

    @Test("A Workshop video is sliced out of its package, not copied whole")
    func publishExtractsPackagedVideo() async throws {
        let rig = try makeRig()
        let (bookmark, payload) = try rig.makePackagedVideoBookmark()

        try await rig.service.publish(bookmark: bookmark)

        // Extension comes from the entry inside the package, not from scene.pkg.
        let extracted = rig.videosDirectory.appendingPathComponent("\(bookmark.id.uuidString).mp4")
        #expect(try Data(contentsOf: extracted) == payload)
        let item = try #require(rig.manifestOnDisk().items.first)
        #expect(item.fileName == "\(bookmark.id.uuidString).mp4")
    }

    @Test("A package missing the named video fails instead of publishing an empty file")
    func publishRejectsMissingPackageEntry() async throws {
        let rig = try makeRig()
        let (bookmark, _) = try rig.makePackagedVideoBookmark(entryName: "video.mp4")
        let broken = WallpaperBookmark(
            label: bookmark.label,
            content: .video(
                bookmarkData: Data(rig.sourceDirectory.appendingPathComponent("scene.pkg").path.utf8),
                packageEntryName: "missing.mp4"
            )
        )

        await #expect(throws: (any Error).self) {
            try await rig.service.publish(bookmark: broken)
        }
        #expect(rig.service.items.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: rig.videosDirectory.appendingPathComponent("\(broken.id.uuidString).mp4").path
        ))
    }

    @Test("Publish copies the video, writes the thumbnail, and records both in the manifest")
    func publishWritesFilesAndManifest() async throws {
        let rig = try makeRig()
        let bytes = Data("unique-payload-\(UUID())".utf8)
        let bookmark = try rig.makeVideoBookmark(bytes: bytes, label: "Sunset")

        try await rig.service.publish(bookmark: bookmark)

        let copied = rig.videosDirectory.appendingPathComponent("\(bookmark.id.uuidString).mp4")
        #expect(try Data(contentsOf: copied) == bytes)
        let thumbnail = rig.videosDirectory.appendingPathComponent("\(bookmark.id.uuidString).jpg")
        #expect(FileManager.default.fileExists(atPath: thumbnail.path))

        let manifest = try rig.manifestOnDisk()
        #expect(manifest.version == SystemWallpaperManifest.currentVersion)
        let item = try #require(manifest.items.first)
        #expect(item.id == bookmark.id.uuidString)
        #expect(item.title == "Sunset")
        #expect(item.fileName == copied.lastPathComponent)
        #expect(item.thumbnailFileName == thumbnail.lastPathComponent)
        #expect(item.addedAt == Self.referenceNow)

        #expect(rig.service.items == manifest.items)
        #expect(rig.service.isPublished(bookmarkID: bookmark.id))
        #expect(rig.service.diskUsageBytes > 0)
    }

    @Test("A failed thumbnail fails the publish and rolls the copy back — the panel refuses thumbnailless tiles")
    func publishFailsWithoutThumbnail() async throws {
        let rig = try makeRig(thumbnailJPEG: nil)
        let bookmark = try rig.makeVideoBookmark()

        await #expect(throws: WallpaperExportService.ServiceError.thumbnailFailed) {
            try await rig.service.publish(bookmark: bookmark)
        }

        #expect(rig.service.items.isEmpty, "a choice invisible in the panel must not be recorded")
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: rig.videosDirectory.path)) ?? []
        #expect(leftovers.filter { !$0.hasPrefix(".") && $0 != "manifest.lock" }.isEmpty,
                "the copied video must be rolled back, not stranded: \(leftovers)")
    }

    @Test("A failed republish leaves the published copy playable — the live file is only touched by the atomic swap")
    func republishThumbnailFailureKeepsOldCopy() async throws {
        let rig = try makeRig()
        let bookmark = try rig.makeVideoBookmark(bytes: Data("original-bytes".utf8))
        try await rig.service.publish(bookmark: bookmark)
        let fileName = try #require(rig.service.items.first?.fileName)
        let published = rig.videosDirectory.appendingPathComponent(fileName)

        // Same shared root, but thumbnails now fail — the republish must
        // abort before it touches the live copy.
        let failing = WallpaperExportService(dependencies: .init(
            sharedRoot: rig.root,
            resolver: SecurityScopedBookmarkResolver(
                resolveData: { data in
                    guard let path = String(data: data, encoding: .utf8) else {
                        throw CocoaError(.fileReadCorruptFile)
                    }
                    return (URL(fileURLWithPath: path), false)
                },
                refreshData: { _ in Data() }
            ),
            now: { Date(timeIntervalSince1970: 1_760_000_000) },
            makeThumbnailJPEG: { _ in nil },
            osSupported: true
        ))
        await #expect(throws: WallpaperExportService.ServiceError.thumbnailFailed) {
            try await failing.publish(bookmark: bookmark)
        }

        #expect(FileManager.default.fileExists(atPath: published.path),
                "the already-published video must survive a failed republish")
        #expect(try String(data: Data(contentsOf: published), encoding: .utf8) == "original-bytes")
        #expect(failing.items.map(\.id) == [bookmark.id.uuidString],
                "the manifest entry must still be there and still valid")
    }

    @Test("Publish rejects content that is not a video at all")
    func publishRejectsUnsupportedContent() async throws {
        let rig = try makeRig()
        let web = WallpaperBookmark(
            label: "Web",
            content: .html(source: .file(bookmarkData: Data("x".utf8)), config: .default)
        )
        await #expect(throws: WallpaperExportService.ServiceError.unsupportedContent) {
            try await rig.service.publish(bookmark: web)
        }
        #expect(rig.service.lastError != nil)
        #expect(!FileManager.default.fileExists(atPath: rig.manifestURL.path))
    }


    // MARK: - Remove

    @Test("Remove deletes both files and rewrites the manifest")
    func removeCleansUp() async throws {
        let rig = try makeRig()
        let bookmark = try rig.makeVideoBookmark()
        try await rig.service.publish(bookmark: bookmark)
        let itemID = bookmark.id.uuidString

        try rig.service.remove(itemID: itemID)

        #expect(rig.service.items.isEmpty)
        #expect(try rig.manifestOnDisk().items.isEmpty)
        let leftovers = try FileManager.default.contentsOfDirectory(atPath: rig.videosDirectory.path)
        #expect(leftovers.isEmpty)
        #expect(rig.service.diskUsageBytes == 0)
    }

    @Test("Removing the item the system is playing is allowed — it is the only way out")
    func removeAllowsInUseItem() async throws {
        let rig = try makeRig()
        let bookmark = try rig.makeVideoBookmark()
        try await rig.service.publish(bookmark: bookmark)
        let itemID = bookmark.id.uuidString
        try rig.writeHeartbeat(SystemWallpaperHeartbeat(
            timestamp: Self.referenceNow.addingTimeInterval(-30),
            activeChoiceID: itemID
        ))
        rig.service.refresh()
        #expect(rig.service.isItemInUse(itemID), "precondition: the heartbeat says this one is on screen")

        // macOS 27.0's wallpaper pane crashes in its own Remove handler for
        // third-party choices, so refusing here would strand the files forever.
        try rig.service.remove(itemID: itemID)

        #expect(rig.service.items.isEmpty)
        #expect(!FileManager.default.fileExists(
            atPath: rig.videosDirectory.appendingPathComponent("\(itemID).mp4").path
        ))
    }


    // MARK: - Status machine

    @Test("Unsupported OS wins over everything else")
    func statusUnsupported() throws {
        let rig = try makeRig(osSupported: false)
        #expect(rig.service.status == .unsupported)
    }

    @Test("An unhealthy heartbeat reads as system-incompatible")
    func statusSystemIncompatible() async throws {
        let rig = try makeRig()
        let bookmark = try rig.makeVideoBookmark()
        try await rig.service.publish(bookmark: bookmark)
        try rig.writeHeartbeat(SystemWallpaperHeartbeat(
            timestamp: Self.referenceNow.addingTimeInterval(-10),
            activeChoiceID: nil,
            runtimeHealthy: false
        ))
        rig.service.refresh()
        #expect(rig.service.status == .systemIncompatible)
    }

    @Test("An unhealthy verdict from a different OS build is ignored — the layout may be fine after an update")
    func statusIgnoresStaleOSVersionVerdict() async throws {
        let rig = try makeRig()
        let bookmark = try rig.makeVideoBookmark()
        try await rig.service.publish(bookmark: bookmark)
        try rig.writeHeartbeat(SystemWallpaperHeartbeat(
            timestamp: Self.referenceNow.addingTimeInterval(-10),
            activeChoiceID: nil,
            runtimeHealthy: false,
            osVersion: "1.0.0"
        ))
        rig.service.refresh()
        #expect(rig.service.status == .publishedNotSelected)

        try rig.writeHeartbeat(SystemWallpaperHeartbeat(
            timestamp: Self.referenceNow.addingTimeInterval(-10),
            activeChoiceID: nil,
            runtimeHealthy: false,
            osVersion: SystemWallpaperHeartbeat.currentOSVersion()
        ))
        rig.service.refresh()
        #expect(rig.service.status == .systemIncompatible)
    }

    @Test("An unhealthy verdict from an older revision of the layout check is ignored")
    func statusIgnoresStaleRuntimeCheckVerdict() async throws {
        let rig = try makeRig()
        let bookmark = try rig.makeVideoBookmark()
        try await rig.service.publish(bookmark: bookmark)
        // Same OS build, but the verdict came from a check we have since
        // replaced — the fixed one never runs if this keeps the app locked out.
        try rig.writeHeartbeat(SystemWallpaperHeartbeat(
            timestamp: Self.referenceNow.addingTimeInterval(-10),
            activeChoiceID: nil,
            runtimeHealthy: false,
            osVersion: SystemWallpaperHeartbeat.currentOSVersion(),
            runtimeCheckVersion: SystemWallpaperHeartbeat.currentRuntimeCheckVersion - 1
        ))
        rig.service.refresh()
        #expect(rig.service.status == .publishedNotSelected)
    }

    @Test("A heartbeat written before the check stamp existed still decodes and still counts")
    func heartbeatWithoutRuntimeCheckVersionDecodes() throws {
        let json = """
        {"timestamp":0,"runtimeHealthy":false,"osVersion":"\(SystemWallpaperHeartbeat.currentOSVersion())"}
        """
        let heartbeat = try JSONDecoder().decode(
            SystemWallpaperHeartbeat.self, from: Data(json.utf8)
        )
        #expect(heartbeat.runtimeCheckVersion == nil)
        let stampedAsOne = SystemWallpaperHeartbeat(
            timestamp: heartbeat.timestamp,
            activeChoiceID: nil,
            runtimeHealthy: false,
            osVersion: SystemWallpaperHeartbeat.currentOSVersion(),
            runtimeCheckVersion: 1
        )
        #expect(heartbeat.barsPublishing == stampedAsOne.barsPublishing,
                "an unstamped heartbeat was written by revision 1 and must be read as one")
    }

    @Test("In-use covers every active choice, not just the first display's")
    func isItemInUseChecksAllActiveChoices() async throws {
        let rig = try makeRig()
        let bookmark = try rig.makeVideoBookmark()
        try await rig.service.publish(bookmark: bookmark)
        try rig.writeHeartbeat(SystemWallpaperHeartbeat(
            timestamp: Self.referenceNow.addingTimeInterval(-10),
            activeChoiceID: "other",
            activeChoiceIDs: ["other", bookmark.id.uuidString]
        ))
        rig.service.refresh()
        #expect(rig.service.isItemInUse(bookmark.id.uuidString),
                "the second display's choice must count as in use")
        #expect(!rig.service.isItemInUse("absent"))
    }

    @Test("No items reads as empty")
    func statusEmpty() throws {
        let rig = try makeRig()
        rig.service.refresh()
        #expect(rig.service.status == .empty)
    }

    @Test("Items with a missing, stale, or choiceless heartbeat read as published-not-selected")
    func statusPublishedNotSelected() async throws {
        let rig = try makeRig()
        let bookmark = try rig.makeVideoBookmark()
        try await rig.service.publish(bookmark: bookmark)

        // No heartbeat at all.
        #expect(rig.service.status == .publishedNotSelected)

        // Fresh heartbeat but no active choice.
        try rig.writeHeartbeat(SystemWallpaperHeartbeat(
            timestamp: Self.referenceNow.addingTimeInterval(-10),
            activeChoiceID: nil
        ))
        rig.service.refresh()
        #expect(rig.service.status == .publishedNotSelected)

        // Stale heartbeat, even with a matching choice.
        try rig.writeHeartbeat(SystemWallpaperHeartbeat(
            timestamp: Self.referenceNow.addingTimeInterval(
                -WallpaperExportService.heartbeatFreshnessInterval - 1
            ),
            activeChoiceID: bookmark.id.uuidString
        ))
        rig.service.refresh()
        #expect(rig.service.status == .publishedNotSelected)
        #expect(!rig.service.isItemInUse(bookmark.id.uuidString))
    }

    @Test("A fresh heartbeat matching an item reads as in-use with its title")
    func statusInUse() async throws {
        let rig = try makeRig()
        let bookmark = try rig.makeVideoBookmark(label: "Aurora")
        try await rig.service.publish(bookmark: bookmark)
        try rig.writeHeartbeat(SystemWallpaperHeartbeat(
            timestamp: Self.referenceNow.addingTimeInterval(-60),
            activeChoiceID: bookmark.id.uuidString
        ))
        rig.service.refresh()
        #expect(rig.service.status == .inUse(itemTitle: "Aurora"))
    }

    @Test("A failed operation surfaces as failed until dismissed")
    func statusFailedOverlay() async throws {
        let rig = try makeRig()
        let packaged = WallpaperBookmark(
            label: "Packed",
            content: .video(bookmarkData: Data("x".utf8), packageEntryName: "inner.mp4")
        )
        _ = try? await rig.service.publish(bookmark: packaged)
        guard case .failed = rig.service.status else {
            Issue.record("Expected .failed, got \(rig.service.status)")
            return
        }
        rig.service.clearLastError()
        #expect(rig.service.status == .empty)
    }

    // MARK: - Corruption tolerance

    /// Was "a corrupt manifest reads as empty and the next publish rewrites
    /// it". That behaviour is what silently orphaned every already-published
    /// video: the rewrite dropped their entries and the sweep deleted the
    /// files an hour later. Refusing is the only non-destructive answer.
    @Test("A corrupt manifest is refused, not treated as an empty library")
    func corruptManifestIsRefused() async throws {
        let rig = try makeRig()
        try FileManager.default.createDirectory(at: rig.root, withIntermediateDirectories: true)
        try Data("{not json]".utf8).write(to: rig.manifestURL)

        rig.service.refresh()
        #expect(rig.service.items.isEmpty)
        #expect(rig.service.lastError != nil, "a damaged index must not look like an empty library")

        let bookmark = try rig.makeVideoBookmark()
        await #expect(throws: WallpaperExportService.ServiceError.manifestUnreadable) {
            try await rig.service.publish(bookmark: bookmark)
        }
        #expect(
            (try? Data(contentsOf: rig.manifestURL)) == Data("{not json]".utf8),
            "the damaged file is left exactly as found so it can be recovered"
        )
    }

    @Test("Republishing the same bookmark replaces its item instead of duplicating it")
    func republishReplaces() async throws {
        let rig = try makeRig()
        let bookmark = try rig.makeVideoBookmark(label: "First")
        try await rig.service.publish(bookmark: bookmark)
        var renamed = bookmark
        renamed.label = "Second"
        try await rig.service.publish(bookmark: renamed)

        #expect(rig.service.items.count == 1)
        #expect(rig.service.items.first?.title == "Second")
    }

    /// The real AVFoundation path, not the injected stub every other test here
    /// uses: a staged copy is what the thumbnail is generated from, and
    /// AVFoundation types a file by its extension. When the staging name ended
    /// in `.partial` this failed with "Cannot Open" on every publish, and no
    /// contract test noticed because they all stub `makeThumbnailJPEG`.
    @Test("A staged copy is still a video AVFoundation can open")
    func stagedCopyKeepsAThumbnailableExtension() async throws {
        let staging = SystemWallpaperLibrary.stagingFileName(
            itemID: "thumbnailable", ext: "mp4", now: Self.referenceNow
        )
        #expect((staging as NSString).pathExtension == "mp4")
        #expect(SystemWallpaperLibrary.stagingCreation(fileName: staging) == Self.referenceNow)

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let video = directory.appendingPathComponent(staging)
        try Self.writeSingleFrameVideo(to: video)

        let jpeg = await WallpaperExportService.Dependencies.live().makeThumbnailJPEG(video)
        #expect(jpeg != nil)
    }

    /// Smallest real MP4 the thumbnail path can be pointed at: one frame,
    /// written by AVFoundation itself so the fixture cannot rot.
    private static func writeSingleFrameVideo(to url: URL) throws {
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: 160,
            AVVideoHeightKey: 90
        ])
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(
            assetWriterInput: input, sourcePixelBufferAttributes: nil
        )
        writer.add(input)
        writer.startWriting()
        writer.startSession(atSourceTime: .zero)

        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferCreate(kCFAllocatorDefault, 160, 90, kCVPixelFormatType_32ARGB, nil, &pixelBuffer)
        if let pixelBuffer {
            CVPixelBufferLockBaseAddress(pixelBuffer, [])
            memset(CVPixelBufferGetBaseAddress(pixelBuffer), 0x40, CVPixelBufferGetDataSize(pixelBuffer))
            CVPixelBufferUnlockBaseAddress(pixelBuffer, [])
            // Two seconds long: the generator samples at 0.5s.
            adaptor.append(pixelBuffer, withPresentationTime: .zero)
            adaptor.append(pixelBuffer, withPresentationTime: CMTime(seconds: 2, preferredTimescale: 600))
        }
        input.markAsFinished()
        let done = DispatchSemaphore(value: 0)
        writer.finishWriting { done.signal() }
        done.wait()
    }
}
