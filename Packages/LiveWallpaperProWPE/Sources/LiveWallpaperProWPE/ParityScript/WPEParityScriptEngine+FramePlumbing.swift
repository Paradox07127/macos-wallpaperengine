import Foundation
import JavaScriptCore

extension WPEParityScriptEngine {
    // MARK: Frame plumbing

    func count(_ event: WPEParityScriptEvent) {
        dispatchCounts[event.rawValue] += 1
    }

    func recordException(_ exception: JSValue?) {
        guard executionLimiter.prepareInvocation(in: context) else { return }
        let message = exception?.toString() ?? "SceneScript exception"
        guard !executionLimiter.didTimeOut else { return }
        record(message)
    }

    func record(_ message: String) {
        exceptionCount += 1
        if exceptions.count < 32 {
            exceptions.append(message)
        }
        configuration.log(2, message)
    }

    func write(_ input: Input) {
        globals[2] = input.timeOfDay
        globals[7] = input.cursorScreen.x
        globals[8] = input.cursorScreen.y
        globals[9] = input.cursorWorld.x
        globals[10] = input.cursorWorld.y
        globals[11] = input.cursorWorld.z
        globals[12] = input.leftDown ? 1 : 0
    }

    @discardableResult
    func evaluateScript(_ source: String, withSourceURL url: URL?) -> JSValue? {
        guard executionLimiter.prepareInvocation(in: context) else { return nil }
        return context.evaluateScript(source, withSourceURL: url)
    }

    @discardableResult
    func invokeHost(_ name: String, withArguments arguments: [Any]) -> JSValue? {
        guard executionLimiter.prepareInvocation(in: context) else { return nil }
        return host.invokeMethod(name, withArguments: arguments)
    }

    func callJavaScript(_ function: JSValue?, withArguments arguments: [Any]) -> JSValue? {
        guard executionLimiter.prepareInvocation(in: context) else { return nil }
        return function?.call(withArguments: arguments)
    }

    /// Every JS entry, including mirror/flush getters and reentrant native callbacks, shares this outer budget.
    func withExecutionBudget(_ operation: ExecutionOperation, _ body: () -> Void) {
        guard executionFailure == nil else { return }
        let limits = configuration.executionLimits
        let seconds = operation == .setup || operation == .initialize ? limits.setupSeconds : limits.callbackSeconds
        guard executionLimiter.perform(in: context, seconds: seconds, body) else {
            if executionFailure == nil {
                let failure = Failure.executionTimedOut(operation: operation, seconds: seconds)
                executionFailure = failure
                record(failure.localizedDescription)
            }
            return
        }
    }

    /// A terminated callback never flushes its unfinished slot writes, and this VM can never run again.
    func run(state: inout WPEParitySceneState, operation: ExecutionOperation = .event, _ body: () -> Void) {
        withExecutionBudget(operation) {
            mirror(state)
            guard !executionLimiter.didTimeOut else { return }
            withUnsafeMutablePointer(to: &state) { pointer in
                let previous = activeState
                activeState = pointer
                defer { activeState = previous }
                body()
            }
            guard !executionLimiter.didTimeOut else { return }
            flushWrites(to: &state)
        }
    }

    func flushWrites(to state: inout WPEParitySceneState) {
        // State changed since the last mirror or flush by a writer other than this flush: those slots are stale.
        if mirroredGenerations != MirroredGenerations(state) {
            mirroredGenerations = nil
        }
        let count = Int(dirty[0])
        // Typed-array capacity includes spare slots. Authored wrapper metadata can address that storage, but
        // only the registered native slot table admits a write. Never trust the JS dirty queue for pointer access.
        guard count >= 0, count <= capacity else {
            dirty[0] = 0
            dirtyFlags.update(repeating: 0, count: capacity)
            mirroredGenerations = nil
            return
        }
        if count > 0 {
            for entry in 1 ... count {
                let slot = Int(dirty[entry])
                guard slots.indices.contains(slot) else {
                    if slot >= 0, slot < capacity {
                        dirtyFlags[slot] = 0
                    }
                    continue
                }
                dirtyFlags[slot] = 0
                flushedSlots.append(slot)
                apply(slot: slot, to: &state)
            }
            dirty[0] = 0
        }
        if mirroredGenerations != nil {
            mirroredGenerations = MirroredGenerations(state)
        }
    }

    struct MirroredGenerations: Equatable {
        let effects: Int
        let constants: Int
        let fields: Int

        init(_ state: WPEParitySceneState) {
            (effects, constants, fields) = (state.effectVisibilityGeneration, state.constantsGeneration,
                                            state.scriptFieldsGeneration)
        }
    }

    func mirror(_ state: WPEParitySceneState) {
        mirroredEntries = 0
        if mirroredMembershipGeneration != state.membershipGeneration {
            // A temporary projection of the existing wrapper slots; neither State nor Engine slots are reordered.
            let indices = Dictionary(layers.enumerated().map { ($0.element.id, $0.offset) }) { first, _ in first }
            invokeHost("setCommonOrder", withArguments: [state.commonOrder.compactMap { indices[$0] }])
            mirroredMembershipGeneration = state.membershipGeneration
        }
        let plan = mirrorPlan ?? makeMirrorPlan()
        mirrorPlan = plan
        let current = MirroredGenerations(state)
        let effects = mirroredGenerations?.effects != current.effects
        let constants = mirroredGenerations?.constants != current.constants
        let fields = mirroredGenerations?.fields != current.fields
        // Module bodies run in the convenience init outside `run`; their unflushed writes must win over State.
        for (id, entries) in plan.objects {
            mirroredEntries += entries.count
            guard let object = state.object(id) else { continue }
            for (slot, property) in entries where dirtyFlags[slot] == 0 {
                store(Self.value(property, of: object), at: slot)
            }
        }
        if effects {
            mirroredEntries += plan.effects.count
            for entry in plan.effects where dirtyFlags[entry.slot] == 0 {
                mirror(entry, from: state)
            }
        }
        if constants {
            for (key, entries) in plan.constants {
                mirroredEntries += entries.count
                guard let pass = state.passIndex(of: key) else { continue }
                let values = state.constants(pass: pass)
                for (slot, name) in entries where dirtyFlags[slot] == 0 {
                    if let constant = values[name] {
                        store(constant.value, at: slot)
                    }
                }
            }
        }
        if fields {
            mirroredEntries += plan.fields.count
            for entry in plan.fields where dirtyFlags[entry.slot] == 0 {
                mirror(entry, from: state)
            }
        }
        // State compares -0 equal to 0 and canonically equal strings as equal, so it can keep a value whose bits
        // differ from the slot a script wrote; a skipped category still restores those slots.
        for slot in flushedSlots where dirtyFlags[slot] == 0 {
            guard let entry = plan.entries[slot] else { continue }
            switch entry {
            case .effect where !effects, .constant where !constants, .field where !fields:
                mirroredEntries += 1
                mirror(entry, from: state)
            default:
                break
            }
        }
        flushedSlots.removeAll(keepingCapacity: true)
        mirroredGenerations = current
        sendStrings()
    }

    /// `refresh` grouped for `mirror`: object entries by layer and constant entries by pass, in first-seen order.
    struct MirrorPlan {
        var objects: [(id: String, entries: [(slot: Int, property: WPEParitySceneState.Property)])] = []
        var effects: [Refresh] = []
        var constants: [(key: WPEParityMaterialPassKey, entries: [(slot: Int, name: String)])] = []
        var fields: [Refresh] = []
        /// Effect, constant and field entries by slot.
        var entries: [Int: Refresh] = [:]
    }

    private func makeMirrorPlan() -> MirrorPlan {
        var plan = MirrorPlan()
        var objectGroups: [String: Int] = [:]
        var constantGroups: [WPEParityMaterialPassKey: Int] = [:]
        for entry in refresh {
            switch entry {
            case let .object(slot, objectID, property):
                let group = objectGroups[objectID] ?? plan.objects.count
                if group == plan.objects.count {
                    objectGroups[objectID] = group
                    plan.objects.append((objectID, []))
                }
                plan.objects[group].entries.append((slot, property))
            case .effect:
                plan.effects.append(entry)
                plan.entries[entry.slot] = entry
            case let .constant(slot, key, name):
                plan.entries[slot] = entry
                let group = constantGroups[key] ?? plan.constants.count
                if group == plan.constants.count {
                    constantGroups[key] = group
                    plan.constants.append((key, []))
                }
                plan.constants[group].entries.append((slot, name))
            case .field:
                plan.fields.append(entry)
                plan.entries[entry.slot] = entry
            }
        }
        return plan
    }

    /// `WPEParitySceneState.value(_:of:)` of an already looked-up object.
    private static func value(_ property: WPEParitySceneState.Property,
                              of object: WPEParitySceneState.Object) -> SIMD4<Float> {
        switch property {
        case .origin: SIMD4(object.origin, 0)
        case .scale: SIMD4(object.scale, 0)
        case .angles: SIMD4(object.angles, 0)
        case .alpha: SIMD4(object.alpha, 0, 0, 0)
        case .color: SIMD4(object.color, 0)
        case .brightness: SIMD4(object.brightness, 0, 0, 0)
        case .visible: SIMD4(object.visible ? 1 : 0, 0, 0, 0)
        }
    }

    private func mirror(_ entry: Refresh, from state: WPEParitySceneState) {
        switch entry {
        case let .object(slot, objectID, property):
            if let value = state.value(property, of: objectID) {
                store(value, at: slot)
            }
        case let .effect(slot, key):
            if let visible = state.isEffectVisible(key.effectID, of: key.objectID) {
                floats[slot * 4] = visible ? 1 : 0
            }
        case let .constant(slot, key, name):
            if let constant = state.constant(name, of: key) {
                store(constant.value, at: slot)
            }
        case let .field(slot, objectID, name):
            if let value = state.scriptField(name, of: objectID) {
                store(value, at: slot)
            }
        }
    }

    private func store(_ value: SIMD4<Float>, at slot: Int) {
        let base = floats + slot * 4
        base[0] = value.x
        base[1] = value.y
        base[2] = value.z
        base[3] = value.w
    }

    func store(_ value: WPEParitySceneState.ScriptValue, at slot: Int) {
        switch value {
        case let .vector(vector): store(vector, at: slot)
        case let .integer(integer): integers[slot] = integer
        case let .string(string):
            if host != nil {
                pendingStrings.append((slot, string))
            }
        }
    }

    /// Writes every string `store` queued into the VM with one call.
    func sendStrings() {
        guard !pendingStrings.isEmpty else { return }
        let vm = context.jsGlobalContextRef
        // Protected while it is built: values referenced only from Swift memory are invisible to the collector.
        let entries = JSObjectMakeArray(vm, 0, nil, nil)
        JSValueProtect(vm, entries)
        defer { JSValueUnprotect(vm, entries) }
        var count: UInt32 = 0
        func append(_ value: JSValueRef?) {
            JSObjectSetPropertyAtIndex(vm, entries, count, value, nil)
            count += 1
        }
        for (slot, string) in pendingStrings {
            append(JSValueMakeNumber(vm, Double(slot)))
            append(Self.makeString(vm, string))
            if let values = descriptors[Int(slots[slot].descriptor)].stringValues {
                let list = JSObjectMakeArray(vm, 0, nil, nil)
                append(list)
                for (index, value) in values.enumerated() {
                    JSObjectSetPropertyAtIndex(vm, list, UInt32(index), Self.makeString(vm, value), nil)
                }
            } else {
                append(JSValueMakeNull(vm))
            }
        }
        pendingStrings.removeAll(keepingCapacity: true)
        var argument: JSValueRef? = entries
        var exception: JSValueRef?
        guard executionLimiter.prepareInvocation(in: context) else { return }
        JSObjectCallAsFunction(vm, setStringsFunction.jsValueRef, nil, 1, &argument, &exception)
        if let exception, !executionLimiter.didTimeOut {
            recordException(JSValue(jsValueRef: exception, in: context))
        }
    }

    private static func makeString(_ vm: JSContextRef?, _ string: String) -> JSValueRef? {
        let text = JSStringCreateWithCFString(string as CFString)
        defer { JSStringRelease(text) }
        return JSValueMakeString(vm, text)
    }

    func seedMissingFields(state: inout WPEParitySceneState, first: Int = 0) {
        for (slotIndex, value) in initialValues.dropFirst(first) {
            let slot = slots[slotIndex]
            let descriptor = descriptors[Int(slot.descriptor)]
            guard descriptor.target == .field else { continue }
            let objectID = slot.layer < 0 ? "" : layers[Int(slot.layer)].id
            let name = fieldName(slot: slotIndex)
            guard state.scriptField(name, of: objectID) == nil else { continue }
            state.setScriptField(name, of: objectID, to: value, invalidating: descriptor.invalidation)
        }
    }

    func fieldName(slot index: Int) -> String {
        let slot = slots[index]
        let name = descriptors[Int(slot.descriptor)].fieldName
        return slot.animationLayer >= 0 ? "animationlayers.\(slot.animationLayer).\(name)" : name
    }

    private func apply(slot index: Int, to state: inout WPEParitySceneState) {
        let slot = slots[index]
        let descriptor = descriptors[Int(slot.descriptor)]
        let base = floats + index * 4
        let value = SIMD4(base[0], base[1], base[2], base[3])
        let layer = slot.layer >= 0 ? layers[Int(slot.layer)] : nil
        guard layer.map({ state.isAlive($0.id) }) ?? true else {
            mirroredGenerations = nil
            return
        }
        switch descriptor.target {
        case let .object(property):
            if let id = layer?.id, let stateIndex = state.index(of: id) {
                state.set(property, at: stateIndex, to: value)
            }
        case .effectVisible:
            if slot.effect >= 0 {
                let key = effectKeys[Int(slot.effect)]
                state.setEffect(key.effectID, of: key.objectID, visible: value.x != 0)
            }
        case .constant:
            if let key = slot.materialPass {
                state.setConstant(descriptor.name, of: key,
                                  to: WPEParitySceneState.Constant(value: value,
                                                                   count: descriptor.type.componentCount))
            }
        case .field:
            let stored: WPEParitySceneState.ScriptValue = switch descriptor.type {
            case .string: .string(invokeHost("getString", withArguments: [index])?.toString() ?? "")
            case .int: .integer(integers[index])
            default: .vector(value)
            }
            state.setScriptField(fieldName(slot: index), of: layer?.id ?? "", to: stored,
                                 invalidating: descriptor.invalidation)
        }
    }

    /// Uses this layer's existing descriptor layout, not a second sound/slot registry.
    private func soundFields(layer index: Int) -> SoundFields? {
        let layer = layers[index]
        guard layer.kind == .sound else { return nil }
        let fields = fields(layer.kind)
        func value(_ name: String) -> Float? {
            guard let relative = fields.firstIndex(where: {
                $0.owner == .sound && $0.name == name && $0.type == .float && $0.target == .field
            }) else { return nil }
            return floats[(layer.base + relative) * 4]
        }
        guard let volume = value("volume") else { return nil }
        return SoundFields(volume: volume, minTime: value("mintime"), maxTime: value("maxtime"))
    }

    func soundVolumeWritten(slot value: Double) {
        guard let consume = soundVolumeConsumer, let slot = Self.checkedLayerIndex(value, count: slots.count),
              descriptors[Int(slots[slot].descriptor)].isSoundVolumeWrite,
              let layer = Self.checkedLayerIndex(Double(slots[slot].layer), count: layers.count),
              let state = activeState, state.pointee.isAlive(layers[layer].id) else { return }
        // The accepted setter already stored its Float, including equal writes. Prior writes must be visible
        // to the native hook, while this flush must not synthesize additional accepted-write events.
        flushWrites(to: &state.pointee)
        guard let fields = soundFields(layer: layer) else { return }
        consume(layers[layer].id, fields)
    }

    func soundCommand(layer value: Double, command raw: Double) -> Bool {
        guard let layer = Self.checkedLayerIndex(value, count: layers.count), layers[layer].kind == .sound,
              let raw = Int(exactly: raw), let command = SoundCommand(rawValue: raw) else { return false }
        if let state = activeState {
            guard state.pointee.isAlive(layers[layer].id) else { return false }
            flushWrites(to: &state.pointee)
        }
        guard let consume = soundCommandConsumer, let fields = soundFields(layer: layer) else {
            configuration.log(1, "ISound methods are unsupported without a synchronous product sound consumer")
            return false
        }
        return consume(layers[layer].id, command, fields)
    }
}
