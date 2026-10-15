/// ES module support on JavaScriptCore's public API, which has no module loader: a module's top-level `import` and
/// `export` declarations are lowered into a function `(__wpeImport, __wpeExport, thisLayer, thisObject)` whose body
/// keeps every other character, line breaks included, so exception lines match the source.
public enum WPEParityScriptModule {
    /// The resolved asset path of `specifier` imported from the module at `importer`. A bare name is a WPE asset
    /// module, `scripts/jsmodules/<lowercased>.js` (wevector.js imports 'WEMath' for wemath.js); a relative one
    /// resolves against the importer's folder, `.js` added when the name has no extension.
    public static func resolve(_ specifier: String, importer: String) -> String {
        guard specifier.hasPrefix("./") || specifier.hasPrefix("../") || specifier.hasPrefix("/") else {
            let name = specifier.lowercased()
            return "scripts/jsmodules/" + (name.hasSuffix(".js") ? name : name + ".js")
        }
        var parts = specifier.hasPrefix("/") ? [] : importer.split(separator: "/").dropLast().map(String.init)
        for part in specifier.split(separator: "/") {
            switch part {
            case ".": continue
            case "..": _ = parts.popLast()
            default: parts.append(String(part))
            }
        }
        let path = parts.joined(separator: "/")
        return path.split(separator: "/").last?.contains(".") == true ? path : path + ".js"
    }

    /// `source` as a function expression returning an internal setter for its existing alias parameter slots.
    public static func lower(_ source: String) -> String {
        var lowering = Lowering(Array(source.utf16))
        lowering.run()
        return "(function(__wpeImport, __wpeExport, thisLayer, thisObject) {'use strict';"
            + String(decoding: lowering.output, as: UTF16.self) + "\n" + lowering.exportTail
            + "return function(layer, object, save) {const previous = save ? [thisLayer, thisObject] : null;"
            + "thisLayer = layer; thisObject = object; return previous;};})"
    }
}

private struct Lowering {
    private enum Previous {
        case start, punctuator, value, keyword
    }

    let text: [UInt16]
    var output: [UInt16] = []
    var exportTail = ""
    private var position = 0
    private var depth = 0
    /// Brace depth at which each open template `${` resumes its template.
    private var templates: [Int] = []
    private var previous = Previous.start
    private var previousWasDot = false

    init(_ text: [UInt16]) {
        self.text = text
        output.reserveCapacity(text.count + 64)
    }

    private static let regexKeywords: Set<String> = [
        "return", "typeof", "case", "do", "else", "in", "of", "new", "delete", "void", "throw", "instanceof", "yield",
        "await",
    ]

    mutating func run() {
        while position < text.count {
            let unit = text[position]
            if Self.isSpace(unit) || Self.isLineBreak(unit) {
                output.append(unit)
                position += 1
            } else if unit == 0x2F, peek(1) == 0x2F || peek(1) == 0x2A {
                copyComment()
            } else if unit == 0x27 || unit == 0x22 {
                copyString(quote: unit)
                note(.value)
            } else if unit == 0x60 {
                copyTemplate()
                note(.value)
            } else if unit == 0x2F {
                if previous == .value {
                    copy(1)
                    note(.punctuator)
                } else {
                    copyRegex()
                    note(.value)
                }
            } else if Self.isIdentifierStart(unit) {
                let start = position
                let word = readIdentifier()
                if depth == 0, !previousWasDot, word == "import", lowerImport(from: start) {
                    note(.punctuator)
                } else if depth == 0, !previousWasDot, word == "export", lowerExport(from: start) {
                    note(.punctuator)
                } else {
                    output.append(contentsOf: text[start ..< position])
                    note(Self.regexKeywords.contains(word) ? .keyword : .value)
                }
            } else if Self.isDigit(unit) {
                while position < text.count, Self.isIdentifierPart(text[position]) || text[position] == 0x2E {
                    copy(1)
                }
                note(.value)
            } else {
                copyPunctuator(unit)
            }
        }
    }

    private mutating func note(_ kind: Previous, dot: Bool = false) {
        previous = kind
        previousWasDot = dot
    }

    private mutating func copyPunctuator(_ unit: UInt16) {
        switch unit {
        case 0x7B, 0x28, 0x5B:
            depth += 1
            copy(1)
            note(.punctuator)
        case 0x7D:
            if let resume = templates.last, resume == depth {
                templates.removeLast()
                copy(1)
                depth -= 1
                copyTemplateBody()
                note(.value)
                return
            }
            depth -= 1
            copy(1)
            note(.punctuator)
        case 0x29, 0x5D:
            depth -= 1
            copy(1)
            note(.value)
        case 0x2E:
            copy(1)
            note(.punctuator, dot: true)
        default:
            copy(1)
            note(.punctuator)
        }
    }

    // MARK: Declarations

    /// `import … from 'm'` or `import 'm'`; false for `import(` and `import.meta`.
    private mutating func lowerImport(from start: Int) -> Bool {
        var cursor = Cursor(text: text, position: position)
        cursor.skipTrivia()
        guard let next = cursor.peek(), next != 0x28, next != 0x2E else { return false }
        if let specifier = cursor.readString() {
            emit("__wpeImport(\(Self.quoted(specifier)));", replacing: start, through: cursor.endOfStatement())
            return true
        }
        var bindings: [String] = []
        let module = "__wpeImport(%@)"
        var namespace: String?
        var defaultName: String?
        var named: [(String, String)] = []
        while let unit = cursor.peek() {
            if unit == 0x2A {
                cursor.position += 1
                cursor.skipTrivia()
                guard cursor.readIdentifier() == "as" else { return false }
                cursor.skipTrivia()
                namespace = cursor.readIdentifier()
            } else if unit == 0x7B {
                cursor.position += 1
                guard let list = cursor.readSpecifierList() else { return false }
                named = list
            } else if let name = cursor.readIdentifier() {
                if name == "from" {
                    break
                }
                defaultName = name
            } else {
                return false
            }
            cursor.skipTrivia()
            if cursor.peek() == 0x2C {
                cursor.position += 1
            }
            cursor.skipTrivia()
            if cursor.peekWord() == "from" {
                _ = cursor.readIdentifier()
                break
            }
        }
        cursor.skipTrivia()
        guard let specifier = cursor.readString() else { return false }
        let call = module.replacingOccurrences(of: "%@", with: Self.quoted(specifier))
        if let namespace {
            bindings.append("const \(namespace) = \(call);")
        }
        if let defaultName {
            bindings.append("const \(defaultName) = \(call).default;")
        }
        if !named.isEmpty {
            let fields = named.map { $0.0 == $0.1 ? $0.0 : "\($0.0): \($0.1)" }.joined(separator: ", ")
            bindings.append("const { \(fields) } = \(call);")
        }
        emit(bindings.isEmpty ? "\(call);" : bindings.joined(separator: " "), replacing: start,
             through: cursor.endOfStatement())
        return true
    }

    private mutating func lowerExport(from start: Int) -> Bool {
        var cursor = Cursor(text: text, position: position)
        cursor.skipTrivia()
        guard let next = cursor.peek() else { return false }
        if next == 0x7B {
            cursor.position += 1
            guard let list = cursor.readSpecifierList() else { return false }
            cursor.skipTrivia()
            var source: String?
            if cursor.peekWord() == "from" {
                _ = cursor.readIdentifier()
                cursor.skipTrivia()
                source = cursor.readString()
            }
            for (local, exported) in list {
                let value = source.map { "__wpeImport(\(Self.quoted($0)))[\(Self.quoted(local))]" } ?? local
                exportTail += "__wpeExport(\(Self.quoted(exported)), () => \(value));\n"
            }
            emit("", replacing: start, through: cursor.endOfStatement())
            return true
        }
        if next == 0x2A {
            cursor.position += 1
            cursor.skipTrivia()
            var namespace: String?
            if cursor.peekWord() == "as" {
                _ = cursor.readIdentifier()
                cursor.skipTrivia()
                namespace = cursor.readIdentifier()
                cursor.skipTrivia()
            }
            guard cursor.readIdentifier() == "from" else { return false }
            cursor.skipTrivia()
            guard let specifier = cursor.readString() else { return false }
            let call = "__wpeImport(\(Self.quoted(specifier)))"
            if let namespace {
                exportTail += "__wpeExport(\(Self.quoted(namespace)), () => \(call));\n"
            } else {
                exportTail += "for (const k of Object.keys(\(call))) if (k !== 'default') __wpeExport(k, () => \(call)[k]);\n"
            }
            emit("", replacing: start, through: cursor.endOfStatement())
            return true
        }
        let keywordStart = cursor.position
        guard let keyword = cursor.readIdentifier() else { return false }
        switch keyword {
        case "default":
            cursor.skipTrivia()
            var probe = cursor
            var word = probe.readIdentifier()
            if word == "async" {
                probe.skipTrivia()
                word = probe.readIdentifier()
            }
            if word == "function" || word == "class" {
                probe.skipTrivia()
                if probe.peek() == 0x2A {
                    probe.position += 1
                    probe.skipTrivia()
                }
                if let name = probe.readIdentifier() {
                    exportTail += "__wpeExport('default', () => \(name));\n"
                    emit("", replacing: start, through: cursor.position)
                    return true
                }
            }
            exportTail += "__wpeExport('default', () => __wpeDefault);\n"
            emit("const __wpeDefault = ", replacing: start, through: cursor.position)
            return true
        case "function", "class", "async", "var", "let", "const":
            var probe = cursor
            probe.skipTrivia()
            if keyword == "async" {
                _ = probe.readIdentifier()
                probe.skipTrivia()
            }
            if probe.peek() == 0x2A {
                probe.position += 1
                probe.skipTrivia()
            }
            guard let name = probe.readIdentifier() else { return false }
            exportTail += "__wpeExport(\(Self.quoted(name)), () => \(name));\n"
            emit("", replacing: start, through: keywordStart)
            return true
        default:
            return false
        }
    }

    /// Replaces `text[start..<end]` with `replacement`, keeping its line breaks.
    private mutating func emit(_ replacement: String, replacing start: Int, through end: Int) {
        output.append(contentsOf: replacement.utf16)
        for unit in text[start ..< end] where Self.isLineBreak(unit) {
            output.append(unit)
        }
        position = end
    }

    // MARK: Tokens copied verbatim

    private mutating func copy(_ count: Int) {
        let end = min(position + count, text.count)
        output.append(contentsOf: text[position ..< end])
        position = end
    }

    private func peek(_ offset: Int) -> UInt16? {
        position + offset < text.count ? text[position + offset] : nil
    }

    private mutating func readIdentifier() -> String {
        let start = position
        while position < text.count, Self.isIdentifierPart(text[position]) {
            position += 1
        }
        return String(decoding: text[start ..< position], as: UTF16.self)
    }

    private mutating func copyComment() {
        if text[position + 1] == 0x2F {
            while position < text.count, !Self.isLineBreak(text[position]) {
                copy(1)
            }
        } else {
            copy(2)
            while position < text.count, !(text[position] == 0x2A && peek(1) == 0x2F) {
                copy(1)
            }
            copy(2)
        }
    }

    private mutating func copyString(quote: UInt16) {
        copy(1)
        while position < text.count, text[position] != quote, !Self.isLineBreak(text[position]) {
            copy(text[position] == 0x5C ? 2 : 1)
        }
        copy(1)
    }

    private mutating func copyTemplate() {
        copy(1)
        copyTemplateBody()
    }

    /// From inside a template to its closing backtick, or into a `${` whose `}` resumes it.
    private mutating func copyTemplateBody() {
        while position < text.count {
            let unit = text[position]
            if unit == 0x5C {
                copy(2)
            } else if unit == 0x60 {
                copy(1)
                return
            } else if unit == 0x24, peek(1) == 0x7B {
                copy(2)
                depth += 1
                templates.append(depth)
                return
            } else {
                copy(1)
            }
        }
    }

    private mutating func copyRegex() {
        copy(1)
        var inClass = false
        while position < text.count, !Self.isLineBreak(text[position]) {
            let unit = text[position]
            if unit == 0x5C {
                copy(2)
                continue
            }
            copy(1)
            if unit == 0x5B {
                inClass = true
            } else if unit == 0x5D {
                inClass = false
            } else if unit == 0x2F, !inClass {
                break
            }
        }
        while position < text.count, Self.isIdentifierPart(text[position]) {
            copy(1)
        }
    }

    static func quoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "'", with: "\\'") + "'"
    }

    static func isLineBreak(_ unit: UInt16) -> Bool {
        unit == 0x0A || unit == 0x0D || unit == 0x2028 || unit == 0x2029
    }

    /// ECMAScript WhiteSpace: tab, VT, FF, space, NBSP, BOM and the Zs block WPE's exporter emits between keywords.
    static func isSpace(_ unit: UInt16) -> Bool {
        switch unit {
        case 0x09, 0x0B, 0x0C, 0x20, 0xA0, 0xFEFF, 0x1680, 0x2000 ... 0x200A, 0x202F, 0x205F, 0x3000: true
        default: false
        }
    }

    static func isDigit(_ unit: UInt16) -> Bool {
        unit >= 0x30 && unit <= 0x39
    }

    static func isIdentifierStart(_ unit: UInt16) -> Bool {
        (unit >= 0x41 && unit <= 0x5A) || (unit >= 0x61 && unit <= 0x7A) || unit == 0x24 || unit == 0x5F
            || unit == 0x5C || (unit >= 0x80 && !isSpace(unit) && !isLineBreak(unit))
    }

    static func isIdentifierPart(_ unit: UInt16) -> Bool {
        isIdentifierStart(unit) || isDigit(unit)
    }
}

/// A look-ahead reader over declaration syntax; it never writes output.
private struct Cursor {
    let text: [UInt16]
    var position: Int

    func peek() -> UInt16? {
        position < text.count ? text[position] : nil
    }

    mutating func skipTrivia() {
        while position < text.count {
            let unit = text[position]
            if Lowering.isSpace(unit) || Lowering.isLineBreak(unit) {
                position += 1
            } else if unit == 0x2F, position + 1 < text.count, text[position + 1] == 0x2F {
                while position < text.count, !Lowering.isLineBreak(text[position]) {
                    position += 1
                }
            } else if unit == 0x2F, position + 1 < text.count, text[position + 1] == 0x2A {
                position += 2
                while position + 1 < text.count, !(text[position] == 0x2A && text[position + 1] == 0x2F) {
                    position += 1
                }
                position = min(position + 2, text.count)
            } else {
                return
            }
        }
    }

    mutating func readIdentifier() -> String? {
        guard let first = peek(), Lowering.isIdentifierStart(first) else { return nil }
        let start = position
        while position < text.count, Lowering.isIdentifierPart(text[position]) {
            position += 1
        }
        return String(decoding: text[start ..< position], as: UTF16.self)
    }

    func peekWord() -> String? {
        var copy = self
        return copy.readIdentifier()
    }

    mutating func readString() -> String? {
        guard let quote = peek(), quote == 0x27 || quote == 0x22 else { return nil }
        position += 1
        var units: [UInt16] = []
        while position < text.count, text[position] != quote {
            if text[position] == 0x5C, position + 1 < text.count {
                position += 1
            }
            units.append(text[position])
            position += 1
        }
        position += 1
        return String(decoding: units, as: UTF16.self)
    }

    /// `a, b as c }` after the opening brace, as (local, exported) pairs.
    mutating func readSpecifierList() -> [(String, String)]? {
        var list: [(String, String)] = []
        while true {
            skipTrivia()
            if peek() == 0x7D {
                position += 1
                return list
            }
            guard let local = readIdentifier() ?? readString() else { return nil }
            skipTrivia()
            var exported = local
            if peekWord() == "as" {
                _ = readIdentifier()
                skipTrivia()
                guard let name = readIdentifier() ?? readString() else { return nil }
                exported = name
                skipTrivia()
            }
            list.append((local, exported))
            if peek() == 0x2C {
                position += 1
            }
        }
    }

    /// Past an optional `;` on the declaration's line.
    func endOfStatement() -> Int {
        var probe = self
        while probe.position < text.count, Lowering.isSpace(text[probe.position]) {
            probe.position += 1
        }
        return probe.peek() == 0x3B ? probe.position + 1 : position
    }
}
