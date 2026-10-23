import Foundation

extension WPEParityScriptEngine {
    // MARK: Bindings

    func compileBindings(document: WPESceneDocument) {
        if case let .object(entries) = document.resolvedGeneralJSON {
            let supported = Set(sceneFields.map(\.name))
            for (name, value) in entries where value["script"] != nil && !supported.contains(name) {
                configuration.log(1, "general.\(name) script is unsupported: no registered descriptor consumer")
            }
        }
        for (rel, descriptor) in sceneFields.enumerated() {
            guard !descriptor.flags.contains(.notFromJSON) else { continue }
            addBinding(layerIndex: -1, path: descriptor.name.lowercased(), slot: sceneBase + rel,
                       descriptor: descriptor, className: "general", source: document.sourceJSON["general"],
                       root: document.resolvedGeneralJSON)
        }
        let sources = Dictionary(WPEParityProgramScene.array(document.sourceJSON["objects"]).compactMap { object in
            WPEParitySceneAnimations.id(object).map { ($0, object) }
        }) { first, _ in first }
        for (layerIndex, layer) in layers.enumerated() {
            compileLayerBindings(layerIndex, source: sources[layer.id])
        }
    }

    func compileLayerBindings(_ layerIndex: Int, source: WPESceneJSONValue?) {
        let layer = layers[layerIndex]
        if case let .object(entries) = layer.config {
            let supported = Set(fields(layer.kind).filter { !$0.flags.contains(.notFromJSON) }
                .filter { $0.owner != .video && $0.owner != .particleInstance }.map(\.name))
            for (name, value) in entries where value["script"] != nil && !supported.contains(name) {
                configuration.log(1, "\(layer.id).\(name) script is unsupported: no registered writable descriptor")
            }
        }
        let layerFields = fields(layer.kind)
        var bindingOrder = Array(layerFields.indices)
        if layer.kind == .sound {
            // Native v2 observes these three scalar scripts max→min→volume, independent of JSON insertion.
            // Reorder traversal only: each descriptor keeps its existing relative slot and metadata ABI.
            let positions = bindingOrder.filter {
                let field = layerFields[$0]
                return field.owner == .sound && field.type == .float
                    && (field.name == "maxtime" || field.name == "mintime" || field.name == "volume")
            }
            let ordered = positions.sorted { layerFields[$0].name < layerFields[$1].name }
            for (position, rel) in zip(positions, ordered) {
                bindingOrder[position] = rel
            }
        }
        for rel in bindingOrder {
            let descriptor = layerFields[rel]
            guard !descriptor.flags.contains(.notFromJSON) else { continue }
            let path = descriptor.owner == .particleInstance ? "instanceoverride/\(descriptor.name)"
                : descriptor.owner == .video ? "video/\(descriptor.name)" : descriptor.name
            addBinding(layerIndex: layerIndex, path: path, slot: layer.base + rel, descriptor: descriptor,
                       className: "\(layer.kind)", source: source)
        }
        for (effectIndex, effect) in WPEParityProgramScene.array(layer.config["effects"]).enumerated() {
            guard let effectID = WPEParitySceneAnimations.id(effect) else { continue }
            if let slot = effectSlots[layerIndex]?.first(where: { $0.id == effectID })?.slot {
                addBinding(layerIndex: layerIndex, path: "effects/\(effectIndex)/visible", slot: slot,
                           descriptor: WPEParityScriptProperty.effectVisible, className: "effect", source: source)
            }
            for pass in WPEParityProgramScene.array(effect["passes"]).indices {
                let key = WPEParityMaterialPassKey(objectID: layer.id, effectID: effectID, pass: pass)
                for (name, slot) in (constantSlots[key] ?? [:]).sorted(by: { $0.key < $1.key }) {
                    addBinding(layerIndex: layerIndex,
                               path: "effects/\(effectIndex)/passes/\(pass)/constantshadervalues/\(name)",
                               slot: slot, descriptor: descriptors[Int(slots[slot].descriptor)],
                               className: "material", source: source)
                }
            }
        }
        for (index, base) in (animationLayerBases[layerIndex] ?? []).enumerated() {
            for (rel, descriptor) in WPEParityScriptProperty.animationLayer.enumerated() {
                addBinding(layerIndex: layerIndex, path: "animationlayers/\(index)/\(descriptor.name)", slot: base + rel,
                           descriptor: descriptor, className: "animationlayer", source: source)
            }
        }
        for (name, slot) in (constantSlots[WPEParityMaterialPassKey(objectID: layer.id)] ?? [:])
            .sorted(by: { $0.key < $1.key }) {
            addBinding(layerIndex: layerIndex, path: "instance/constantshadervalues/\(name)", slot: slot,
                       descriptor: descriptors[Int(slots[slot].descriptor)], className: "material", source: source)
        }
    }

    private func addBinding(layerIndex: Int, path: String, slot: Int, descriptor: WPEParityScriptProperty,
                            className: String, source: WPESceneJSONValue?, root: WPESceneJSONValue? = nil) {
        let components = path.split(separator: "/").map(String.init)
        let config = root ?? (layerIndex >= 0 ? layers[layerIndex].config : nil)
        let resolved = components.reduce(config) { node, key in
            Int(key).flatMap { node?[$0] } ?? node?[key]
        }
        guard case let .string(script)? = resolved?["script"], !script.isEmpty else { return }
        let raw = components.reduce(source) { node, key in Int(key).flatMap { node?[$0] } ?? node?[key] }
        var userKeys: [String: [(name: String, condition: String)]] = [:]
        if case let .object(entries)? = raw?["scriptproperties"] {
            for (name, entry) in entries {
                if let key = WPEParityProgramScene.string(entry["user"])
                    ?? WPEParityProgramScene.string(entry["user"]?["name"]) {
                    let condition = WPEParityProgramScene.string(entry["user"]?["condition"]) ?? ""
                    userKeys[key, default: []].append((name, condition))
                }
            }
        }
        guard !executionLimiter.didTimeOut else { return }
        let name = "\(className)_\(components.last ?? path)"
        let vars = resolved?["scriptproperties"].map(Self.jsonText) ?? NSNull() as Any
        let bindingIndex = bindings.count
        let objectID = layerIndex < 0 ? "" : layers[layerIndex].id
        let modulePath = "scripts/\(name).js"
        bindings.append(Binding(objectID: objectID, path: path, name: name,
                                exportBits: 0, bindingIndex: bindingIndex, script: -1, userKeys: userKeys))
        let before = exceptionCount
        let function = evaluateScript(WPEParityScriptModule.lower(script),
                                      withSourceURL: URL(string: "scripts/\(name).js"))
        var bits = -1
        var handle = -1
        if !executionLimiter.didTimeOut, exceptionCount == before, let function, function.isObject {
            bits = Int(invokeHost("addBinding", withArguments: [
                function, name, modulePath, bindingIndex, layerIndex, slot, descriptor.type.rawValue,
                descriptor.flags.contains(.angle), descriptor.flags.contains(.notFromJSON), vars, descriptor.isSoundVolumeWrite,
                layerIndex >= 0 && layers[layerIndex].kind == .sound && descriptor.owner == .sound,
            ])?.toInt32() ?? -1)
            if bits >= 0 {
                handle = bindings.filter(\.compiled).count
            }
        }
        let registered = bindings[bindingIndex]
        bindings[bindingIndex] = Binding(objectID: objectID, path: path, name: name,
                                         exportBits: max(bits, 0), bindingIndex: bindingIndex,
                                         registeredAssets: registered.registeredAssets,
                                         script: handle, userKeys: userKeys)
    }
}
