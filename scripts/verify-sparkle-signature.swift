#!/usr/bin/env swift
import CryptoKit
import Foundation

enum VerificationError: Error, CustomStringConvertible {
    case invalid(String)
    var description: String {
        switch self {
        case let .invalid(message): message
        }
    }
}

func verify(archive: Data, publicKey: Data, signature: Data, length: Int) throws {
    guard archive.count == length else { throw VerificationError.invalid("archive length differs from signed enclosure") }
    let key = try Curve25519.Signing.PublicKey(rawRepresentation: publicKey)
    guard key.isValidSignature(signature, for: archive) else {
        throw VerificationError.invalid("Ed25519 signature does not match this archive and the app's SUPublicEDKey")
    }
}

func selfTest() throws {
    func hex(_ value: String) -> Data {
        let bytes = Array(value.utf8)
        return Data(stride(from: 0, to: bytes.count, by: 2).map {
            UInt8(String(bytes: bytes[$0 ..< $0 + 2], encoding: .utf8)!, radix: 16)!
        })
    }
    // RFC 8032 section 7.1, TEST 2: independently specified public key/message/signature.
    let key = hex("3d4017c3e843895a92b70aa74d1b7ebc9c982ccf2ec4968cc0cd55f12af4660c")
    let signature = hex("92a009a9f0d4cab8720e820b5f642540a2b27b5416503f8fb3762223ebdb69da085ac1e43e15996e458f3613d0f11d8c387b2eaeb4302aeeb00d291612bb0c00")
    let archive = Data([0x72])
    try verify(archive: archive, publicKey: key, signature: signature, length: 1)
    let invalid: [(Data, Data, Data, Int)] = [
        (Data([0x73]), key, signature, 1),
        (archive, Data(repeating: 0, count: 32), signature, 1),
        (archive, key, Data(signature.dropLast()), 1),
        (archive, key, signature, 2),
    ]
    for (file, candidateKey, candidateSignature, length) in invalid {
        var rejected = false
        do {
            try verify(archive: file, publicKey: candidateKey, signature: candidateSignature, length: length)
        } catch {
            rejected = true
        }
        guard rejected else { throw VerificationError.invalid("negative signature control was accepted") }
    }
    print("Sparkle public verification: RFC 8032 positive and 4 negative controls passed")
}

do {
    let args = Array(CommandLine.arguments.dropFirst())
    if args == ["--self-test"] {
        try selfTest()
    } else {
        guard args.count == 3 else {
            throw VerificationError.invalid("usage: verify-sparkle-signature.swift <archive> <app Info.plist> <sign_update output>")
        }
        let plistData = try Data(contentsOf: URL(fileURLWithPath: args[1]))
        guard let plist = try PropertyListSerialization.propertyList(from: plistData, format: nil) as? [String: Any],
              let encodedKey = plist["SUPublicEDKey"] as? String,
              let key = Data(base64Encoded: encodedKey), key.count == 32 else {
            throw VerificationError.invalid("app Info.plist has no valid fixed SUPublicEDKey")
        }
        let output = try String(contentsOfFile: args[2], encoding: .utf8)
        let pattern = #"^\s*sparkle:edSignature="([A-Za-z0-9+/]+={0,2})"\s+length="([0-9]+)"\s*$"#
        let regex = try NSRegularExpression(pattern: pattern)
        guard let match = regex.firstMatch(in: output, range: NSRange(output.startIndex..., in: output)),
              let signatureRange = Range(match.range(at: 1), in: output),
              let lengthRange = Range(match.range(at: 2), in: output),
              let signature = Data(base64Encoded: String(output[signatureRange])), signature.count == 64,
              let length = Int(output[lengthRange]) else {
            throw VerificationError.invalid("sign_update output is not one signed enclosure with a valid length")
        }
        let archive = try Data(contentsOf: URL(fileURLWithPath: args[0]), options: .mappedIfSafe)
        try verify(archive: archive, publicKey: key, signature: signature, length: length)
        let digest = SHA256.hash(data: archive).map { String(format: "%02x", $0) }.joined()
        print("Verified Sparkle Ed25519 against app SUPublicEDKey: bytes=\(archive.count) sha256=\(digest)")
    }
} catch {
    FileHandle.standardError.write(Data("ERROR: Sparkle public verification failed: \(error)\n".utf8))
    exit(1)
}
