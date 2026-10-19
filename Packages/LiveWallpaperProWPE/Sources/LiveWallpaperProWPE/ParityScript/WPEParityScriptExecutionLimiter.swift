import Darwin
import JavaScriptCore

/// Direct-distribution Pro uses JavaScriptCore's watchdog SPI, resolved at runtime. There is no public JSC
/// interruption API. If either symbol is absent, the engine refuses to execute any authored JavaScript.
/// Thread-confined to the engine. The watchdog invokes its callback on the thread executing JavaScript.
final class WPEParityScriptExecutionLimiter {
    private typealias Terminate = @convention(c) (JSContextRef?, UnsafeMutableRawPointer?) -> Bool
    private typealias SetLimit = @convention(c) (JSContextGroupRef?, Double, Terminate?, UnsafeMutableRawPointer?) -> Void
    private typealias ClearLimit = @convention(c) (JSContextGroupRef?) -> Void

    private struct API: Sendable {
        let set: SetLimit
        let clear: ClearLimit

        static let available: Self? = {
            let symbols = UnsafeMutableRawPointer(bitPattern: -2) // Darwin RTLD_DEFAULT.
            guard let set = dlsym(symbols, "JSContextGroupSetExecutionTimeLimit"),
                  let clear = dlsym(symbols, "JSContextGroupClearExecutionTimeLimit") else { return nil }
            return Self(set: unsafeBitCast(set, to: SetLimit.self), clear: unsafeBitCast(clear, to: ClearLimit.self))
        }()
    }

    private let api: API
    private var depth = 0
    private var cpuDeadline = 0.0
    private(set) var didTimeOut = false

    init() throws {
        guard let api = API.available else { throw WPEParityScriptEngine.Failure.executionLimitUnavailable }
        self.api = api
    }

    /// Nested JS/native/JS calls retain the outer deadline; authored recursion cannot refresh its allowance.
    /// This interrupts JavaScript execution, including an uncatchable infinite loop; native host work must be bounded
    /// by its own admission rules and cannot be preempted by this watchdog.
    func perform(in context: JSContext, seconds: Double, _ body: () -> Void) -> Bool {
        guard !didTimeOut else { return false }
        if depth > 0 {
            body()
            return !didTimeOut
        }
        let group = JSContextGetGroup(context.jsGlobalContextRef)
        depth = 1
        cpuDeadline = Self.cpuTime() + seconds
        guard prepareInvocation(in: context) else { depth = 0; return false }
        defer {
            api.clear(group)
            depth = 0
        }
        body()
        if Self.cpuTime() >= cpuDeadline {
            didTimeOut = true
        }
        return !didTimeOut
    }

    /// JSC restarts its watchdog on each outer VM entry. Re-arm with the remaining batch CPU time so many
    /// finite callbacks, imports or getter conversions cannot each consume a fresh full allowance.
    func prepareInvocation(in context: JSContext) -> Bool {
        guard !didTimeOut, depth > 0 else { return false }
        let remaining = cpuDeadline - Self.cpuTime()
        guard remaining > 0 else { didTimeOut = true; return false }
        api.set(JSContextGetGroup(context.jsGlobalContextRef), remaining, { _, raw in
            guard let raw else { return true }
            Unmanaged<WPEParityScriptExecutionLimiter>.fromOpaque(raw).takeUnretainedValue().didTimeOut = true
            return true
        }, Unmanaged.passUnretained(self).toOpaque())
        return true
    }

    private static func cpuTime() -> Double {
        var value = timespec()
        clock_gettime(CLOCK_THREAD_CPUTIME_ID, &value)
        return Double(value.tv_sec) + Double(value.tv_nsec) / 1_000_000_000
    }
}
