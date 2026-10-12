/// Shader file loader of FUN_140162100: splits at CR/LF/NUL, drops empty lines except a leading one and
/// expands column-0 `#include "x"` from `shaders/x`, each name once per stage.
struct WPEShaderLoader {
    let sources: any WPEShaderSourceProviding

    private static let includeDirective = Latin1.bytes("#include")

    func load(_ source: [UInt8]?, included: inout Set<[UInt8]>) -> [UInt8] {
        guard let source else { return [] }
        let data = source.firstIndex(of: Latin1.nul).map { Array(source[..<$0]) } ?? source
        let n = data.count
        var out: [UInt8] = []
        if n == 0 {
            return out
        }
        var i = 0
        while true {
            var j = i
            while j < n, data[j] != Latin1.cr, data[j] != Latin1.lf {
                j += 1
            }
            let line = Array(data[i ..< j])
            if line.starts(with: Self.includeDirective) {
                if let name = Self.quotedName(line), included.insert(name).inserted {
                    let path = "shaders/" + Latin1.string(name)
                    out += load(sources.shaderSource(named: path), included: &included)
                }
            } else {
                out += line
            }
            out.append(Latin1.lf)
            while j < n, data[j] == Latin1.cr || data[j] == Latin1.lf {
                j += 1
            }
            i = j
            if i >= n {
                break
            }
        }
        return out
    }

    private static func quotedName(_ line: [UInt8]) -> [UInt8]? {
        guard let q1 = line.firstIndex(of: Latin1.quote), q1 + 1 < line.count,
              let q2 = line[(q1 + 1)...].firstIndex(of: Latin1.quote) else { return nil }
        return Array(line[(q1 + 1) ..< q2])
    }
}
