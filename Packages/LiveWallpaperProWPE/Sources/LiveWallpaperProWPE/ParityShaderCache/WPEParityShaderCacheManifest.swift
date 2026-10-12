import CryptoKit
import Foundation

public struct WPEParityShaderCacheManifest: Codable, Sendable, Equatable {
    public struct FileRecord: Codable, Sendable, Equatable {
        public let byteCount: Int
        public let sha256: String

        public init(data: Data) {
            byteCount = data.count
            sha256 = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
        }
    }

    public let key: String
    public let stages: [WPEParityShaderKey.Stage]
    public let files: [String: FileRecord]
    public let createdAt: Date

    public init(key: WPEParityShaderKey, stages: [WPEParityShaderKey.Stage],
                files: [String: FileRecord], createdAt: Date = Date()) {
        self.key = key.rawValue
        self.stages = stages
        self.files = files
        self.createdAt = createdAt
    }
}
