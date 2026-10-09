#if !LITE_BUILD
import LiveWallpaperProWPE

extension WPESceneScriptInstanceInventory {
    /// `effectVisibility` scripts are scanned but never constructed as a runtime, so the count skips them.
    enum BoundScriptFamily {
        case text, layer, transform, effectVisibility
    }

    init(document: WPESceneDocument) {
        var text = 0
        var layer = 0
        var transform = 0
        Self.forEachBoundScript(in: document) { family, _ in
            switch family {
            case .text: text += 1
            case .layer: layer += 1
            case .transform: transform += 1
            case .effectVisibility: break
            }
        }
        self.init(text: text, layer: layer, transform: transform)
    }

    static func forEachBoundScript(
        in document: WPESceneDocument,
        _ body: (BoundScriptFamily, String) -> Void
    ) {
        func each(_ family: BoundScriptFamily, _ scripts: [String?]) {
            for case let script? in scripts {
                body(family, script)
            }
        }
        for object in document.imageObjects {
            each(.layer, [object.visibleScript, object.alphaScript])
            each(.transform, [
                object.originScript, object.scaleScript, object.anglesScript, object.colorScript,
                object.parallaxDepthScript,
            ].map { $0?.script })
            for effect in object.effects {
                each(.effectVisibility, [effect.visibleScript?.script])
                for override in effect.passOverrides {
                    each(.transform, override.constantScripts.values.map(\.script))
                }
            }
        }
        for object in document.textObjects {
            each(.text, [object.textScript])
            each(.layer, [object.visibleScript, object.alphaScript])
            each(.transform, [
                object.originScript, object.scaleScript, object.anglesScript, object.colorScript,
            ].map { $0?.script })
        }
        let lightObjectIDs = Set(document.lightObjects.map(\.id))
        for object in document.transformHostObjects where !lightObjectIDs.contains(object.id) {
            each(.transform, [object.originScript, object.scaleScript, object.anglesScript].map { $0?.script })
        }
        for object in document.particleObjects {
            each(.transform, [object.instanceOverride?.rateScript?.script])
            each(.layer, [object.instanceOverride?.alphaScript])
        }
        for object in document.lightObjects {
            each(.transform, ["origin", "scale", "angles", "color"].map { object.fieldBindings[$0]?.script })
        }
        each(.layer, document.scriptHostObjects.map(\.visibleScript))
    }

    /// True if any bound script reads audio. Do not gate on supportsaudioprocessing (corpus omits it).
    static func usesAudioAPI(in document: WPESceneDocument) -> Bool {
        anyBoundScript(in: document) { script in
            script.contains("registerAudioBuffers")
                || script.contains("getFrequency")
                || script.contains("getFrequencies")
        }
    }

    /// True if any bound script exports a media handler. There is no `supports*` opt-in
    /// for media in scene.json — WPE simply calls the conventionally-named export — so this
    /// scan IS the demand signal, and a scene without one must never cost a now-playing
    /// subscription. Only the handlers we dispatch count; `mediaStatusChanged` isn't wired,
    /// so claiming demand for it would subscribe and deliver nothing.
    static func usesMediaAPI(in document: WPESceneDocument) -> Bool {
        anyBoundScript(in: document) { script in
            // Over comment/string-stripped source: a `// TODO: wire
            // mediaPlaybackChanged` or a string literal holding an event name
            // used to subscribe the scene to now-playing, violating the
            // "no handler costs nothing" contract. Still a text probe — the
            // real gate is `wpeExportsFunction` after evaluation — so it may
            // only over-approximate exports, never miss one: handlers are
            // static module exports, which never live inside a comment or
            // string.
            let code = strippingCommentsAndStrings(script)
            return code.contains("mediaPlaybackChanged")
                || code.contains("mediaPropertiesChanged")
                || code.contains("mediaThumbnailChanged")
                || code.contains("mediaTimelineChanged")
        }
    }

    /// Removes `//`/`/* */` comments and '"`-quoted literals (escape-aware).
    /// Template-literal `${}` interpolation is treated as string text — code
    /// inside one cannot declare a module export, which is all this feeds.
    static func strippingCommentsAndStrings(_ source: String) -> String {
        var out = String.UnicodeScalarView()
        out.reserveCapacity(source.unicodeScalars.count)
        var scalars = source.unicodeScalars[...]
        enum Mode { case code, line, block, string(UnicodeScalar) }
        var mode = Mode.code
        while let c = scalars.first {
            scalars.removeFirst()
            switch mode {
            case .code:
                if c == "/", let next = scalars.first {
                    if next == "/" {
                        mode = .line; scalars.removeFirst(); continue
                    }
                    if next == "*" {
                        mode = .block; scalars.removeFirst(); continue
                    }
                }
                if c == "\"" || c == "'" || c == "`" {
                    mode = .string(c); continue
                }
                out.append(c)
            case .line:
                if c == "\n" {
                    mode = .code; out.append(c)
                }
            case .block:
                if c == "*", scalars.first == "/" {
                    scalars.removeFirst(); mode = .code
                }
            case let .string(quote):
                if c == "\\" {
                    if !scalars.isEmpty {
                        scalars.removeFirst()
                    }; continue
                }
                if c == quote {
                    mode = .code
                }
            }
        }
        return String(out)
    }

    private static func anyBoundScript(
        in document: WPESceneDocument,
        where matches: (String) -> Bool
    ) -> Bool {
        var found = false
        forEachBoundScript(in: document) { _, script in
            if !found {
                found = matches(script)
            }
        }
        return found
    }

    static func sourceReuse(in document: WPESceneDocument) -> (bindings: Int, distinct: Int, maxRepeat: Int) {
        var counts: [String: Int] = [:]
        forEachBoundScript(in: document) { _, script in
            guard !script.isEmpty else { return }
            counts[script, default: 0] += 1
        }
        return (
            bindings: counts.values.reduce(0, +),
            distinct: counts.count,
            maxRepeat: counts.values.max() ?? 0
        )
    }
}
#endif
