import Foundation

enum BLELogLevel: String, Sendable {
    case info = "INFO"
    case success = "OK"
    case warning = "WARN"
    case error = "ERROR"
}

struct BLELogEntry: Identifiable, Sendable {
    let id = UUID()
    let timestamp: Date
    let level: BLELogLevel
    let message: String

    var timestampText: String {
        Self.formatter.string(from: timestamp)
    }

    private static let formatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
