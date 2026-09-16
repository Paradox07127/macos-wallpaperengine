#if !LITE_BUILD
import CryptoKit
import Foundation
import Metal

/// Shares live libraries across renderers without extending their GPU lifetime.
final class WPEMetalLibraryRegistry: @unchecked Sendable { // every mutable field is read/written only inside `condition` (NSCondition) lock/unlock; compiles run outside it on immutable inputs
    struct Configuration: Hashable, Sendable {
        var languageVersion: MTLLanguageVersion = .version3_0
        var fastMathEnabled = true

        func makeOptions() -> MTLCompileOptions {
            let options = MTLCompileOptions()
            options.languageVersion = languageVersion
            if #available(macOS 15.0, *) {
                options.mathMode = fastMathEnabled ? .fast : .safe
                options.mathFloatingPointFunctions = fastMathEnabled ? .fast : .precise
            } else {
                options.fastMathEnabled = fastMathEnabled
            }
            return options
        }
    }

    typealias Compiler = @Sendable (MTLDevice, String, Configuration) throws -> MTLLibrary

    static let shared = WPEMetalLibraryRegistry()

    private struct Key: Hashable {
        let device: ObjectIdentifier
        let sourceDigest: SHA256.Digest
        let configuration: Configuration
    }

    private final class Entry {
        weak var device: MTLDevice?
        weak var library: MTLLibrary?
        var access: UInt64

        init(device: MTLDevice, library: MTLLibrary, access: UInt64) {
            self.device = device
            self.library = library
            self.access = access
        }
    }

    private final class Flight {
        var result: Result<MTLLibrary, Error>?
    }

    private let condition = NSCondition()
    private let capacity: Int
    private let compiler: Compiler
    private var entries: [Key: Entry] = [:]
    private var compiling: [Key: Flight] = [:]
    private var access: UInt64 = 0
    #if DEBUG
    private var waitingRequests = 0
    #endif

    init(capacity: Int = 128, compiler: @escaping Compiler = WPEMetalLibraryRegistry.compile) {
        self.capacity = max(1, capacity)
        self.compiler = compiler
    }

    func library(
        device: MTLDevice,
        source: String,
        configuration: Configuration = Configuration()
    ) throws -> MTLLibrary {
        let key = Key(
            device: ObjectIdentifier(device),
            sourceDigest: SHA256.hash(data: Data(source.utf8)),
            configuration: configuration
        )
        condition.lock()
        access &+= 1
        if let entry = entries[key], entry.device === device, let library = entry.library {
            entry.access = access
            condition.unlock()
            return library
        }
        if let flight = compiling[key] {
            #if DEBUG
            waitingRequests += 1
            #endif
            while flight.result == nil {
                condition.wait()
            }
            #if DEBUG
            waitingRequests -= 1
            #endif
            let result = flight.result!
            condition.unlock()
            return try result.get()
        }
        let flight = Flight()
        compiling[key] = flight
        condition.unlock()

        // Independent shader compiles must not hold the registry lock.
        do {
            let library = try compiler(device, source, configuration)
            condition.lock()
            entries = entries.filter { $0.value.library != nil && $0.value.device != nil }
            if entries.count >= capacity, let oldest = entries.min(by: { $0.value.access < $1.value.access }) {
                entries.removeValue(forKey: oldest.key)
            }
            access &+= 1
            entries[key] = Entry(device: device, library: library, access: access)
            flight.result = .success(library)
            compiling.removeValue(forKey: key)
            condition.broadcast()
            condition.unlock()
            return library
        } catch {
            condition.lock()
            flight.result = .failure(error)
            compiling.removeValue(forKey: key)
            condition.broadcast()
            condition.unlock()
            throw error
        }
    }

    private static func compile(
        device: MTLDevice,
        source: String,
        configuration: Configuration
    ) throws -> MTLLibrary {
        try device.makeLibrary(source: source, options: configuration.makeOptions())
    }

    #if DEBUG
    var waitingRequestCountForTesting: Int {
        condition.lock()
        defer { condition.unlock() }
        return waitingRequests
    }

    var entryCountForTesting: Int {
        condition.lock()
        defer { condition.unlock() }
        return entries.count
    }
    #endif
}
#endif
