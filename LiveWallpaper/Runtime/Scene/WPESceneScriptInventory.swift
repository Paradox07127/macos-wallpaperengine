#if !LITE_BUILD
    import LiveWallpaperProWPE

    extension WPESceneScriptInstanceInventory {
        init(document: WPESceneDocument) {
            let text = document.textObjects.reduce(into: 0) { count, object in
                if object.textScript != nil {
                    count += 1
                }
            }
            let layer = document.scriptHostObjects.count
                + document.imageObjects.reduce(into: 0) { count, object in
                    if object.visibleScript != nil {
                        count += 1
                    }
                    if object.alphaScript != nil {
                        count += 1
                    }
                }
                + document.textObjects.reduce(into: 0) { count, object in
                    if object.visibleScript != nil {
                        count += 1
                    }
                    if object.alphaScript != nil {
                        count += 1
                    }
                }
            let transform = document.imageObjects.reduce(into: 0) { count, object in
                if object.originScript != nil {
                    count += 1
                }
                if object.scaleScript != nil {
                    count += 1
                }
                if object.anglesScript != nil {
                    count += 1
                }
                if object.colorScript != nil {
                    count += 1
                }
            } + document.transformHostObjects.reduce(into: 0) { count, object in
                if object.originScript != nil {
                    count += 1
                }
                if object.scaleScript != nil {
                    count += 1
                }
                if object.anglesScript != nil {
                    count += 1
                }
            } + document.textObjects.reduce(into: 0) { count, object in
                if object.originScript != nil {
                    count += 1
                }
                if object.colorScript != nil {
                    count += 1
                }
                if object.scaleScript != nil {
                    count += 1
                }
                if object.anglesScript != nil {
                    count += 1
                }
            }
            // Shader-constant scripts share the transform inventory bucket. There is no instance cap.
            let effectConstants = document.imageObjects.reduce(into: 0) { count, object in
                for effect in object.effects {
                    for override in effect.passOverrides {
                        count += override.constantScripts.count
                    }
                }
            }
            self.init(text: text, layer: layer, transform: transform + effectConstants)
        }

        /// True if any bound script reads audio. Do not gate on supportsaudioprocessing (corpus omits it).
        static func usesAudioAPI(in document: WPESceneDocument) -> Bool {
            var found = false
            func note(_ script: String?) {
                guard !found, let script else { return }
                found = script.contains("registerAudioBuffers")
                    || script.contains("getFrequency")
                    || script.contains("getFrequencies")
            }
            for object in document.imageObjects {
                note(object.visibleScript)
                note(object.alphaScript)
                for transform in [object.originScript, object.scaleScript, object.anglesScript, object.colorScript] {
                    note(transform?.script)
                }
                for effect in object.effects {
                    note(effect.visibleScript?.script)
                    for override in effect.passOverrides {
                        for bound in override.constantScripts.values { note(bound.script) }
                    }
                }
            }
            for object in document.textObjects {
                note(object.textScript)
                note(object.visibleScript)
                note(object.alphaScript)
                for transform in [object.originScript, object.scaleScript, object.anglesScript, object.colorScript] {
                    note(transform?.script)
                }
            }
            for object in document.transformHostObjects {
                for transform in [object.originScript, object.scaleScript, object.anglesScript] {
                    note(transform?.script)
                }
            }
            for object in document.scriptHostObjects { note(object.visibleScript) }
            return found
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
                        if next == "/" { mode = .line; scalars.removeFirst(); continue }
                        if next == "*" { mode = .block; scalars.removeFirst(); continue }
                    }
                    if c == "\"" || c == "'" || c == "`" { mode = .string(c); continue }
                    out.append(c)
                case .line:
                    if c == "\n" { mode = .code; out.append(c) }
                case .block:
                    if c == "*", scalars.first == "/" { scalars.removeFirst(); mode = .code }
                case .string(let quote):
                    if c == "\\" { if !scalars.isEmpty { scalars.removeFirst() }; continue }
                    if c == quote { mode = .code }
                }
            }
            return String(out)
        }

        /// Visits every script slot the parser binds, stopping at the first match.
        /// (`usesAudioAPI` above predates this and walks the same slots inline.)
        private static func anyBoundScript(
            in document: WPESceneDocument,
            where matches: (String) -> Bool
        ) -> Bool {
            var found = false
            func note(_ script: String?) {
                guard !found, let script else { return }
                found = matches(script)
            }
            for object in document.imageObjects {
                note(object.visibleScript)
                note(object.alphaScript)
                for transform in [object.originScript, object.scaleScript, object.anglesScript, object.colorScript] {
                    note(transform?.script)
                }
                for effect in object.effects {
                    note(effect.visibleScript?.script)
                    for override in effect.passOverrides {
                        for bound in override.constantScripts.values { note(bound.script) }
                    }
                }
            }
            for object in document.textObjects {
                note(object.textScript)
                note(object.visibleScript)
                note(object.alphaScript)
                for transform in [object.originScript, object.scaleScript, object.anglesScript, object.colorScript] {
                    note(transform?.script)
                }
            }
            for object in document.transformHostObjects {
                for transform in [object.originScript, object.scaleScript, object.anglesScript] {
                    note(transform?.script)
                }
            }
            for object in document.scriptHostObjects { note(object.visibleScript) }
            return found
        }

        /// Diagnostic: budget spent on duplicate sources (WPE does not share module state).
        static func sourceReuse(in document: WPESceneDocument) -> (bindings: Int, distinct: Int, maxRepeat: Int) {
            var counts: [String: Int] = [:]
            func note(_ script: String?) {
                guard let script, !script.isEmpty else { return }
                counts[script, default: 0] += 1
            }
            for object in document.imageObjects {
                note(object.visibleScript)
                note(object.alphaScript)
                for transform in [object.originScript, object.scaleScript, object.anglesScript, object.colorScript] {
                    note(transform?.script)
                }
                for effect in object.effects {
                    note(effect.visibleScript?.script)
                    for override in effect.passOverrides {
                        for bound in override.constantScripts.values { note(bound.script) }
                    }
                }
            }
            for object in document.textObjects {
                note(object.textScript)
                note(object.visibleScript)
                note(object.alphaScript)
                for transform in [object.originScript, object.scaleScript, object.anglesScript, object.colorScript] {
                    note(transform?.script)
                }
            }
            for object in document.transformHostObjects {
                for transform in [object.originScript, object.scaleScript, object.anglesScript] {
                    note(transform?.script)
                }
            }
            for object in document.scriptHostObjects { note(object.visibleScript) }
            return (
                bindings: counts.values.reduce(0, +),
                distinct: counts.count,
                maxRepeat: counts.values.max() ?? 0
            )
        }
    }
#endif
