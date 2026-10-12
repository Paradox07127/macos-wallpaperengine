/// Byte classes of Python 3 `str` predicates and `re` classes on latin-1 decoded text: the reference
/// rewriter that the captures were reproduced with reads shaders as latin-1, so non-ASCII bytes follow these.
enum Latin1 {
    static let nul: UInt8 = 0x00
    static let tab: UInt8 = 0x09
    static let lf: UInt8 = 0x0A
    static let cr: UInt8 = 0x0D
    static let space: UInt8 = 0x20
    static let quote: UInt8 = 0x22
    static let hash: UInt8 = 0x23
    static let slash: UInt8 = 0x2F
    static let star: UInt8 = 0x2A
    static let underscore: UInt8 = 0x5F

    /// `str.isspace` and `re` `\s`.
    static func isSpace(_ b: UInt8) -> Bool {
        (0x09 ... 0x0D).contains(b) || (0x1C ... 0x20).contains(b) || b == 0x85 || b == 0xA0
    }

    static func isAlpha(_ b: UInt8) -> Bool {
        (0x41 ... 0x5A).contains(b) || (0x61 ... 0x7A).contains(b) || b == 0xAA || b == 0xB5 || b == 0xBA
            || (0xC0 ... 0xD6).contains(b) || (0xD8 ... 0xF6).contains(b) || b >= 0xF8
    }

    /// `re` `\d`.
    static func isASCIIDigit(_ b: UInt8) -> Bool {
        (0x30 ... 0x39).contains(b)
    }

    /// `str.isdigit`, which also accepts the superscripts ¹ ² ³.
    static func isDigit(_ b: UInt8) -> Bool {
        isASCIIDigit(b) || b == 0xB2 || b == 0xB3 || b == 0xB9
    }

    static func isAlnum(_ b: UInt8) -> Bool {
        isAlpha(b) || isDigit(b) || (0xBC ... 0xBE).contains(b)
    }

    /// `re` `\w`.
    static func isWord(_ b: UInt8) -> Bool {
        isAlnum(b) || b == underscore
    }

    /// The ASCII-only identifier class the rewriter itself uses for its replacements.
    static func isIdent(_ b: UInt8) -> Bool {
        (0x41 ... 0x5A).contains(b) || (0x61 ... 0x7A).contains(b) || isASCIIDigit(b) || b == underscore
    }

    static func string(_ bytes: some Sequence<UInt8>) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.append(contentsOf: bytes.map { Unicode.Scalar($0) })
        return String(scalars)
    }

    static func bytes(_ s: String) -> [UInt8] {
        Array(s.utf8)
    }

    /// `re` `\b` at `index`.
    static func isWordBoundary(_ text: [UInt8], _ index: Int) -> Bool {
        let before = index > 0 && index <= text.count && isWord(text[index - 1])
        let after = index < text.count && isWord(text[index])
        return before != after
    }

    /// First index of `\b` + `word` + `\b` in `text`.
    static func firstWholeWord(_ word: [UInt8], in text: [UInt8]) -> Int? {
        guard word.count <= text.count else { return nil }
        for p in 0 ... (text.count - word.count)
            where text[p ..< p + word.count].elementsEqual(word)
            && isWordBoundary(text, p) && isWordBoundary(text, p + word.count) {
            return p
        }
        return nil
    }

    /// Python `int(s)` for the decimal forms a define value can take; nil where Python raises.
    static func pythonInt(_ s: [UInt8]) -> Int? {
        var lo = 0
        var hi = s.count
        while lo < hi, isSpace(s[lo]) {
            lo += 1
        }
        while hi > lo, isSpace(s[hi - 1]) {
            hi -= 1
        }
        var negative = false
        if lo < hi, s[lo] == 0x2B || s[lo] == 0x2D {
            negative = s[lo] == 0x2D
            lo += 1
        }
        guard lo < hi, s[lo ..< hi].allSatisfy(isASCIIDigit) else { return nil }
        let value = s[lo ..< hi].reduce(0) { $0 &* 10 &+ Int($1 - 0x30) }
        return negative ? 0 &- value : value
    }
}

extension [UInt8] {
    func firstIndex(ofBytes needle: [UInt8], from start: Int = 0) -> Int? {
        guard needle.count <= count, start <= count - needle.count else { return nil }
        for p in start ... (count - needle.count) where self[p ..< p + needle.count].elementsEqual(needle) {
            return p
        }
        return nil
    }

    func contains(bytes needle: [UInt8]) -> Bool {
        firstIndex(ofBytes: needle) != nil
    }
}
