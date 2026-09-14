#if !LITE_BUILD
import Foundation

enum WorkshopURLParser {

    enum ParsedItem: Equatable, Sendable {
        case ok(publishedFileID: UInt64, original: String)
        case invalid(reason: InvalidReason, original: String)
    }

    enum InvalidReason: String, Equatable, Sendable {
        case empty
        case unsupportedURL
        case missingID
        case malformedID
        case overflowID
        case unknownHost
    }

    /// Order-preserving and duplicate-tolerant; callers handle dedupe.
    static func tokenize(_ blob: String) -> [String] {
        let separators = CharacterSet(charactersIn: ",;\n\r\t ")
        return blob
            .components(separatedBy: separators)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    static func parse(_ raw: String) -> ParsedItem {
        let token = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !token.isEmpty else {
            return .invalid(reason: .empty, original: raw)
        }

        if token.allSatisfy({ $0.isASCII && $0.isNumber }) {
            return parseNumericID(token, original: raw)
        }

        if token.lowercased().hasPrefix("steam://") {
            return parseSteamURL(token, original: raw)
        }

        if let scheme = URL(string: token)?.scheme?.lowercased(),
           scheme == "http" || scheme == "https" {
            return parseHTTPSURL(token, original: raw)
        }

        return .invalid(reason: .unsupportedURL, original: raw)
    }

    /// Bulk-parse + dedupe in input order; duplicate `publishedFileID`s collapse to the first occurrence.
    static func parseAll(_ blob: String) -> [ParsedItem] {
        var seen: Set<UInt64> = []
        var results: [ParsedItem] = []
        for token in tokenize(blob) {
            let parsed = parse(token)
            switch parsed {
            case .ok(let id, _):
                if seen.insert(id).inserted {
                    results.append(parsed)
                }
            case .invalid:
                results.append(parsed)
            }
        }
        return results
    }

    // MARK: - Private

    private static func parseNumericID(_ token: String, original: String) -> ParsedItem {
        guard token.count <= 20,
              !(token.count > 1 && token.first == "0"),
              token != "0" else {
            return .invalid(reason: .malformedID, original: original)
        }
        guard let id = UInt64(token) else {
            return .invalid(reason: .overflowID, original: original)
        }
        return .ok(publishedFileID: id, original: original)
    }

    private static func parseSteamURL(_ token: String, original: String) -> ParsedItem {
        // `steam://url/CommunityFilePage/<id>` — entire tail must be digits.
        let prefix = "steam://url/CommunityFilePage/"
        guard token.lowercased().hasPrefix(prefix.lowercased()) else {
            return .invalid(reason: .unsupportedURL, original: original)
        }
        let tail = String(token.dropFirst(prefix.count))
        // Reject trailing junk like `…/123abc` — a prefix-match would silently accept a partial paste.
        guard tail.allSatisfy({ $0.isASCII && $0.isNumber }) else {
            return .invalid(reason: .malformedID, original: original)
        }
        return parseNumericID(tail, original: original)
    }

    private static func parseHTTPSURL(_ token: String, original: String) -> ParsedItem {
        guard let components = URLComponents(string: token) else {
            return .invalid(reason: .unsupportedURL, original: original)
        }
        // Reject embedded credentials and non-standard ports — the canonical Steam community URL never carries either.
        guard components.user == nil, components.password == nil else {
            return .invalid(reason: .unsupportedURL, original: original)
        }
        if let port = components.port, port != 443 {
            return .invalid(reason: .unsupportedURL, original: original)
        }
        guard let host = components.host?.lowercased(), host == "steamcommunity.com" else {
            return .invalid(reason: .unknownHost, original: original)
        }

        // Path forms with or without trailing slash: `sharedfiles/filedetails` and `workshop/filedetails`.
        let normalizedPath = components.path
            .trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .lowercased()
        let acceptedPaths: Set<String> = [
            "sharedfiles/filedetails",
            "workshop/filedetails"
        ]
        guard acceptedPaths.contains(normalizedPath) else {
            return .invalid(reason: .unsupportedURL, original: original)
        }

        guard let idValue = components.queryItems?.first(where: { $0.name.lowercased() == "id" })?.value,
              !idValue.isEmpty else {
            return .invalid(reason: .missingID, original: original)
        }
        return parseNumericID(idValue, original: original)
    }
}
#endif
