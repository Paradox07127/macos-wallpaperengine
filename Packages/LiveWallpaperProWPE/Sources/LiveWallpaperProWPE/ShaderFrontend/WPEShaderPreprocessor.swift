typealias WPEShaderMacros = [[UInt8]: [UInt8]]

/// In-place preprocessor of FUN_14016b0e0. Conditional directives and inactive lines are overwritten with
/// spaces from the first non-blank character, so the line structure survives; active `#define`, `#undef`
/// and unknown directives stay in the text without being expanded.
enum WPEShaderPreprocessor {
    private struct ConditionalFrame {
        var active: Bool
        var taken: Bool
    }

    static func run(_ text: [UInt8]) throws -> [UInt8] {
        var buf = text
        var n = buf.count
        if n == 0 {
            return text
        }
        var defines: WPEShaderMacros = [Latin1.bytes("SHADERVERSION"): Latin1.bytes("69")]
        var stack: [ConditionalFrame] = []
        var active = true
        var inBlock = false
        var pos = 0
        while true {
            var end = pos
            while end < n, buf[end] != Latin1.cr, buf[end] != Latin1.lf, buf[end] != Latin1.nul {
                end += 1
            }
            inBlock = blankBlockComments(&buf, from: pos, to: end, inBlock: inBlock)
            var first = pos
            while first < n, buf[first] == Latin1.space || buf[first] == Latin1.tab {
                first += 1
            }
            var blank = false
            if first < end, buf[first] == Latin1.hash, let parsed = directive(buf, first, end) {
                let name = parsed.name
                let rest = trimmedArgument(parsed.rest)
                switch name {
                case "define":
                    if active {
                        define(rest, into: &defines)
                    } else {
                        blank = true
                    }
                case "ifdef", "ifndef", "if":
                    let cond: Bool = if name == "if" {
                        active && WPEShaderExpression.evaluate(rest, defines: defines) != 0
                    } else {
                        active && ((defines[rest] != nil) == (name == "ifdef"))
                    }
                    stack.append(ConditionalFrame(active: cond, taken: cond))
                    active = stack.allSatisfy(\.active)
                    blank = true
                case "elif":
                    if let top = stack.last {
                        let outer = stack.dropLast().allSatisfy(\.active)
                        if outer, !top.taken, WPEShaderExpression.evaluate(rest, defines: defines) != 0 {
                            stack[stack.count - 1] = ConditionalFrame(active: true, taken: true)
                        } else {
                            stack[stack.count - 1].active = false
                        }
                        active = stack.allSatisfy(\.active)
                    }
                    blank = true
                case "else":
                    if let top = stack.last {
                        let outer = stack.dropLast().allSatisfy(\.active)
                        stack[stack.count - 1].active = outer && !top.taken
                        active = stack.allSatisfy(\.active)
                    }
                    blank = true
                case "endif":
                    if !stack.isEmpty {
                        stack.removeLast()
                    }
                    active = stack.allSatisfy(\.active)
                    blank = true
                case "require":
                    // Expanded even inside an inactive region, as the engine does; the directive itself is blanked.
                    let generated = try WPELightingV1Generator.generate(argument: rest, defines: defines)
                    if !generated.isEmpty {
                        buf.insert(contentsOf: generated, at: first)
                        n += generated.count
                        first += generated.count
                        end += generated.count
                    }
                    blank = true
                case "undef":
                    if active {
                        defines[rest] = nil
                    } else {
                        blank = true
                    }
                default:
                    break
                }
            }
            if !active || blank {
                for q in first ..< max(first, end) {
                    buf[q] = Latin1.space
                }
            }
            var p = end
            while p < n, buf[p] == Latin1.cr || buf[p] == Latin1.lf {
                p += 1
            }
            if p >= n || buf[p] == Latin1.nul {
                break
            }
            pos = p
        }
        return buf
    }

    /// Blanks `/* */` comments on one line, carrying the open-comment state; stops at `//`.
    private static func blankBlockComments(_ buf: inout [UInt8], from pos: Int, to end: Int, inBlock: Bool) -> Bool {
        var inBlock = inBlock
        var k = pos
        while k < end {
            if inBlock {
                if buf[k] == Latin1.star, k + 1 < end, buf[k + 1] == Latin1.slash {
                    buf[k] = Latin1.space
                    buf[k + 1] = Latin1.space
                    inBlock = false
                    k += 2
                } else {
                    buf[k] = Latin1.space
                    k += 1
                }
            } else {
                if buf[k] == Latin1.slash, k + 1 < end {
                    if buf[k + 1] == Latin1.slash {
                        break
                    }
                    if buf[k + 1] == Latin1.star {
                        buf[k] = Latin1.space
                        buf[k + 1] = Latin1.space
                        inBlock = true
                        k += 2
                        continue
                    }
                }
                k += 1
            }
        }
        return inBlock
    }

    /// `^\s*#\s*([a-z]+)\b\s*(.*)` on `buf[first..<end]`, where `buf[first]` is `#`.
    private static func directive(_ buf: [UInt8], _ first: Int, _ end: Int) -> (name: String, rest: [UInt8])? {
        var k = first + 1
        while k < end, Latin1.isSpace(buf[k]) {
            k += 1
        }
        let nameStart = k
        while k < end, (0x61 ... 0x7A).contains(buf[k]) {
            k += 1
        }
        guard k > nameStart, k == end || !Latin1.isWord(buf[k]) else { return nil }
        let name = Latin1.string(buf[nameStart ..< k])
        while k < end, Latin1.isSpace(buf[k]) {
            k += 1
        }
        return (name, Array(buf[k ..< end]))
    }

    private static func trimmedArgument(_ raw: [UInt8]) -> [UInt8] {
        var rest = raw
        if rest.count > 1, let cut = rest.firstIndex(ofBytes: [Latin1.slash, Latin1.slash]) {
            rest = Array(rest[..<cut])
        }
        while let last = rest.last, last == Latin1.space || last == Latin1.lf || last == Latin1.cr || last == Latin1.tab {
            rest.removeLast()
        }
        return rest
    }

    private static func define(_ rest: [UInt8], into defines: inout WPEShaderMacros) {
        guard let sp = rest.firstIndex(where: { $0 == Latin1.space || $0 == Latin1.tab }) else {
            defines[rest] = Latin1.bytes("1")
            return
        }
        let value = Array(rest[sp...].drop { $0 == Latin1.space || $0 == Latin1.tab })
        defines[Array(rest[..<sp])] = value.isEmpty ? Latin1.bytes("1") : value
    }
}

/// `#if`/`#elif` evaluation (FUN_140167e10 / FUN_140166a90): C precedence on 32-bit ints, macros expanded
/// recursively except inside their own expansion (as in C), undefined identifiers are 0, division by zero is 0.
enum WPEShaderExpression {
    enum Token: Equatable {
        case number(Int)
        case identifier([UInt8])
        case defined
        case op(String)
        case end
    }

    private static let twoCharOps: Set<String> = ["==", "!=", "<=", ">=", "&&", "||", "<<", ">>"]
    private static let levels: [Set<String>] = [
        ["||"], ["&&"], ["|"], ["^"], ["&"], ["==", "!="], ["<", "<=", ">", ">="], ["<<", ">>"], ["+", "-"],
        ["*", "/", "%"],
    ]
    /// Replacement bytes one expression may expand; a chain of distinct doubling macros is exponential otherwise.
    private static let maxExpandedBytes = 1 << 16

    static func evaluate(_ expression: [UInt8], defines: WPEShaderMacros) -> Int {
        var budget = maxExpandedBytes
        var parser = Parser(tokens: tokenize(expression, defines: defines, expanding: [], budget: &budget))
        return parser.parse(level: 0, defines: defines)
    }

    /// `expanding` holds the macros whose replacement text is being tokenized; they stay plain identifiers,
    /// as does every macro once `budget` is spent.
    static func tokenize(_ s: [UInt8], defines: WPEShaderMacros, expanding: Set<[UInt8]>, budget: inout Int) -> [Token] {
        var tokens: [Token] = []
        let n = s.count
        var i = 0
        var afterDefined = 0
        while i < n {
            let c = s[i]
            if Latin1.isSpace(c) {
                i += 1
                continue
            }
            if c == Latin1.slash, i + 1 < n, s[i + 1] == Latin1.slash {
                while i < n, s[i] != Latin1.cr, s[i] != Latin1.lf {
                    i += 1
                }
                continue
            }
            if c == Latin1.slash, i + 1 < n, s[i + 1] == Latin1.star {
                i = s.firstIndex(ofBytes: [Latin1.star, Latin1.slash], from: i + 2).map { $0 + 2 } ?? n
                continue
            }
            if Latin1.isDigit(c) {
                var v = 0
                if c == 0x30, i + 1 < n, s[i + 1] == 0x78 || s[i + 1] == 0x58 {
                    i += 2
                    while i < n, let digit = hexValue(s[i]) {
                        v = v &* 16 &+ digit
                        i += 1
                    }
                } else {
                    while i < n, Latin1.isDigit(s[i]) {
                        v = v &* 10 &+ Int(s[i]) &- 48
                        i += 1
                    }
                }
                if i < n, s[i] == 0x2E {
                    i += 1
                    while i < n, Latin1.isDigit(s[i]) {
                        i += 1
                    }
                }
                while i < n, Latin1.bytes("uflUFL").contains(s[i]) {
                    i += 1
                }
                tokens.append(.number(v))
                afterDefined = 0
                continue
            }
            if Latin1.isAlpha(c) || c == Latin1.underscore {
                var j = i
                while j < n, Latin1.isAlnum(s[j]) || s[j] == Latin1.underscore {
                    j += 1
                }
                let ident = Array(s[i ..< j])
                i = j
                if ident == Latin1.bytes("defined") {
                    tokens.append(.defined)
                    afterDefined = 2
                    continue
                }
                if afterDefined == 0, !expanding.contains(ident), let value = defines[ident], budget >= value.count {
                    budget -= value.count
                    tokens += tokenize(value, defines: defines, expanding: expanding.union([ident]), budget: &budget)
                } else {
                    tokens.append(.identifier(ident))
                }
                afterDefined = 0
                continue
            }
            if i + 1 < n {
                let two = Latin1.string(s[i ... i + 1])
                if twoCharOps.contains(two) {
                    tokens.append(.op(two))
                    i += 2
                    afterDefined = 0
                    continue
                }
            }
            tokens.append(.op(Latin1.string([c])))
            i += 1
            afterDefined = (c == 0x28 && afterDefined != 0) ? 1 : 0
        }
        return tokens
    }

    private static func hexValue(_ b: UInt8) -> Int? {
        switch b {
        case 0x30 ... 0x39: Int(b - 0x30)
        case 0x61 ... 0x66: Int(b - 0x61 + 10)
        case 0x41 ... 0x46: Int(b - 0x41 + 10)
        default: nil
        }
    }

    private static func i32(_ x: Int) -> Int {
        Int(Int32(truncatingIfNeeded: x))
    }

    private static func flag(_ b: Bool) -> Int {
        b ? 1 : 0
    }

    private static func apply(_ op: String, _ a: Int, _ b: Int) -> Int {
        switch op {
        case "||": flag(a != 0 || b != 0)
        case "&&": flag(a != 0 && b != 0)
        case "|": i32(a | b)
        case "^": i32(a ^ b)
        case "&": i32(a & b)
        case "==": flag(a == b)
        case "!=": flag(a != b)
        case "<": flag(a < b)
        case "<=": flag(a <= b)
        case ">": flag(a > b)
        case ">=": flag(a >= b)
        case "<<": (0 ..< 32).contains(b) ? i32(a << b) : 0
        case ">>": (0 ..< 32).contains(b) ? a >> b : 0
        case "+": i32(a &+ b)
        case "-": i32(a &- b)
        case "*": i32(a &* b)
        case "/": b == 0 ? 0 : i32(a.dividedReportingOverflow(by: b).partialValue)
        case "%": b == 0 ? 0 : i32(a.remainderReportingOverflow(dividingBy: b).partialValue)
        default: 0
        }
    }

    private struct Parser {
        let tokens: [Token]
        var k = 0

        init(tokens: [Token]) {
            self.tokens = tokens
        }

        func peek() -> Token {
            k < tokens.count ? tokens[k] : .end
        }

        mutating func take() -> Token {
            let token = peek()
            k += 1
            return token
        }

        mutating func parse(level: Int, defines: WPEShaderMacros) -> Int {
            if level == levels.count {
                return unary(defines: defines)
            }
            var v = parse(level: level + 1, defines: defines)
            while case let .op(op) = peek(), levels[level].contains(op) {
                k += 1
                v = apply(op, v, parse(level: level + 1, defines: defines))
            }
            return v
        }

        mutating func unary(defines: WPEShaderMacros) -> Int {
            switch take() {
            case .op("!"): return flag(unary(defines: defines) == 0)
            case .op("~"): return i32(~unary(defines: defines))
            case .op("-"): return i32(0 &- unary(defines: defines))
            case .op("+"): return unary(defines: defines)
            case let .number(v): return v
            case .defined:
                let paren = peek() == .op("(")
                if paren {
                    k += 1
                }
                var v = 0
                if case let .identifier(name) = take(), defines[name] != nil {
                    v = 1
                }
                if paren, peek() == .op(")") {
                    k += 1
                }
                return v
            case .op("("):
                let v = parse(level: 0, defines: defines)
                if peek() == .op(")") {
                    k += 1
                }
                return v
            default:
                return 0
            }
        }
    }
}
