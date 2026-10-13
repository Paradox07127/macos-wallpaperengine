import CryptoKit
import Foundation

public struct WPEParityShaderCompileOptions: Sendable, Hashable {
    public let hlslVersion: String
    public let minimumMacOS: String
    public let boundsCheck: Bool

    /// Direct3D Load guarantees zero outside the resource; MSC must preserve that contract on Metal.
    public init(hlslVersion: String = "2016", minimumMacOS: String = "14.6.0", boundsCheck: Bool = true) {
        self.hlslVersion = hlslVersion
        self.minimumMacOS = minimumMacOS
        self.boundsCheck = boundsCheck
    }
}

public struct WPEParityShaderKey: Sendable, Hashable {
    public enum Stage: String, Codable, Sendable, CaseIterable {
        case vertex, fragment, geometry
    }

    public let rawValue: String

    public init(program: WPEHLSLProgram, compilerIdentity: String,
                options: WPEParityShaderCompileOptions, bindingABIVersion: Int,
                keyFormatVersion: Int = 1) {
        var encoded = Data()
        func append(_ bytes: Data) {
            var length = UInt64(bytes.count).bigEndian
            withUnsafeBytes(of: &length) { encoded.append(contentsOf: $0) }
            encoded.append(bytes)
        }
        func appendText(_ text: String) {
            append(Data(text.utf8))
        }
        appendText(String(keyFormatVersion))
        let stages: [(Stage, [UInt8]?)] = [
            (.vertex, program.vertex), (.fragment, program.fragment), (.geometry, program.geometry),
        ]
        appendText(String(stages.filter { $0.1 != nil }.count))
        for (stage, bytes) in stages {
            guard let bytes else { continue }
            appendText(stage.rawValue)
            append(Data(bytes))
        }
        appendText(compilerIdentity)
        appendText(options.hlslVersion)
        appendText(options.minimumMacOS)
        appendText(options.boundsCheck ? "1" : "0")
        appendText(String(bindingABIVersion))
        rawValue = SHA256.hash(data: encoded).map { String(format: "%02x", $0) }.joined()
    }
}
