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
            // Shader-constant scripts count against the per-scene cap (same as transforms).
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
