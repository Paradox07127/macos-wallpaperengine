import CryptoKit
import Foundation

/// Hash bytes and relative names so an identical republish cannot reset the failure circuit.
enum WallpaperSceneCapsule {
    static func fingerprint(at root: URL) throws -> String {
        var enumerationError: (any Error)?
        guard let enumerator = FileManager.default.enumerator(
            at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
            errorHandler: { _, error in enumerationError = error; return false }
        ) else { throw CocoaError(.fileReadUnknown) }
        var files: [URL] = []
        for case let url as URL in enumerator {
            try Task.checkCancellation()
            let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
            if values.isRegularFile == true || values.isSymbolicLink == true {
                files.append(url)
            }
        }
        if let enumerationError {
            throw enumerationError
        }
        var digest = SHA256()
        for url in files.sorted(by: { $0.path < $1.path }) {
            try Task.checkCancellation()
            let name = String(url.path.dropFirst(root.path.count))
            digest.update(data: Data(name.utf8))
            digest.update(data: Data([0]))
            if try url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink == true {
                digest.update(data: Data([1]))
                let target = try FileManager.default.destinationOfSymbolicLink(atPath: url.path)
                digest.update(data: Data(SHA256.hash(data: Data(target.utf8))))
                continue
            }
            digest.update(data: Data([0]))
            let file = try FileHandle(forReadingFrom: url)
            defer { try? file.close() }
            var fileDigest = SHA256()
            while let bytes = try file.read(upToCount: 1024 * 1024), !bytes.isEmpty {
                try Task.checkCancellation()
                fileDigest.update(data: bytes)
            }
            digest.update(data: Data(fileDigest.finalize()))
        }
        return digest.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
