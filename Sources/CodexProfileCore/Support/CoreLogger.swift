import Foundation

public enum CoreLogLevel: String {
    case info = "INFO"
    case warning = "WARN"
    case error = "ERROR"
}

public enum CoreLogger {
    public typealias Sink = @Sendable (CoreLogLevel, String, [String: String]) -> Void

    private static let lock = NSLock()
    private static var sink: Sink?

    public static func configure(sink: Sink?) {
        self.lock.lock()
        self.sink = sink
        self.lock.unlock()
    }

    public static func info(_ message: String, metadata: [String: String] = [:]) {
        self.write(level: .info, message: message, metadata: metadata)
    }

    public static func warning(_ message: String, metadata: [String: String] = [:]) {
        self.write(level: .warning, message: message, metadata: metadata)
    }

    public static func error(_ message: String, metadata: [String: String] = [:]) {
        self.write(level: .error, message: message, metadata: metadata)
    }

    private static func write(level: CoreLogLevel, message: String, metadata: [String: String]) {
        self.lock.lock()
        let sink = self.sink
        self.lock.unlock()
        sink?(level, message, metadata)
    }
}
