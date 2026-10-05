import Foundation
import os

public final class Logger {
    // MARK: - Log Categories

    public enum Category: String, CaseIterable, Sendable {
        case general = "General"
        case screenManager = "ScreenManager"
        case videoPlayer = "VideoPlayer"
        case powerMonitor = "PowerMonitor"
        case fileAccess = "FileAccess"
        case settings = "Settings"
        case ui = "UserInterface"
        case performance = "Performance"
        case startup = "Startup"
        case lifecycle = "Lifecycle"
        case memory = "Memory"
        case wpeRender = "WPERender"
        case audioCapture = "AudioCapture"
        case workshop = "Workshop"
        case updates = "Updates"

        public static let subsystem = "com.livewallpaper"

        /// Cached to avoid per-call subsystem string interning.
        fileprivate var logger: os.Logger {
            LoggerCache.shared.entry(for: self).logger
        }

        fileprivate var osLog: OSLog {
            LoggerCache.shared.entry(for: self).osLog
        }
    }

    // MARK: - Log Levels

    public enum Level: Sendable {
        case debug, info, notice, warning, error, fault

        public var prefix: String {
            switch self {
            case .debug:    return "🔍"
            case .info:     return "ℹ️"
            case .notice:   return "📢"
            case .warning:  return "⚠️"
            case .error:    return "❌"
            case .fault:    return "🔥"
            }
        }

        fileprivate var osLogType: OSLogType {
            switch self {
            case .debug:    return .debug
            case .info:     return .info
            case .notice:   return .default
            case .warning:  return .default
            case .error:    return .error
            case .fault:    return .fault
            }
        }
    }

    // MARK: - Core Logging

    /// `@autoclosure` defers string interpolation; the message is only evaluated when this level is actually being logged.

    public static func log(
        _ message: @autoclosure () -> String,
        category: Category,
        level: Level = .info,
        file: String = #file,
        function: String = #function,
        line: Int = #line
    ) {
        emit(message, category: category, level: level, file: file, function: function, line: line)
    }

    /// Persistent log file path users can `tail -f`. `nil` only if the
    /// `~/Library/Logs/LiveWallpaper/` directory could not be created.
    public static var persistentLogFileURL: URL? {
        LogFileSink.shared.fileURL
    }

    /// Single rendering boundary for both unified and persistent logs. Keep
    /// this pure so privacy behavior remains testable without scraping Console.
    static func sanitizedBody(_ message: String) -> String {
        LogPrivacyRedactor.scrub(message)
    }

    struct SanitizedMessage {
        let text: String

        init(_ raw: String) {
            text = Logger.sanitizedBody(raw)
        }
    }

    // MARK: - Convenience Methods

    public static func debug(_ message: @autoclosure () -> String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        emit(message, category: category, level: .debug, file: file, function: function, line: line)
        #endif
    }

    public static func info(_ message: @autoclosure () -> String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        emit(message, category: category, level: .info, file: file, function: function, line: line)
    }

    public static func notice(_ message: @autoclosure () -> String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        emit(message, category: category, level: .notice, file: file, function: function, line: line)
    }

    public static func warning(_ message: @autoclosure () -> String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        emit(message, category: category, level: .warning, file: file, function: function, line: line)
    }

    public static func error(_ message: @autoclosure () -> String, category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        emit(message, category: category, level: .error, file: file, function: function, line: line)
    }

    private static func emit(
        _ message: () -> String,
        category: Category,
        level: Level,
        file: String,
        function: String,
        line: Int
    ) {
        #if !DEBUG
        if level == .debug { return }
        #endif
        guard shouldEvaluate(level, category: category) else { return }

        let fileName = (file as NSString).lastPathComponent
        let sanitized = SanitizedMessage(message())
        let body = sanitized.text
        category.logger.log(
            level: level.osLogType,
            "\(level.prefix, privacy: .public) [\(fileName, privacy: .public):\(line, privacy: .public)] \(function, privacy: .public) - \(body, privacy: .public)"
        )
        LogFileSink.shared.record(
            category: category,
            level: level,
            message: sanitized,
            file: file,
            line: line
        )
    }

    static func shouldEvaluate(_ level: Level, category: Category) -> Bool {
        switch level {
        case .notice, .warning, .error, .fault:
            return true
        case .info, .debug:
            return category.osLog.isEnabled(type: level.osLogType)
        }
    }

    // MARK: - Lifecycle Logging

    struct AuthoredErrorBudget {
        enum Admission: Equatable {
            case message(suppressed: Int)
            case suppressionStarted
        }

        private var windowStart: TimeInterval = -.infinity
        private var keys: Set<Int> = []
        private var suppressedCount = 0

        mutating func admit(key: Int, at now: TimeInterval) -> Admission? {
            var previousSuppressed = 0
            if now - windowStart >= 10 {
                previousSuppressed = suppressedCount
                windowStart = now
                keys.removeAll(keepingCapacity: true)
                suppressedCount = 0
            }
            guard keys.count < 20, keys.insert(key).inserted else {
                suppressedCount += 1
                return suppressedCount == 1 ? .suppressionStarted : nil
            }
            return .message(suppressed: previousSuppressed)
        }
    }

    private static let authoredErrorBudget = OSAllocatedUnfairLock(initialState: AuthoredErrorBudget())

    public enum RepeatedWarningSource: String, Sendable {
        case bookmarkResolution, sceneSpanPresent, soundEngineStart
    }

    private static let repeatedWarningBudgets = OSAllocatedUnfairLock(initialState: [RepeatedWarningSource: AuthoredErrorBudget]())

    public static func repeatedWarning(
        _ message: String, source: RepeatedWarningSource, category: Category,
        file: String = #file, function: String = #function, line: Int = #line
    ) {
        let admission = repeatedWarningBudgets.withLock {
            $0[source, default: AuthoredErrorBudget()].admit(key: message.hashValue, at: ProcessInfo.processInfo.systemUptime)
        }
        switch admission {
        case let .message(suppressed):
            if suppressed > 0 {
                warning("\(source.rawValue): suppressed \(suppressed) repeated/excess messages", category: category, file: file, function: function, line: line)
            }
            warning(message, category: category, file: file, function: function, line: line)
        case .suppressionStarted:
            warning("\(source.rawValue): repeated/excess messages suppressed; budget is 20 distinct messages per 10 seconds", category: category, file: file, function: function, line: line)
        case nil:
            break
        }
    }

    public static func authoredScriptError(_ message: String) {
        let admission = authoredErrorBudget.withLock {
            $0.admit(key: message.hashValue, at: ProcessInfo.processInfo.systemUptime)
        }
        switch admission {
        case let .message(suppressed):
            if suppressed > 0 {
                warning("SceneScript console.error: suppressed \(suppressed) messages in the previous logging window", category: .wpeRender)
            }
            error("SceneScript console.error: \(message)", category: .wpeRender)
        case .suppressionStarted:
            warning("SceneScript console.error: repeated/excess messages suppressed; budget is 20 distinct messages per 10 seconds", category: .wpeRender)
        case nil:
            break
        }
    }

    public static func functionStart(category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log("Started", category: category, level: .debug, file: file, function: function, line: line)
        #endif
    }

    public static func functionEnd(category: Category = .general, file: String = #file, function: String = #function, line: Int = #line) {
        #if DEBUG
        log("Finished", category: category, level: .debug, file: file, function: function, line: line)
        #endif
    }

    // MARK: - Domain-Specific Logging

    /// Last reported screen count, so a wake/reconnect storm that re-detects the
    /// same displays does not repeat the line into the user's runtime log.
    private static let lastReportedScreenCount = OSAllocatedUnfairLock<Int?>(initialState: nil)

    /// `true` only when `count` differs from the previous call, which also records it.
    static func shouldReportScreenCount(_ count: Int) -> Bool {
        lastReportedScreenCount.withLock { last in
            guard last != count else { return false }
            last = count
            return true
        }
    }

    #if DEBUG
    static func resetScreenCountGateForTesting() {
        lastReportedScreenCount.withLock { $0 = nil }
    }
    #endif

    public static func screensDetected(_ count: Int, file: String = #file, function: String = #function, line: Int = #line) {
        guard shouldReportScreenCount(count) else { return }
        log("Detected \(count) screens", category: .screenManager, level: .notice, file: file, function: function, line: line)
    }

    public static func powerSourceChanged(isOnBattery: Bool, level: Double?, file: String = #file, function: String = #function, line: Int = #line) {
        let source = isOnBattery ? "battery" : "AC power"
        var message = "Power source changed to \(source)"
        if let level = level, isOnBattery {
            message += " (level: \(Int(level * 100))%)"
        }
        log(message, category: .powerMonitor, level: .notice, file: file, function: function, line: line)
    }

    public static func settingsChanged(setting: String, value: Any, file: String = #file, function: String = #function, line: Int = #line) {
        log("Setting changed: \(setting) = \(value)", category: .settings, level: .info, file: file, function: function, line: line)
    }
}

// MARK: - Performance Measuring

public final class PerformanceTimer {
    private let startTime: CFAbsoluteTime
    private let description: String
    private let category: Logger.Category
    private let file: String
    private let function: String
    private let line: Int

    public init(description: String, category: Logger.Category = .performance, file: String = #file, function: String = #function, line: Int = #line) {
        self.startTime = CFAbsoluteTimeGetCurrent()
        self.description = description
        self.category = category
        self.file = file
        self.function = function
        self.line = line
        Logger.debug("⏱ \(description) - Started", category: category, file: file, function: function, line: line)
    }

    public func checkpoint(_ label: String) {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        Logger.debug("⏱ \(description) - Checkpoint '\(label)' at \(String(format: "%.4f", elapsed))s",
                   category: category, file: file, function: function, line: line)
    }

    deinit {
        let elapsed = CFAbsoluteTimeGetCurrent() - startTime
        Logger.debug("⏱ \(description) - Finished in \(String(format: "%.4f", elapsed))s",
                   category: category, file: file, function: function, line: line)
    }
}

// MARK: - Cache

/// Synchronous, thread-safe cache of `os.Logger` / `OSLog` pairs.
/// `@unchecked Sendable`: `lock` serializes `entries`; no other mutable state.
private final class LoggerCache: @unchecked Sendable {
    static let shared = LoggerCache()

    struct Entry {
        let logger: os.Logger
        let osLog: OSLog
    }

    private var entries: [Logger.Category: Entry] = [:]
    private let lock = NSLock()

    func entry(for category: Logger.Category) -> Entry {
        lock.lock()
        defer { lock.unlock() }
        if let cached = entries[category] { return cached }
        let entry = Entry(
            logger: os.Logger(subsystem: Logger.Category.subsystem, category: category.rawValue),
            osLog: OSLog(subsystem: Logger.Category.subsystem, category: category.rawValue)
        )
        entries[category] = entry
        return entry
    }
}
