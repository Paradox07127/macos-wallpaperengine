#if !LITE_BUILD
import Foundation
import LiveWallpaperCore

/// Library-name translations kept across launches: one JSON object of target language → { original: translation }.
/// A few hundred short entries, so reads and writes run synchronously on the main actor.
@MainActor
final class WallpaperNameTranslationCache {
    private let fileURL: URL
    private lazy var entries: [String: [String: String]] = Self.read(fileURL)

    init(fileURL: URL = WallpaperNameTranslationCache.defaultFileURL()) {
        self.fileURL = fileURL
    }

    func translations(for language: Locale.Language) -> [String: String] {
        entries[language.maximalIdentifier] ?? [:]
    }

    func merge(_ pairs: [(String, String)], for language: Locale.Language) {
        let key = language.maximalIdentifier
        let current = entries[key] ?? [:]
        let merged = current.merging(pairs) { _, new in new }
        guard merged != current else { return }
        entries[key] = merged
        write()
    }

    /// Drops originals outside `originals` from every language.
    func retain(_ originals: Set<String>) {
        let pruned = entries
            .mapValues { $0.filter { originals.contains($0.key) } }
            .filter { !$0.value.isEmpty }
        guard pruned != entries else { return }
        entries = pruned
        write()
    }

    private static func read(_ url: URL) -> [String: [String: String]] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: [String: String]].self, from: data)) ?? [:]
    }

    private func write() {
        do {
            try FileManager.default.createDirectory(
                at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try JSONEncoder().encode(entries).write(to: fileURL, options: .atomic)
        } catch {
            Logger.warning("Wallpaper name translation cache write failed: \(error.localizedDescription)", category: .ui)
        }
    }

    /// Caches, not Application Support: every entry can be translated again. Test processes, hosted in
    /// the real app, get the per-process scratch root instead of the user's container.
    nonisolated static func defaultFileURL() -> URL {
        let fileManager = FileManager.default
        let directory: URL
        if NSClassFromString("XCTestCase") != nil {
            directory = fileManager.temporaryDirectory
                .appendingPathComponent(TestProcessScratch.name(TestProcessScratch.configurationPrefix), isDirectory: true)
        } else {
            let caches = (try? fileManager.url(
                for: .cachesDirectory, in: .userDomainMask, appropriateFor: nil, create: true
            )) ?? URL(fileURLWithPath: NSHomeDirectory())
                .appendingPathComponent("Library/Caches", isDirectory: true)
            directory = caches
                .appendingPathComponent(Bundle.main.bundleIdentifier ?? "com.loomscreen.pro", isDirectory: true)
                .appendingPathComponent("Translations", isDirectory: true)
        }
        return directory.appendingPathComponent("wallpaper-names.json", isDirectory: false)
    }
}
#endif
