import Foundation
import JavaScriptCore
import simd

extension WPEParityScriptEngine {
    // MARK: Host

    /// Host indices originate in JS; conversion must not trap before checking an existing wrapper's bounds.
    static func checkedLayerIndex(_ value: Double, count: Int) -> Int? {
        guard let index = Int(exactly: value), index >= 0, index < count else { return nil }
        return index
    }

    /// nil = no puppet, an unresolved key, or a world transform without the layer's matrix; setters answer [].
    private func puppetCommand(_ layer: Layer, _ command: PuppetCommand, key: JSValue, values: [Float]) -> [Float]? {
        guard let handler = puppetHandler else {
            configuration.log(1, "bone and blend shape methods are unsupported without a product puppet consumer")
            return nil
        }
        // 1401fdf90.c:1601-1659: a bone's scene matrix is the layer's vfunc+0x80 matrix times its puppet world.
        var object = matrix_identity_float4x4
        if command == .boneTransform || command == .setBoneTransform {
            guard let state = activeState else {
                configuration.log(1, "getBoneTransform and setBoneTransform are unsupported outside a scene callback")
                return nil
            }
            guard state.pointee.isAlive(layer.id) else { return nil }
            flushWrites(to: &state.pointee)
            guard let matrix = transformMatrixHandler?(layer.id, layer.kind, state.pointee) else {
                configuration.log(1, "getBoneTransform and setBoneTransform are unsupported without a product transform owner")
                return nil
            }
            object = matrix
        }
        var result: [Float]?
        let found = handler(layer.id) { puppet in
            result = Self.perform(command, on: &puppet, key: key, values: values, object: object)
        }
        return found ? result : nil
    }

    private static func perform(_ command: PuppetCommand, on puppet: inout WPEParityPuppetAnimator, key: JSValue,
                                values: [Float], object: simd_float4x4) -> [Float]? {
        // 14020fa10.c:22-95 and 1402105c0.c:18-58: an int32 below the count, or the first entry with that non-empty name.
        func resolve(count: Int, named: (String) -> Int?) -> Int? {
            if key.isString {
                return named(key.toString())
            }
            guard key.isNumber, let index = Int(exactly: key.toDouble()), index >= 0, index < count else { return nil }
            return index
        }
        let matrix = values.count == 16 ? simd_float4x4((0 ..< 4).map { SIMD4(values[$0 * 4 ..< $0 * 4 + 4]) }) : nil
        let vector = values.count == 3 ? SIMD3(values[0], values[1], values[2]) : nil
        func floats(_ matrix: simd_float4x4) -> [Float] {
            [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
        }
        switch command {
        case .boneCount:
            return [Float(puppet.boneLocal.count)]
        case .boneIndex:
            return [Float(puppet.boneIndex(named: key.toString()) ?? -1)]
        case .blendShapeIndex:
            return [Float(puppet.blendShapeIndex(named: key.toString()) ?? -1)]
        case .blendShapeWeight, .setBlendShapeWeight:
            guard let shape = resolve(count: puppet.blendShapeCount, named: puppet.blendShapeIndex(named:)) else { return nil }
            guard command == .setBlendShapeWeight else { return [puppet.blendShapeWeight(at: shape)] }
            guard let weight = values.first else { return nil }
            puppet.setBlendShapeWeight(weight, at: shape)
            return []
        default:
            break
        }
        guard let bone = resolve(count: puppet.boneLocal.count, named: puppet.boneIndex(named:)) else { return nil }
        let local = puppet.boneLocal[bone]
        switch command {
        case .boneParentIndex:
            return [Float(puppet.parentIndex(of: bone) ?? -1)]
        case .boneTransform:
            return floats(object * puppet.boneWorld[bone])
        case .localBoneTransform:
            return floats(local)
        case .localBoneAngles:
            let angles = WPEParityPuppetAnimator.angles(of: local)
            return [angles.x, angles.y, angles.z]
        case .localBoneOrigin:
            return [local.columns.3.x, local.columns.3.y, local.columns.3.z]
        case .setBoneTransform:
            guard let matrix else { return nil }
            puppet.setBoneWorld(object.inverse * matrix, at: bone)
        case .setLocalBoneTransform:
            guard let matrix else { return nil }
            puppet.setBoneLocal(matrix, at: bone)
        case .setLocalBoneAngles:
            guard let vector else { return nil }
            puppet.setBoneLocal(WPEParityPuppetAnimator.replacingRotation(of: local, angles: vector), at: bone)
        case .setLocalBoneOrigin:
            guard let vector else { return nil }
            var moved = local
            moved.columns.3 = SIMD4(vector, local.columns.3.w)
            puppet.setBoneLocal(moved, at: bone)
        case .boneCount, .boneIndex, .blendShapeIndex, .blendShapeWeight, .setBlendShapeWeight:
            return nil
        }
        return []
    }

    func installHost(state: WPEParitySceneState) {
        let host = JSValue(newObjectIn: context)!
        func set(_ key: String, _ value: Any) {
            host.setObject(value, forKeyedSubscript: key as NSString)
        }
        set("floats", typedArray(.float32, floats, capacity * 16))
        set("integers", typedArray(.int32, integers, capacity * 4))
        set("dirtyFlags", typedArray(.uint8, dirtyFlags, capacity))
        set("dirty", typedArray(.int32, dirty, (capacity + 1) * 4))
        set("globals", typedArray(.float32, globals, 64, owned: false))
        set("audio", typedArray(.float32, audio, 336 * 4, owned: false))
        set("eventNames", WPEParityScriptEvent.allCases.map { $0.functionName ?? NSNull() as Any })
        set("kinds", WPEParityScriptLayerKind.allCases.map { kind in
            fields(kind).enumerated().map { rel, field in Self.fieldInfo(field, rel: rel) }
        })
        set("sceneFields", sceneFields.enumerated().map { rel, field in
            Self.fieldInfo(field, rel: rel)
        })
        set("sceneBase", sceneBase)
        set("animationLayerFields", WPEParityScriptProperty.animationLayer.enumerated().map { rel, field in
            Self.fieldInfo(field, rel: rel)
        })
        let resolve: @convention(block) (String, String) -> String = { specifier, importer in
            WPEParityScriptModule.resolve(specifier, importer: importer)
        }
        let load: @convention(block) (String) -> JSValue? = { [weak self] path in
            guard let self, let data = configuration.assets.data(path) else { return nil }
            return evaluateScript(WPEParityScriptModule.lower(String(bytes: data, encoding: .utf8) ?? ""),
                                  withSourceURL: URL(string: path))
        }
        let error: @convention(block) (String, String) -> Void = { [weak self] name, message in
            self?.record(name.isEmpty ? message : "\(name): \(message)")
        }
        let log: @convention(block) (Double, String) -> Void = { [weak self] level, message in
            self?.configuration.log(Int(level), message)
        }
        let shortcut: @convention(block) (String) -> Bool = { [weak self] name in
            self?.configuration.openUserShortcut(name) ?? false
        }
        let canDestroy: @convention(block) (Double) -> Bool = { [weak self] index in
            guard let self, let index = Self.checkedLayerIndex(index, count: layers.count),
                  configuration.destroyLayer != nil else { return false }
            let id = layers[index].id
            let token = activeState?.pointee.object(id)?.modelDataToken
            let admitted = configuration.canDestroyLayer?(id, token) ?? true
            if !admitted {
                configuration.log(1, "destroyLayer is unsupported for this product resource consumer")
            }
            return admitted
        }
        let destroyed: @convention(block) (Double) -> Bool = { [weak self] index in
            guard let self, let index = Self.checkedLayerIndex(index, count: layers.count), let state = activeState,
                  let destroy = configuration.destroyLayer else { return false }
            let id = layers[index].id
            flushWrites(to: &state.pointee)
            guard destroy(id, &state.pointee) else {
                record("destroyLayer transaction failed for \(id)")
                return false
            }
            destroyedObjectIDs.append(id)
            let layer = Int32(index)
            refresh.removeAll { slots[$0.slot].layer == layer }
            return true
        }
        let sort: @convention(block) (Double, Double) -> Bool = { [weak self] index, position in
            guard let self, let index = Self.checkedLayerIndex(index, count: layers.count),
                  let position = Int(exactly: position), let state = activeState,
                  let sort = configuration.sortLayer else { return false }
            flushWrites(to: &state.pointee)
            return sort(layers[index].id, position, &state.pointee)
        }
        // `parentIndex` −1 clears the parent. 1 accepted, 0 rejected, nil when nothing ran.
        let setParent: @convention(block) (Double, Double) -> NSNumber? = { [weak self] index, parentIndex in
            guard let self, let index = Self.checkedLayerIndex(index, count: layers.count) else { return nil }
            guard let state = activeState else {
                configuration.log(1, "setParent is unsupported outside a scene callback")
                return nil
            }
            var parentID: String?
            if parentIndex != -1 {
                guard let parent = Self.checkedLayerIndex(parentIndex, count: layers.count) else { return nil }
                parentID = layers[parent].id
            }
            flushWrites(to: &state.pointee)
            return NSNumber(value: state.pointee.setParent(layers[index].id, to: parentID) ? 1 : 0)
        }
        let registerAudio: @convention(block) (Double) -> Void = { [weak self] resolution in
            self?.audioResolutions.insert(Int(resolution))
        }
        let initialConfig: @convention(block) (Double) -> String? = { [weak self] index in
            guard let self, let index = Self.checkedLayerIndex(index, count: layers.count),
                  case var .object(entries) = layers[index].config else { return nil }
            entries["id"] = nil
            return Self.jsonText(.object(entries))
        }
        let soundVolumeWritten: @convention(block) (Double) -> Void = { [weak self] slot in
            self?.soundVolumeWritten(slot: slot)
        }
        let soundCommand: @convention(block) (Double, Double) -> Bool = { [weak self] layer, command in
            self?.soundCommand(layer: layer, command: command) ?? false
        }
        let pauseVideo: @convention(block) (Double) -> Void = { [weak self] index in
            guard let self else { return }
            guard let index = Self.checkedLayerIndex(index, count: layers.count), layers[index].hasVideo else {
                configuration.log(1, "video.pause is unsupported for an invalid video owner")
                return
            }
            guard let pause = configuration.pauseVideoTexture, pause(layers[index].id) else {
                configuration.log(1, "video.pause is unsupported without an existing product video consumer")
                return
            }
        }
        let videoTextureCommand: @convention(block) (Double, Double, Double) -> NSNumber? = { [weak self] index, raw, argument in
            guard let self, let raw = Int(exactly: raw), let command = VideoCommand(rawValue: raw) else { return nil }
            guard let index = Self.checkedLayerIndex(index, count: layers.count), layers[index].hasVideo else {
                configuration.log(1, "video.\(command) is unsupported for an invalid video owner")
                return nil
            }
            guard let handler = videoTextureHandler, let result = handler(layers[index].id, command, argument) else {
                configuration.log(1, "video.\(command) is unsupported without an existing product video consumer")
                return nil
            }
            return NSNumber(value: result)
        }
        let textureAnimationCommand: @convention(block) (Double, Double, Double) -> NSNumber? = { [weak self] index, raw, value in
            guard let self, let index = Self.checkedLayerIndex(index, count: layers.count),
                  let raw = Int(exactly: raw), let command = TextureAnimationCommand(rawValue: raw) else { return nil }
            guard let handler = textureAnimationHandler else {
                configuration.log(1, "getTextureAnimation is unsupported without a product sprite consumer")
                return nil
            }
            return handler(layers[index].id, command, value).map { NSNumber(value: $0) }
        }
        let animationLayerCommand: @convention(block) (Double, Double, Double, Double) -> NSNumber? = { [weak self] index, animationLayer, raw, value in
            guard let self, let index = Self.checkedLayerIndex(index, count: layers.count),
                  let animationLayer = Int(exactly: animationLayer),
                  let raw = Int(exactly: raw), let command = AnimationLayerCommand(rawValue: raw) else { return nil }
            guard let handler = animationLayerHandler else {
                configuration.log(1, "IAnimationLayer is unsupported without a product puppet consumer")
                return nil
            }
            return handler(layers[index].id, animationLayer, command, value).map { NSNumber(value: $0) }
        }
        let particleCommand: @convention(block) (Double, Double, Double) -> NSNumber? = { [weak self] index, raw, count in
            guard let self, let index = Self.checkedLayerIndex(index, count: layers.count), layers[index].kind == .particle,
                  let raw = Int(exactly: raw), let command = ParticleCommand(rawValue: raw),
                  let count = Int32(exactly: count) else { return nil }
            if let state = activeState, !state.pointee.isAlive(layers[index].id) {
                return nil
            }
            guard let handler = particleSystemHandler, let result = handler(layers[index].id, command, count) else {
                configuration.log(1, "IParticleSystem methods are unsupported without a product particle consumer")
                return nil
            }
            return NSNumber(value: result)
        }
        let executeMaterialFunction: @convention(block) (Double, String) -> Void = { [weak self] slot, name in
            guard let self, let slot = Self.checkedLayerIndex(slot, count: slots.count),
                  let effect = Self.checkedLayerIndex(Double(slots[slot].effect), count: effectKeys.count) else { return }
            guard let handler = materialFunctionHandler else {
                configuration.log(1, "executeMaterialFunction is unsupported without a product resource consumer")
                return
            }
            handler(effectKeys[effect], name)
        }
        // A material receiver passes one of its constant slots; a layer passes slot -1 and its index; the scene -1, -2.
        let findAnimation: @convention(block) (Double, Double, String) -> Double = { [weak self] slot, layer, name in
            guard let self else { return -1 }
            let owner: (id: String?, pass: WPEParityMaterialPassKey?)
            if let slot = Self.checkedLayerIndex(slot, count: slots.count), let pass = slots[slot].materialPass {
                owner = (pass.objectID, pass)
            } else if slot == -1, layer == -2 {
                owner = (nil, nil)
            } else if let layer = Self.checkedLayerIndex(layer, count: layers.count) {
                owner = (layers[layer].id, nil)
            } else {
                return -1
            }
            guard let lookup = propertyAnimationLookup else {
                configuration.log(1, "getAnimation is unsupported without a product animation owner")
                return -1
            }
            guard let animation = lookup(owner.id, owner.pass, name) else { return -1 }
            if let handle = animationHandles.firstIndex(where: { $0 === animation }) {
                return Double(handle)
            }
            animationHandles.append(animation)
            return Double(animationHandles.count - 1)
        }
        let animationCommand: @convention(block) (Double, Double, Double) -> Double = { [weak self] handle, raw, value in
            guard let self, let handle = Self.checkedLayerIndex(handle, count: animationHandles.count),
                  let raw = Int(exactly: raw), let command = AnimationCommand(rawValue: raw) else { return 0 }
            let animation = animationHandles[handle]
            switch command {
            case .play: animation.play()
            case .pause: animation.pause()
            case .stop: animation.stop()
            case .isPlaying: return animation.isPlaying ? 1 : 0
            case .setFrame: animation.frame = Float(value)
            case .getFrame: return Double(animation.frame)
            case .getRate: return Double(animation.rate)
            case .setRate: animation.rate = Float(value)
            case .fps: return Double(animation.fps)
            case .frameCount: return Double(animation.frameCount)
            case .duration: return Double(animation.duration)
            }
            return 0
        }
        let animationName: @convention(block) (Double) -> String = { [weak self] handle in
            guard let self, let handle = Self.checkedLayerIndex(handle, count: animationHandles.count) else { return "" }
            return animationHandles[handle].name ?? ""
        }
        let layerIndexByID: @convention(block) (String) -> Double = { [weak self] id in
            Double(self?.layers.firstIndex { $0.id == id } ?? -1)
        }
        let lookAtAngles: @convention(block) (Double, Double, Double, Double, Double, Double,
                                              Double, Double, Double, Double, Double) -> NSArray? = { ox, oy, oz, tx, ty, tz, ux, uy, uz, camera, yawOnly in
            guard let angles = WPEParityLayerTransform.lookAtAngles(
                origin: SIMD3(Float(ox), Float(oy), Float(oz)), target: SIMD3(Float(tx), Float(ty), Float(tz)),
                up: SIMD3(Float(ux), Float(uy), Float(uz)), camera: camera != 0, yawOnly: yawOnly != 0
            ) else { return nil }
            return [NSNumber(value: angles.x), NSNumber(value: angles.y), NSNumber(value: angles.z)] as NSArray
        }
        let transformMatrix: @convention(block) (Double) -> NSArray? = { [weak self] index in
            guard let self, let index = Self.checkedLayerIndex(index, count: layers.count) else { return nil }
            let layer = layers[index]
            guard layer.kind != .text else {
                configuration.log(1, "getTransformMatrix is unsupported for text layers")
                return nil
            }
            guard let state = activeState else {
                configuration.log(1, "getTransformMatrix is unsupported outside a scene callback")
                return nil
            }
            guard state.pointee.isAlive(layer.id) else { return nil }
            flushWrites(to: &state.pointee)
            guard let handler = transformMatrixHandler, let matrix = handler(layer.id, layer.kind, state.pointee) else {
                configuration.log(1, "getTransformMatrix is unsupported without a product transform owner")
                return nil
            }
            let columns = [matrix.columns.0, matrix.columns.1, matrix.columns.2, matrix.columns.3]
            return columns.flatMap { [$0.x, $0.y, $0.z, $0.w] }.map { NSNumber(value: $0) } as NSArray
        }
        let puppetCommand: @convention(block) (Double, Double, JSValue, NSArray) -> NSArray? = { [weak self] index, raw, key, values in
            guard let self, let index = Self.checkedLayerIndex(index, count: layers.count), layers[index].kind == .image,
                  let raw = Int(exactly: raw), let command = PuppetCommand(rawValue: raw) else { return nil }
            let numbers = (values as? [NSNumber])?.map(\.floatValue) ?? []
            return puppetCommand(layers[index], command, key: key, values: numbers)?.map { NSNumber(value: $0) } as NSArray?
        }
        // 14018da30.c:7-13: root eye, center, up and zoom as ten numbers.
        let cameraTransforms: @convention(block) () -> NSArray? = { [weak self] in
            guard let self else { return nil }
            guard let state = activeState else {
                configuration.log(1, "getCameraTransforms is unsupported outside a scene callback")
                return nil
            }
            let members = ["eye", "center", "up", "zoom"].compactMap { name -> SIMD4<Float>? in
                let key = WPEParitySceneState.ScriptFieldKey(objectID: "", name: "cameraTransforms.\(name)")
                guard case let .vector(value)? = state.pointee.scriptField(key.name, of: "")
                    ?? configuration.fieldDefaults[key] else { return nil }
                return value
            }
            guard members.count == 4 else {
                configuration.log(1, "getCameraTransforms is unsupported without a product camera owner")
                return nil
            }
            let numbers = members.dropLast().flatMap { [$0.x, $0.y, $0.z] } + [members[3].x]
            return numbers.map { NSNumber(value: $0) } as NSArray
        }
        // 14018da90.c:7-21: each non-null member overwrites its root value; Vec3 members arrive as [x, y, z].
        let setCameraTransforms: @convention(block) (JSValue, JSValue, JSValue, JSValue) -> Void = { [weak self] eye, center, up, zoom in
            guard let self else { return }
            guard let state = activeState else {
                configuration.log(1, "setCameraTransforms is unsupported outside a scene callback")
                return
            }
            for (name, value) in [("eye", eye), ("center", center), ("up", up), ("zoom", zoom)] where !value.isNull {
                let vector = value.isNumber ? SIMD4(Float(value.toDouble()), 0, 0, 0)
                    : SIMD4((0 ..< 3).map { Float(value.atIndex($0).toDouble()) } + [0])
                state.pointee.setScriptField("cameraTransforms.\(name)", of: "", to: .vector(vector), invalidating: .none)
            }
        }
        let create: @convention(block) (String) -> Double = { [weak self] json in
            self?.createLayer(json: json) ?? -1
        }
        let createModel: @convention(block) (JSValue, Double) -> JSValue? = { [weak self] input, binding in
            self?.modelData(input, token: nil, replacing: false, bindingIndex: binding)
        }
        let updateModel: @convention(block) (Double, JSValue, Bool, Double) -> JSValue? = { [weak self] token, input, replacing, binding in
            guard let token = UInt32(exactly: token) else { return nil }
            return self?.modelData(input, token: token, replacing: replacing, bindingIndex: binding)
        }
        let releaseModel: @convention(block) (Double) -> Void = { [weak self] token in
            guard let self, let token = UInt32(exactly: token), let state = activeState else { return }
            state.pointee.releaseModelData(token)
        }
        set("resolve", resolve)
        set("load", load)
        set("error", error)
        set("log", log)
        set("openUserShortcut", shortcut)
        set("destroyed", destroyed)
        set("canDestroyLayer", canDestroy)
        set("sortLayer", sort)
        set("setParent", setParent)
        let registerAsset: @convention(block) (Double, String, Bool) -> Bool = { [weak self] binding, path, flag in
            guard let self, let index = Int(exactly: binding), bindings.indices.contains(index), !bindings[index].registeredAssets.contains(where: { $0.path.utf8.elementsEqual(path.utf8) }) else { return false }
            bindings[index].registeredAssets.append(.init(path: path, flag: flag))
            return true
        }
        set("registerAsset", registerAsset)
        set("registerAudio", registerAudio)
        set("initialConfig", initialConfig)
        set("pauseVideoTexture", pauseVideo)
        set("videoTextureCommand", videoTextureCommand)
        set("soundVolumeWritten", soundVolumeWritten)
        set("soundCommand", soundCommand)
        set("soundKind", WPEParityScriptLayerKind.sound.rawValue)
        set("imageKind", WPEParityScriptLayerKind.image.rawValue)
        set("textureAnimationCommand", textureAnimationCommand)
        set("animationLayerCommand", animationLayerCommand)
        set("particleCommand", particleCommand)
        set("particleKind", WPEParityScriptLayerKind.particle.rawValue)
        set("executeMaterialFunction", executeMaterialFunction)
        set("findAnimation", findAnimation)
        set("animationCommand", animationCommand)
        set("animationName", animationName)
        set("lookAtAngles", lookAtAngles)
        set("transformMatrix", transformMatrix)
        set("puppetCommand", puppetCommand)
        set("cameraTransforms", cameraTransforms)
        set("setCameraTransforms", setCameraTransforms)
        set("cameraKind", WPEParityScriptLayerKind.camera.rawValue)
        set("layerIndexByID", layerIndexByID)
        set("createLayer", create)
        set("createModelData", createModel)
        set("updateModelData", updateModel)
        set("releaseModelData", releaseModel)
        let storageGet: @convention(block) (String, Double) -> String? = { [weak self] key, location in
            self?.configuration.storage?.get(key, location == 0 ? .global : .screen)
        }
        let storageSet: @convention(block) (String, String, Double) -> Void = { [weak self] key, value, location in
            self?.configuration.storage?.set(key, value, location == 0 ? .global : .screen)
        }
        let storageDelete: @convention(block) (String, Double) -> Bool = { [weak self] key, location in
            self?.configuration.storage?.delete(key, location == 0 ? .global : .screen) ?? false
        }
        let storageClear: @convention(block) (Double) -> Bool = { [weak self] location in
            self?.configuration.storage?.clear(location == 0 ? .global : .screen) ?? false
        }
        set("storageGet", storageGet)
        set("storageSet", storageSet)
        set("storageDelete", storageDelete)
        set("storageClear", storageClear)
        _ = callJavaScript(evaluateScript(WPEParityScriptPrelude.source, withSourceURL: URL(string: "parity-host.js")),
                           withArguments: [host])
        self.host = host
        tickFunction = host.forProperty("tick")
        setStringsFunction = host.forProperty("setStrings")
        for (index, layer) in layers.enumerated() {
            addHostLayer(index, layer, state: state)
        }
        for (slot, value) in initialValues {
            if case let .string(string) = value {
                store(.string(string), at: slot)
            }
        }
        sendStrings()
        invokeHost("setUserProperties", withArguments: [configuration.userPropertiesJSON])
    }

    private static func fieldInfo(_ field: WPEParityScriptProperty, rel: Int) -> [String: Any] {
        let owner = switch field.owner {
        case .particleInstance: "instance"
        case .video: "video"
        default: ""
        }
        return ["name": field.name, "type": field.type.rawValue, "angle": field.flags.contains(.angle),
                "readonly": field.flags.contains(.notFromJSON), "soundVolume": field.isSoundVolumeWrite, "rel": rel, "owner": owner]
    }

    private func addHostLayer(_ index: Int, _ layer: Layer, state: WPEParitySceneState) {
        let parent = WPEParityProgramScene.string(layer.config["parent"]).flatMap { id in
            layers.firstIndex { $0.id == id }
        } ?? (WPEParityProgramScene.numericID(layer.config["parent"]).flatMap { id in
            layers.firstIndex { $0.id == id }
        } ?? -1)
        var effects: [[String: Any]] = []
        let effectJSON = WPEParityProgramScene.array(layer.config["effects"])
        for (effectID, slot) in effectSlots[index] ?? [] {
            guard let effect = effectJSON.first(where: { WPEParitySceneAnimations.id($0) == effectID }) else {
                continue
            }
            let records = configuration.resolvedEffectRecords[.init(objectID: layer.id, effectID: effectID)]
            func resolvedMaterialKey(_ record: WPEParityEffectPassRecord) -> WPEParityMaterialPassKey? {
                guard let key = record.materialPass, record.filePassIndex >= 0,
                      key.objectID == layer.id, key.effectID == effectID, key.pass == record.filePassIndex,
                      state.passIndex(of: key) != nil else { return nil }
                return key
            }
            let materialKeys = (records.map { Set($0.compactMap(resolvedMaterialKey)) }
                ?? Set(constantSlots.keys.filter { $0.objectID == layer.id && $0.effectID == effectID }))
                .filter { state.passIndex(of: $0) != nil }
                .sorted { $0.pass < $1.pass }
            let passes = materialKeys.map(materialInfo)
            let recordMaterials: [[String: Any]] = records?.map { record in
                ["pass": resolvedMaterialKey(record).flatMap { materialKeys.firstIndex(of: $0) } ?? -1,
                 "path": record.materialPath.map { $0 as Any } ?? NSNull(),
                 "hasMaterial": record.materialPass != nil || record.materialPath != nil]
            } ?? []
            effects.append(["slot": slot, "name": WPEParityProgramScene.string(effect["name"]) ?? effectID,
                            "passes": passes, "records": recordMaterials,
                            "metadataKnown": records != nil])
        }
        let baseMaterials = constantSlots.keys.filter {
            $0.objectID == layer.id && $0.effectID == nil && state.passIndex(of: $0) != nil
        }
        .sorted { $0.pass < $1.pass }.map(materialInfo)
        let animationLayers = (animationLayerBases[index] ?? []).enumerated().map { ["index": $0.offset, "base": $0.element] }
        invokeHost("addLayer", withArguments: [index, layer.kind.rawValue, layer.base, parent, effects, baseMaterials,
                                               layer.hasVideo, animationLayers])
    }

    private func materialInfo(_ key: WPEParityMaterialPassKey) -> [String: Any] {
        var constants: [String: Any] = [:]
        for (name, constantSlot) in constantSlots[key] ?? [:] {
            let descriptor = descriptors[Int(slots[constantSlot].descriptor)]
            constants[name] = ["slot": constantSlot, "type": descriptor.type.rawValue,
                               "angle": descriptor.flags.contains(.angle), "readonly": descriptor.flags.contains(.notFromJSON)]
        }
        return constants
    }

    private func modelData(_ input: JSValue, token: UInt32?, replacing: Bool, bindingIndex: Double) -> JSValue? {
        guard let provider = configuration.modelData, let admitShape = modelDataAdmissionHandler, let state = activeState else {
            configuration.log(1, "ModelData is unsupported without the product resource owner")
            return nil
        }
        flushWrites(to: &state.pointee)
        // Getter failures remain ordinary catchable JS values; the converter must not count them as uncaught.
        let capturedOutside = capturesExceptionsAsValues
        context.exception = nil
        capturesExceptionsAsValues = true
        defer { capturesExceptionsAsValues = capturedOutside }
        let assetContext = Int(exactly: bindingIndex).flatMap(assetContext(of:))
        return WPEParityScriptModels.perform(input, token: token, assetContext: assetContext,
                                             provider: provider) { patch in
            // No State inout borrow spans VM getters/material conversion; the owned patch is now complete.
            if let token {
                try state.pointee.updateModelData(token, patch: patch, replacing: replacing, admitShape: admitShape)
                return nil
            }
            return try state.pointee.createModelData(patch, admitShape: admitShape)
        }
    }

    private func createLayer(json: String) -> Double {
        guard let create = configuration.createLayer, let state = activeState else {
            configuration.log(1, "createLayer is unsupported without a product resource transaction")
            return -1
        }
        flushWrites(to: &state.pointee)
        var candidate = state.pointee
        guard let created = create(json, &candidate),
              let object = try? JSONSerialization.jsonObject(with: Data(created.configJSON.utf8)),
              let config = WPESceneJSONValue(jsonValue: object), case .object = config,
              !created.id.isEmpty, Self.preparedIdentity(config) == created.id,
              state.pointee.index(of: created.id) == nil,
              candidate.index(of: created.id) != nil,
              candidate.ids.count == state.pointee.ids.count + 1,
              Array(candidate.ids.dropLast()) == state.pointee.ids,
              Array(candidate.objects.dropLast()) == state.pointee.objects,
              Array(candidate.commonOrder.dropLast()) == state.pointee.commonOrder,
              !layers.contains(where: { $0.id == created.id }),
              hasCreatedMaterialConsumers(id: created.id, config: config, state: candidate) else {
            configuration.log(1, "createLayer candidate is invalid or unsupported; no state was committed")
            return -1
        }
        if case let .number(number)? = config["model"] {
            guard let token = UInt32(exactly: number), candidate.modelData(token) != nil else {
                configuration.log(1, "createLayer numeric model has no canonical prepared State consumer")
                return -1
            }
            if candidate.object(created.id)?.modelDataToken == nil {
                do { try candidate.retainModelData(token, for: created.id) } catch {
                    configuration.log(1, "createLayer could not retain its canonical ModelData")
                    return -1
                }
            } else if candidate.object(created.id)?.modelDataToken != token {
                configuration.log(1, "createLayer candidate retained a different ModelData token")
                return -1
            }
        }
        state.pointee = candidate
        let kind: WPEParityScriptLayerKind = config["text"] != nil ? .text
            : config["particle"] != nil ? .particle : config["sound"] != nil ? .sound : .image
        let start = initialValues.count
        let firstBinding = bindings.filter(\.compiled).count
        let index = addLayer(id: created.id, kind: kind, config: config, state: state.pointee)
        grow(to: slots.count)
        for (slot, value) in initialValues[start...] {
            store(value, at: slot)
        }
        seedMissingFields(state: &state.pointee, first: start)
        mirroredGenerations = nil
        mirror(state.pointee)
        addHostLayer(index, layers[index], state: state.pointee)
        compileLayerBindings(index, source: config)
        invokeHost("init", withArguments: [firstBinding])
        createdLayers.append(created)
        return Double(index)
    }

    /// Authored constant writes may only register a real prepared pass, just like loaded layers. This validates
    /// candidate value-state; it does not infer resources, native handles, or descriptors from authored JSON.
    private func hasCreatedMaterialConsumers(id: String, config: WPESceneJSONValue, state: WPEParitySceneState) -> Bool {
        func hasConstants(_ value: WPESceneJSONValue?) -> Bool {
            if case let .object(entries)? = value {
                return !entries.isEmpty
            }
            return false
        }
        if hasConstants(config["instance"]?["constantshadervalues"]),
           state.passIndex(of: .init(objectID: id)) == nil {
            return false
        }
        for effect in WPEParityProgramScene.array(config["effects"]) {
            guard let effectID = Self.preparedIdentity(effect),
                  state.effects.contains(.init(objectID: id, effectID: effectID)) else { return false }
            let records = configuration.resolvedEffectRecords[.init(objectID: id, effectID: effectID)]
            for (pass, value) in WPEParityProgramScene.array(effect["passes"]).enumerated() {
                guard hasConstants(value["constantshadervalues"]) else { continue }
                let key = WPEParityMaterialPassKey(objectID: id, effectID: effectID, pass: pass)
                guard state.passIndex(of: key) != nil else { return false }
                if let records, !records.contains(where: { $0.materialPass == key }) {
                    return false
                }
            }
        }
        return true
    }

    /// A host-prepared config carries its assigned ID. Unlike authored name lookup, this never falls back to a
    /// name or truncates an out-of-range/fractional number while validating a candidate that may be rejected.
    private static func preparedIdentity(_ config: WPESceneJSONValue) -> String? {
        if case let .string(id)? = config["id"], !id.isEmpty {
            return id
        }
        if case let .number(number)? = config["id"], let id = Int(exactly: number) {
            return String(id)
        }
        return nil
    }
}
