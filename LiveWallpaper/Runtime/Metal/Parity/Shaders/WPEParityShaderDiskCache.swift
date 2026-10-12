#if !LITE_BUILD
import Foundation
import LiveWallpaperProWPE

actor WPEParityShaderDiskCache {
    private static let stageInName = "vertex-stage-in.metallib"
    private let rootURL: URL
    private let sizeBudget: Int

    init(cachesURL: URL = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0],
         sizeBudget: Int = 64 * 1024 * 1024) {
        rootURL = cachesURL.appendingPathComponent("wpe-parity-shaders/v1", isDirectory: true)
        self.sizeBudget = max(0, sizeBudget)
    }

    func read(_ key: WPEParityShaderKey) -> WPEParityCompiledStages? {
        let directory = entryURL(key)
        do {
            let manifest = try JSONDecoder().decode(WPEParityShaderCacheManifest.self,
                                                    from: Data(contentsOf: directory.appendingPathComponent("manifest.json")))
            let stages = Set(manifest.stages)
            var names = Set(stages.flatMap { ["\($0.rawValue).metallib", "\($0.rawValue).json"] })
            if stages.contains(.geometry) {
                names.insert(Self.stageInName)
            }
            guard manifest.key == key.rawValue, !stages.isEmpty,
                  stages.count == manifest.stages.count, Set(manifest.files.keys) == names else {
                remove(key)
                return nil
            }
            var files: [String: Data] = [:]
            for name in names {
                let data = try Data(contentsOf: directory.appendingPathComponent(name))
                guard manifest.files[name] == WPEParityShaderCacheManifest.FileRecord(data: data) else {
                    remove(key)
                    return nil
                }
                files[name] = data
            }
            var compiled: [WPEParityShaderKey.Stage: WPEParityCompiledStages.Stage] = [:]
            for stage in stages {
                guard let metallib = files["\(stage.rawValue).metallib"],
                      let reflection = files["\(stage.rawValue).json"] else { return nil }
                compiled[stage] = .init(metallib: metallib, reflectionJSON: reflection,
                                        stageIn: stage == .vertex ? files[Self.stageInName] : nil)
            }
            // Directory mtime records last access; creation time lives in the manifest.
            try? FileManager.default.setAttributes([.modificationDate: Date()], ofItemAtPath: directory.path)
            return WPEParityCompiledStages(stages: compiled)
        } catch {
            remove(key)
            return nil
        }
    }

    func write(_ compiled: WPEParityCompiledStages, for key: WPEParityShaderKey) {
        guard sizeBudget > 0 else { return }
        let fileManager = FileManager.default
        let temporary = rootURL.appendingPathComponent(".\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: temporary) }
        do {
            try fileManager.createDirectory(at: temporary, withIntermediateDirectories: true)
            var files: [String: WPEParityShaderCacheManifest.FileRecord] = [:]
            let stages = WPEParityShaderKey.Stage.allCases.filter { compiled.stages[$0] != nil }
            for stage in stages {
                guard let bytes = compiled.stages[stage] else { continue }
                var outputs = [("\(stage.rawValue).metallib", bytes.metallib), ("\(stage.rawValue).json", bytes.reflectionJSON)]
                if let stageIn = bytes.stageIn {
                    outputs.append((Self.stageInName, stageIn))
                }
                for (name, data) in outputs {
                    try data.write(to: temporary.appendingPathComponent(name))
                    files[name] = .init(data: data)
                }
            }
            let manifest = WPEParityShaderCacheManifest(key: key, stages: stages, files: files)
            try JSONEncoder().encode(manifest).write(to: temporary.appendingPathComponent("manifest.json"))
            if read(key) == nil {
                try fileManager.moveItem(at: temporary, to: entryURL(key))
            }
            evict()
        } catch {
            // Persistence is optional; a successful compile remains usable.
        }
    }

    func remove(_ key: WPEParityShaderKey) {
        try? FileManager.default.removeItem(at: entryURL(key))
    }

    private func entryURL(_ key: WPEParityShaderKey) -> URL {
        rootURL.appendingPathComponent(key.rawValue, isDirectory: true)
    }

    private func evict() {
        let fileManager = FileManager.default
        guard let directories = try? fileManager.contentsOfDirectory(
            at: rootURL, includingPropertiesForKeys: [.isDirectoryKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        var entries: [(url: URL, accessedAt: Date, bytes: Int)] = []
        for directory in directories {
            guard let values = try? directory.resourceValues(forKeys: [.isDirectoryKey, .contentModificationDateKey]),
                  values.isDirectory == true,
                  let files = try? fileManager.contentsOfDirectory(at: directory, includingPropertiesForKeys: [.fileSizeKey]) else { continue }
            let bytes = files.reduce(0) { $0 + ((try? $1.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0) }
            entries.append((directory, values.contentModificationDate ?? .distantPast, bytes))
        }
        var total = entries.reduce(0) { $0 + $1.bytes }
        for entry in entries.sorted(by: { $0.accessedAt < $1.accessedAt }) where total > sizeBudget {
            do {
                try fileManager.removeItem(at: entry.url)
                total -= entry.bytes
            } catch {
                continue
            }
        }
    }
}
#endif
