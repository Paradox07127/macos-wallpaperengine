import Foundation
import JavaScriptCore

/// 18162fd40/181630720: only converts the VM inputs. Model identity, phase, admission and GPU lifetime stay
/// with the existing host/resource transaction. Limits are supplied by that owner, not guessed native rules.
public enum WPEModelDataConverter {
    public enum Failure: Error, Equatable {
        case vertexBufferMissing, vertexFormatMissing, materialMissing, shapesMissing
        case shapeLimitExceeded, bufferLimitExceeded, invalidBufferView, javascriptException

        public var nativeMessage: String? {
            switch self {
            case .vertexBufferMissing: "Vertex buffer missing."
            case .vertexFormatMissing: "Vertex format missing."
            case .materialMissing: "Material missing."
            case .shapesMissing: "Shapes missing."
            default: nil
            }
        }
    }

    /// `resolveMaterial` is the existing binding-aware filename provider (181653460), including its native
    /// bounded string conversion. It has no identity fallback: registering/resolving assets is host-owned.
    public static func convert(
        _ input: JSValue, requireFields: Bool, maximumArrayEntries: Int, maximumBufferBytes: Int,
        resolveMaterial: (JSValue) throws -> Data
    ) throws -> WPEParityModelDataPatch {
        let array = try property(input, "shapes")
        let shapeArray = array?.isArray == true ? array : nil
        let count = try shapeArray.map { try Int(property($0, "length")?.toUInt32() ?? 0) } ?? 1
        guard count <= maximumArrayEntries else { throw Failure.shapeLimitExceeded }
        guard count > 0 else { throw Failure.shapesMissing }
        var remaining = maximumBufferBytes
        var shapes: [WPEParityModelDataShapePatch] = []
        shapes.reserveCapacity(count)
        for index in 0 ..< count {
            let value = try shapeArray.map { try element($0, index) } ?? input
            try shapes.append(shape(value, requireFields: requireFields, maximumArrayEntries: maximumArrayEntries,
                                    remaining: &remaining, resolveMaterial: resolveMaterial))
        }
        let minimum = try property(input, "boundingBoxMins")
        // The native outer converter does not read maxs unless mins is an object.
        let maximum = minimum?.isObject == true ? try property(input, "boundingBoxMaxs") : nil
        let bounds: WPEPuppetMeshBounds? = if let minimum, let maximum, minimum.isObject, maximum.isObject {
            try WPEPuppetMeshBounds(minimum: vector(minimum), maximum: vector(maximum))
        } else {
            nil
        }
        return WPEParityModelDataPatch(shapes: shapes, bounds: bounds)
    }

    private static func shape(
        _ value: JSValue, requireFields: Bool, maximumArrayEntries: Int, remaining: inout Int,
        resolveMaterial: (JSValue) throws -> Data
    ) throws -> WPEParityModelDataShapePatch {
        var result = WPEParityModelDataShapePatch()
        guard value.isObject else {
            result.remove = value.isNull
            return result
        }
        if let buffer = try property(value, "vertexBuffer") {
            result.vertices = try bytes(buffer, type: kJSTypedArrayTypeFloat32Array, width: 4, remaining: &remaining)
        }
        if requireFields, result.vertices == nil {
            throw Failure.vertexBufferMissing
        }
        if let buffer = try property(value, "indexBuffer") {
            if let data = try bytes(buffer, type: kJSTypedArrayTypeUint16Array, width: 2, remaining: &remaining) {
                result.indices = .buffer(.init(data: data, elementWidth: .uint16))
            } else if let data = try bytes(buffer, type: kJSTypedArrayTypeUint32Array, width: 4, remaining: &remaining) {
                result.indices = .buffer(.init(data: data, elementWidth: .uint32))
            } else if buffer.isNull {
                result.indices = .remove
            }
        }
        if let format = try property(value, "vertexFormat"), format.isArray {
            let count = try Int(property(format, "length")?.toUInt32() ?? 0)
            guard count <= maximumArrayEntries else { throw Failure.shapeLimitExceeded }
            for index in 0 ..< count {
                let item = try element(format, index)
                guard item.isString else { break }
                let name = item.toString()?.split(separator: "\0", maxSplits: 1, omittingEmptySubsequences: false).first
                switch name {
                case "position": result.vertexFormat |= 1
                case "normal": result.vertexFormat |= 2
                case "tangentSigned": result.vertexFormat |= 4
                case "uv": result.vertexFormat |= 8
                case "color": result.vertexFormat |= 0x8000
                default: break
                }
            }
        }
        if requireFields, result.vertexFormat == 0 {
            throw Failure.vertexFormatMissing
        }
        if let material = try property(value, "material"), material.isString {
            result.material = try resolveMaterial(material)
        } else if requireFields {
            throw Failure.materialMissing
        }
        if let flag = try property(value, "isVertexBufferDynamic"), flag.isBoolean {
            result.isVertexBufferDynamic = flag.toBool()
        }
        if let flag = try property(value, "isIndexBufferDynamic"), flag.isBoolean {
            result.isIndexBufferDynamic = flag.toBool()
        }
        return result
    }

    private static func property(_ value: JSValue, _ key: String) throws -> JSValue? {
        let result = value.objectForKeyedSubscript(key)
        guard let context = value.context, context.exception == nil else { throw Failure.javascriptException }
        return result
    }

    private static func element(_ value: JSValue, _ index: Int) throws -> JSValue {
        let result = value.atIndex(index)
        guard let context = value.context, context.exception == nil, let result else { throw Failure.javascriptException }
        return result
    }

    private static func vector(_ value: JSValue) throws -> SIMD3<Float> {
        var result = SIMD3<Float>.zero
        for (index, key) in ["x", "y", "z"].enumerated() {
            if let component = try property(value, key), component.isNumber {
                result[index] = Float(component.toDouble())
            }
        }
        return result
    }

    private static func bytes(
        _ value: JSValue, type: JSTypedArrayType, width: Int, remaining: inout Int
    ) throws -> Data? {
        guard let context = value.context, let ref = context.jsGlobalContextRef else { throw Failure.javascriptException }
        var exception: JSValueRef?
        let actual = JSValueGetTypedArrayType(ref, value.jsValueRef, &exception)
        try check(exception, context)
        guard actual == type else { return nil }
        let object = JSValueToObject(ref, value.jsValueRef, &exception)
        try check(exception, context)
        guard let object else { throw Failure.invalidBufferView }
        let count = JSObjectGetTypedArrayLength(ref, object, &exception)
        try check(exception, context)
        let offset = JSObjectGetTypedArrayByteOffset(ref, object, &exception)
        try check(exception, context)
        let (length, overflow) = count.multipliedReportingOverflow(by: width)
        guard !overflow, length <= remaining else { throw Failure.bufferLimitExceeded }
        let buffer = JSObjectGetTypedArrayBuffer(ref, object, &exception)
        try check(exception, context)
        guard let buffer else { throw Failure.invalidBufferView }
        let capacity = JSObjectGetArrayBufferByteLength(ref, buffer, &exception)
        try check(exception, context)
        guard offset <= capacity, length <= capacity - offset else { throw Failure.invalidBufferView }
        remaining -= length
        if length == 0 {
            return Data()
        }
        let base = JSObjectGetArrayBufferBytesPtr(ref, buffer, &exception)
        try check(exception, context)
        guard let base else { throw Failure.invalidBufferView }
        // No further VM call while this borrowed pointer is used. The transaction receives one owned copy.
        return Data(bytes: base + offset, count: length)
    }

    private static func check(_ exception: JSValueRef?, _ context: JSContext) throws {
        if let exception {
            context.exception = JSValue(jsValueRef: exception, in: context)
            throw Failure.javascriptException
        }
    }
}
