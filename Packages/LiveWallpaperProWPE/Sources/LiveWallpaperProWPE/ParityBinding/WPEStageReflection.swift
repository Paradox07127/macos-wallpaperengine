import Foundation

public struct WPEStageReflection: Decodable, Sendable {
    public enum Stage: String, Decodable, Sendable {
        case vertex, fragment, geometry
    }

    public struct CBuffer: Decodable, Sendable {
        public struct Variable: Decodable, Sendable {
            public enum BaseType: String, Decodable, Sendable {
                case float, int, uint, bool
            }

            public enum VariableClass: String, Decodable, Sendable {
                case scalar, vector, matrix_rows, matrix_columns, `struct`
            }

            public let name: String
            public let offset: Int
            public let size: Int
            public let baseType: BaseType
            public let `class`: VariableClass
            public let rows: Int
            public let columns: Int
            public let elements: Int
            public let used: Bool

            public init(name: String, offset: Int, size: Int, baseType: BaseType,
                        class: VariableClass, rows: Int, columns: Int, elements: Int, used: Bool) {
                self.name = name
                self.offset = offset
                self.size = size
                self.baseType = baseType
                self.class = `class`
                self.rows = rows
                self.columns = columns
                self.elements = elements
                self.used = used
            }
        }

        public let name: String
        public let register: Int
        public let space: Int
        public let size: Int
        public let variables: [Variable]

        public init(name: String, register: Int, space: Int, size: Int, variables: [Variable]) {
            self.name = name
            self.register = register
            self.space = space
            self.size = size
            self.variables = variables
        }
    }

    public struct Resource: Decodable, Sendable {
        public enum Kind: String, Decodable, Sendable {
            case texture, sampler
        }

        public enum Dimension: String, Decodable, Sendable {
            case texture2D = "2d"
            case texture2DMS = "2dms"
            case texture3D = "3d"
            case cube
            case texture2DArray = "2darray"
            case none
        }

        public let name: String
        public let kind: Kind
        public let register: Int
        public let space: Int
        public let dimension: Dimension
        public let count: Int
        public let comparison: Bool?

        public init(name: String, kind: Kind, register: Int, space: Int,
                    dimension: Dimension, count: Int, comparison: Bool? = nil) {
            self.name = name
            self.kind = kind
            self.register = register
            self.space = space
            self.dimension = dimension
            self.count = count
            self.comparison = comparison
        }
    }

    public struct ArgumentEntry: Decodable, Sendable {
        public enum Kind: String, Decodable, Sendable, Hashable {
            case cbv, srv, sampler, uav
        }

        public let kind: Kind
        public let register: Int
        public let space: Int
        public let offset: Int
        public let size: Int

        public init(kind: Kind, register: Int, space: Int, offset: Int, size: Int) {
            self.kind = kind
            self.register = register
            self.space = space
            self.offset = offset
            self.size = size
        }
    }

    public struct StageAttribute: Decodable, Sendable {
        public let name: String
        public let index: Int
        public let elementType: String
        public let columns: Int
    }

    public let schema: Int
    public let stage: Stage
    public let entry: String
    public let cbuffers: [CBuffer]
    public let resources: [Resource]
    public let topLevelArgumentBuffer: [ArgumentEntry]
    public let vertexInputs: [StageAttribute]
    public let stageOutputs: [StageAttribute]
    public let mscReflection: [String: WPEReflectionJSONValue]

    public init(schema: Int = 1, stage: Stage, entry: String = "main", cbuffers: [CBuffer],
                resources: [Resource], topLevelArgumentBuffer: [ArgumentEntry],
                vertexInputs: [StageAttribute] = [], stageOutputs: [StageAttribute] = [],
                mscReflection: [String: WPEReflectionJSONValue] = [:]) {
        self.schema = schema
        self.stage = stage
        self.entry = entry
        self.cbuffers = cbuffers
        self.resources = resources
        self.topLevelArgumentBuffer = topLevelArgumentBuffer
        self.vertexInputs = vertexInputs
        self.stageOutputs = stageOutputs
        self.mscReflection = mscReflection
    }
}

public indirect enum WPEReflectionJSONValue: Decodable, Sendable, Equatable {
    case object([String: Self]), array([Self]), string(String)
    case integer(Int64), unsignedInteger(UInt64), number(Double), bool(Bool), null

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else if let value = try? container.decode(Int64.self) {
            self = .integer(value)
        } else if let value = try? container.decode(UInt64.self) {
            self = .unsignedInteger(value)
        } else if let value = try? container.decode(Double.self) {
            self = .number(value)
        } else if let value = try? container.decode([Self].self) {
            self = .array(value)
        } else {
            self = try .object(container.decode([String: Self].self))
        }
    }
}

public enum WPEParityBindingError: Error, Sendable, Equatable {
    case invalidLayout(String)
    case unsupportedVariable(String)
    case unknownVariable(String)
    case shapeMismatch(String)
    case typeMismatch(String)
    case invalidBinding(String)
    case bufferTooSmall(required: Int, actual: Int)
}
