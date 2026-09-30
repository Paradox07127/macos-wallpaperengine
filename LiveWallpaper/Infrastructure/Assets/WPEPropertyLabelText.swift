import Foundation

enum WPEPropertyLabelText {
    private static let namedEntities = [
        "nbsp": " ", "amp": "&", "lt": "<", "gt": ">", "quot": "\"", "apos": "'",
        "ndash": "–", "mdash": "—", "hellip": "…", "bull": "•", "copy": "©", "reg": "®",
    ]
    private static let entityPattern = try? NSRegularExpression(pattern: #"&(#(?:[xX][0-9a-fA-F]+|[0-9]+)|[a-zA-Z]+);"#)

    static func clean(_ raw: String) -> String {
        let stripped = raw
            .replacingOccurrences(of: #"<br\s*/?>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"</?(h[1-6]|p|big|small|b|center|hr)[^>]*>"#, with: " ", options: .regularExpression)
            .replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        return decodeEntities(stripped)
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func decodeEntities(_ text: String) -> String {
        guard let entityPattern else { return text }
        var decoded = text
        // Match the original input once so encoded ampersands cannot trigger recursive decoding.
        for match in entityPattern.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let tokenRange = Range(match.range(at: 1), in: text),
                  let entityRange = Range(match.range, in: decoded) else { continue }
            let token = text[tokenRange]
            let replacement: String?
            if token.hasPrefix("#") {
                let digits = token.dropFirst()
                let isHex = digits.hasPrefix("x") || digits.hasPrefix("X")
                let number = UInt32(isHex ? digits.dropFirst() : digits, radix: isHex ? 16 : 10)
                replacement = number.flatMap { $0 == 0 ? nil : Unicode.Scalar($0) }.map(String.init)
            } else {
                replacement = namedEntities[String(token)]
            }
            if let replacement {
                decoded.replaceSubrange(entityRange, with: replacement)
            }
        }
        return decoded
    }
}
