import Foundation

/// NSXPC drops a message whose block signature differs from the peer's, so each selector's
/// extended encoding must match the system protocol once class names and offsets are removed.
enum XPCContractChecks {
    private static let frameworkPath =
        "/System/Library/PrivateFrameworks/WallpaperExtensionKit.framework/WallpaperExtensionKit"

    static func run() -> [String] {
        var failures = replyShapeFailures()
        guard dlopen(frameworkPath, RTLD_LAZY) != nil else {
            let reason = dlerror().map { String(cString: $0) } ?? "unknown"
            return failures + ["cannot load WallpaperExtensionKit: \(reason)"]
        }
        let exportedName = "WallpaperExtensionKit.WallpaperExtensionXPCProtocol"
        let proxyName = "WallpaperExtensionKit.WallpaperExtensionProxyXPCProtocol"
        guard let exported = objc_getProtocol(exportedName) else { return failures + ["system protocol \(exportedName) not found"] }
        guard let proxy = objc_getProtocol(proxyName) else { return failures + ["system protocol \(proxyName) not found"] }
        let downloadedSelector = NSSelectorFromString("isChoiceDownloadedWith:reply:")
        let downloaded = WallpaperXPCBridge.extendedTypeEncoding(of: downloadedSelector, in: exported)
        let ours = WallpaperXPCBridge.choiceDownloadedReply(forSystemEncoding: downloaded).exportedProtocol
        failures += compare(apple: methods(of: exported), ours: methods(of: ours), label: exportedName)
        failures += compare(apple: methods(of: proxy), ours: methods(of: WallpaperExtensionProxyXPCProtocol.self), label: proxyName)
        return failures
    }

    private static func replyShapeFailures() -> [String] {
        let cases: [(String?, ChoiceDownloadedReply)] = [
            ("v32@0:8@\"WallpaperChoiceIDXPC\"16@?<v@?B@\"NSError\">24", .bool),
            ("v32@0:8@\"WallpaperChoiceIDXPC\"16@?<v@?@\"NSNumber\"@\"NSError\">24", .number),
            (nil, .number),
        ]
        return cases.compactMap { encoding, expected in
            let chosen = WallpaperXPCBridge.choiceDownloadedReply(forSystemEncoding: encoding)
            return chosen == expected ? nil : "encoding \(encoding ?? "nil") chose \(chosen), expected \(expected)"
        }
    }

    private static func compare(apple: [String: String]?, ours: [String: String]?, label: String) -> [String] {
        guard let apple, let ours else { return ["\(label): extended encodings unavailable"] }
        var failures: [String] = []
        for selector in Set(apple.keys).subtracting(ours.keys).sorted() {
            failures.append("\(label): \(selector) missing on our side")
        }
        for selector in Set(ours.keys).subtracting(apple.keys).sorted() {
            failures.append("\(label): \(selector) not in the system protocol")
        }
        for selector in Set(apple.keys).intersection(ours.keys).sorted() {
            let system = normalized(apple[selector] ?? ""), local = normalized(ours[selector] ?? "")
            if system != local {
                failures.append("\(label): \(selector) system \(system) vs ours \(local)")
            }
        }
        return failures
    }

    /// Selector to extended encoding over the protocol and everything it incorporates except NSObject; nil when an encoding is missing.
    private static func methods(of proto: Protocol) -> [String: String]? {
        var result: [String: String] = [:]
        var pending = [proto]
        var visited = Set<String>()
        while let current = pending.popLast() {
            let name = String(cString: protocol_getName(current))
            guard name != "NSObject", visited.insert(name).inserted else { continue }
            for required in [true, false] {
                var count: UInt32 = 0
                guard let list = protocol_copyMethodDescriptionList(current, required, true, &count) else { continue }
                defer { free(list) }
                for description in UnsafeBufferPointer(start: list, count: Int(count)) {
                    guard let selector = description.name else { continue }
                    guard let types = WallpaperXPCBridge.extendedTypeEncoding(of: selector, in: current) else { return nil }
                    result[NSStringFromSelector(selector)] = types
                }
            }
            var incorporatedCount: UInt32 = 0
            if let incorporated = protocol_copyProtocolList(current, &incorporatedCount) {
                pending += (0 ..< Int(incorporatedCount)).map { incorporated[$0] }
            }
        }
        return result
    }

    private static func normalized(_ encoding: String) -> String {
        encoding.replacingOccurrences(of: "\"[^\"]*\"", with: "", options: .regularExpression)
            .filter { !$0.isNumber }
    }
}
