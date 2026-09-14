import Foundation
import Testing
@testable import LiveWallpaper

@Suite("Steam library binding containment")
struct SteamLibraryBindingContainmentTests {

    private static func doctorSource() throws -> String {
        try String(
            contentsOf: RepositoryRoot.url(
                "LiveWallpaper/Infrastructure/Workshop/Doctor/SteamCMDDoctorService.swift"
            ),
            encoding: .utf8
        )
    }

    @Test("A container path is not a Steam profile, however complete it looks")
    func containerIsRecognisedAsInternal() {
        let container = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
        #expect(WPEEngineAssetsLibrary.isContainerInternal(container))

        // The real profile lives under the POSIX home, which the sandbox never
        // rewrites — that is exactly what makes the two distinguishable.
        let shared = AppleAerialsLibrary.realHomeDirectory()
            .appendingPathComponent("Library/Application Support/Steam", isDirectory: true)
        #expect(!WPEEngineAssetsLibrary.isContainerInternal(shared))
    }

    @Test("Binding refuses a container path instead of accepting it as shared")
    func bindingRejectsContainerPaths() throws {
        let source = try Self.doctorSource()
        let bind = try #require(
            source.range(of: "func bindSteamLibrary(")
                .map { String(source[$0.lowerBound...].prefix(1400)) },
            "bindSteamLibrary moved"
        )
        #expect(bind.contains("isContainerInternal"))
        #expect(bind.contains("steamLibraryInsideContainer"))
    }

    @Test("Revalidation releases a container binding stored before the fix")
    func revalidationForgetsContainerBindings() throws {
        let source = try Self.doctorSource()
        let revalidate = try #require(
            source.range(of: "private func autoConfigureWorkdirIfNeeded()")
                .map { String(source[$0.lowerBound...].prefix(1800)) },
            "autoConfigureWorkdirIfNeeded moved"
        )
        #expect(revalidate.contains("isContainerInternal"))
        #expect(revalidate.contains("forgetWorkdirBinding"))
    }

    @Test("Forgetting a binding deletes no files")
    func forgettingNeverDeletes() throws {
        let source = try Self.doctorSource()
        let forget = try #require(
            source.range(of: "private func forgetWorkdirBinding(")
                .map { String(source[$0.lowerBound...].prefix(600)) },
            "forgetWorkdirBinding moved"
        )
        #expect(!forget.contains("removeItem"))
        #expect(!forget.contains("trashItem"))
    }
}
