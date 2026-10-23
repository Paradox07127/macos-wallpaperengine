import JavaScriptCore

extension WPEParityScriptEngine {
    // MARK: Layout

    private func index(of descriptor: WPEParityScriptProperty) -> Int32 {
        if let index = descriptorIndex[descriptor] {
            return Int32(index)
        }
        descriptorIndex[descriptor] = descriptors.count
        descriptors.append(descriptor)
        return Int32(descriptors.count - 1)
    }

    private func registered(_ fields: [WPEParityScriptProperty]) -> [WPEParityScriptProperty] {
        fields.map { field in
            configuration.propertyOverrides.first { $0.owner == field.owner && $0.name == field.name } ?? field
        } + configuration.propertyOverrides.filter { override in
            fields.contains { $0.owner == override.owner } && !fields.contains { $0.owner == override.owner && $0.name == override.name }
        }
    }

    func fields(_ kind: WPEParityScriptLayerKind) -> [WPEParityScriptProperty] {
        registered(WPEParityScriptProperty.layer(kind) + (kind == .image ? WPEParityScriptProperty.video : []))
    }

    var sceneFields: [WPEParityScriptProperty] {
        registered(WPEParityScriptProperty.scene)
    }

    func layout(document: WPESceneDocument, state: WPEParitySceneState) {
        for object in document.resolvedObjectsJSON {
            guard let id = WPEParitySceneAnimations.id(object) else { continue }
            addLayer(id: id, kind: WPEParityScriptLayerKind.classify(id: id, object: object, document: document),
                     config: object, state: state, document: document)
        }
        sceneBase = slots.count
        for descriptor in sceneFields {
            let slot = slots.count
            slots.append(Slot(layer: -1, descriptor: index(of: descriptor)))
            refresh.append(.field(slot: slot, objectID: "", name: descriptor.fieldName))
            let key = WPEParitySceneState.ScriptFieldKey(objectID: "", name: descriptor.fieldName)
            let parsed = Self.parse(document.resolvedGeneralJSON[descriptor.name.lowercased()], descriptor)
            // Strict scene JSON must not be replaced by a generic number-derived product seed.
            // Existing canonical fields are retained by seedMissingFields and mirror.
            let strictSceneSeed = descriptor.isSceneBloomField || descriptor.isSceneCameraFade || descriptor.isSceneCameraParallax
                || descriptor.isSceneCameraShake || descriptor.isSceneProjection
            let value = strictSceneSeed ? parsed ?? Self.generalDefault(descriptor)
                : configuration.fieldDefaults[key] ?? parsed ?? Self.generalDefault(descriptor)
            if let value {
                initialValues.append((slot, value))
            }
        }
        grow(to: slots.count + 256)
        for (slot, value) in initialValues {
            store(value, at: slot)
        }
    }

    @discardableResult
    func addLayer(id: String, kind: WPEParityScriptLayerKind, config: WPESceneJSONValue,
                  state: WPEParitySceneState?, document: WPESceneDocument? = nil) -> Int {
        let layerIndex = Int32(layers.count)
        let base = slots.count
        let stateIndex = state?.index(of: id)
        let hasVideo = config["video"] != nil || ["video.rate", "video.loop", "video.duration"].contains {
            configuration.fieldDefaults[.init(objectID: id, name: $0)] != nil || state?.scriptField($0, of: id) != nil
        }
        layers.append(Layer(id: id, kind: kind, base: base, config: config, hasVideo: hasVideo))
        for descriptor in fields(kind) {
            let slot = slots.count
            slots.append(Slot(layer: layerIndex, descriptor: index(of: descriptor)))
            if case let .object(property) = descriptor.target, stateIndex != nil {
                refresh.append(.object(slot: slot, objectID: id, property))
                continue
            }
            let raw: WPESceneJSONValue? = switch descriptor.owner {
            case .particleInstance: config["instanceoverride"]?[descriptor.name]
            case .video: config["video"]?[descriptor.name]
            default: config[descriptor.name]
            }
            refresh.append(.field(slot: slot, objectID: id, name: descriptor.fieldName))
            let key = WPEParitySceneState.ScriptFieldKey(objectID: id, name: descriptor.fieldName)
            if let value = configuration.fieldDefaults[key] ?? (descriptor.flags.contains(.notFromJSON) ? nil : Self.parse(raw, descriptor))
                ?? Self.fallback(descriptor, objectID: id, document: document) {
                initialValues.append((slot, value))
            }
        }
        if kind == .image {
            for (index, entry) in WPEParityProgramScene.array(config["animationlayers"]).enumerated() {
                animationLayerBases[Int(layerIndex), default: []].append(slots.count)
                for descriptor in WPEParityScriptProperty.animationLayer {
                    let slot = slots.count
                    slots.append(Slot(layer: layerIndex, descriptor: self.index(of: descriptor), animationLayer: Int32(index)))
                    refresh.append(.field(slot: slot, objectID: id, name: fieldName(slot: slot)))
                    // Native defaults for an absent field: the 14026c680 ctor sets visible, rate, blend 1 and blendtime 0.5.
                    let fallback: WPEParitySceneState.ScriptValue = switch descriptor.name {
                    case "visible", "rate", "blend": .vector(SIMD4(1, 0, 0, 0))
                    case "blendtime": .vector(SIMD4(0.5, 0, 0, 0))
                    case "name": .string("")
                    default: .vector(.zero)
                    }
                    initialValues.append((slot, Self.parse(entry[descriptor.name], descriptor) ?? fallback))
                }
            }
        }
        guard let state else { return Int(layerIndex) }
        for effect in WPEParityProgramScene.array(config["effects"]) {
            guard let effectID = WPEParitySceneAnimations.id(effect) else { continue }
            let slot = slots.count
            var entry = Slot(layer: layerIndex, descriptor: index(of: WPEParityScriptProperty.effectVisible))
            if let effectIndex = state.effects.firstIndex(of: .init(objectID: id, effectID: effectID)) {
                entry.effect = Int32(effectKeys.count)
                effectKeys.append(state.effects[effectIndex])
                refresh.append(.effect(slot: slot, key: state.effects[effectIndex]))
            }
            slots.append(entry)
            effectSlots[Int(layerIndex), default: []].append((effectID, slot))
            for (pass, values) in WPEParityProgramScene.array(effect["passes"]).enumerated() {
                addConstants(values["constantshadervalues"], layer: layerIndex,
                             pass: WPEParityMaterialPassKey(objectID: id, effectID: effectID, pass: pass), state: state)
            }
            for pass in materialPassesByOwner[WPEParityMaterialPassKey(objectID: id, effectID: effectID)] ?? [] {
                addConstants(nil, layer: layerIndex, pass: pass, state: state)
            }
        }
        addConstants(config["instance"]?["constantshadervalues"], layer: layerIndex,
                     pass: WPEParityMaterialPassKey(objectID: id), state: state)
        for pass in materialPassesByOwner[WPEParityMaterialPassKey(objectID: id)] ?? [] {
            addConstants(nil, layer: layerIndex, pass: pass, state: state)
        }
        return Int(layerIndex)
    }

    private func addConstants(_ values: WPESceneJSONValue?, layer: Int32, pass key: WPEParityMaterialPassKey,
                              state: WPEParitySceneState) {
        guard state.passIndex(of: key) != nil else { return }
        if let effectID = key.effectID, let records = configuration.resolvedEffectRecords[.init(objectID: key.objectID, effectID: effectID)],
           !records.contains(where: { $0.materialPass == key }) {
            return
        }
        let entries: [String: WPESceneJSONValue] = if case let .object(raw)? = values {
            raw
        } else {
            [:]
        }
        let passIndex = state.passIndex(of: key)
        let native = passIndex.map { state.constants(pass: $0) } ?? [:]
        let metadata = materialConstantsByPass[key] ?? [:]
        let names = Set(entries.keys).union(native.keys).union(metadata.keys.map(\.name)).sorted()
        for name in names {
            guard constantSlots[key]?[name] == nil else { continue }
            let raw = entries[name]
            let info = metadata[ConstantKey(pass: key, name: name)]
            let components = info?.components ?? native[name]?.count ?? raw.map { Self.components($0["value"] ?? $0).count } ?? 0
            let angle = info?.angle ?? configuration.angleConstants.contains(ConstantKey(pass: key, name: name))
            guard let descriptor = WPEParityScriptProperty.material(name: name, components: components, angle: angle)
            else { continue }
            let slot = slots.count
            slots.append(Slot(layer: layer, descriptor: index(of: descriptor), materialPass: key))
            constantSlots[key, default: [:]][name] = slot
            refresh.append(.constant(slot: slot, key: key, name: name))
            if let value = native[name]?.value ?? info?.value ?? raw.map({ Self.vector(Self.components($0["value"] ?? $0)) }) {
                initialValues.append((slot, .vector(value)))
            }
        }
    }

    func grow(to count: Int) {
        guard count > capacity else { return }
        let newCapacity = max(count, capacity * 2)
        let newFloats = UnsafeMutablePointer<Float>.allocate(capacity: newCapacity * 4)
        newFloats.initialize(repeating: 0, count: newCapacity * 4)
        let newIntegers = UnsafeMutablePointer<Int32>.allocate(capacity: newCapacity)
        newIntegers.initialize(repeating: 0, count: newCapacity)
        let newFlags = UnsafeMutablePointer<UInt8>.allocate(capacity: newCapacity)
        newFlags.initialize(repeating: 0, count: newCapacity)
        let newDirty = UnsafeMutablePointer<Int32>.allocate(capacity: newCapacity + 1)
        newDirty.initialize(repeating: 0, count: newCapacity + 1)
        if capacity > 0 {
            newFloats.update(from: floats, count: capacity * 4)
            newIntegers.update(from: integers, count: capacity)
            newFlags.update(from: dirtyFlags, count: capacity)
            newDirty.update(from: dirty, count: capacity + 1)
        } else {
            floats.deallocate()
            integers.deallocate()
            dirtyFlags.deallocate()
            dirty.deallocate()
        }
        // The old buffers belong to their typed arrays, which free them when collected.
        (floats, integers, dirtyFlags, dirty, capacity) = (newFloats, newIntegers, newFlags, newDirty, newCapacity)
        guard host != nil else { return }
        invokeHost("rebind", withArguments: [typedArray(.float32, floats, newCapacity * 16),
                                             typedArray(.int32, integers, newCapacity * 4),
                                             typedArray(.uint8, dirtyFlags, newCapacity),
                                             typedArray(.int32, dirty, (newCapacity + 1) * 4)])
    }

    enum ArrayType {
        case float32, uint8, int32
    }

    /// A typed array over `bytes`; `owned` arrays free their bytes when collected.
    func typedArray(_ type: ArrayType, _ bytes: UnsafeMutableRawPointer, _ length: Int,
                    owned: Bool = true) -> JSValue {
        let kind: JSTypedArrayType = switch type {
        case .float32: kJSTypedArrayTypeFloat32Array
        case .uint8: kJSTypedArrayTypeUint8Array
        case .int32: kJSTypedArrayTypeInt32Array
        }
        var exception: JSValueRef?
        let array = JSObjectMakeTypedArrayWithBytesNoCopy(
            context.jsGlobalContextRef, kind, bytes, length, owned ? { bytes, _ in bytes?.deallocate() } : nil, nil,
            &exception
        )
        return JSValue(jsValueRef: array, in: context)
    }
}
