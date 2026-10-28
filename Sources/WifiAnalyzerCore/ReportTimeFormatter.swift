import Foundation

/// Display wall-clock labels without changing the monotonic chart coordinates.
public struct ReportTimeFormatter {
    private let start: Date?
    private let clock: DateFormatter
    private let preciseClock: DateFormatter
    public var available: Bool { start != nil }

    public init(startedUTC: String, timeZone: TimeZone = .current) {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        let fractional = iso.date(from: startedUTC)
        iso.formatOptions = [.withInternetDateTime]
        start = fractional ?? iso.date(from: startedUTC)
        func formatter(_ format: String) -> DateFormatter {
            let value = DateFormatter()
            value.locale = Locale(identifier: "en_US_POSIX")
            value.timeZone = timeZone
            value.dateFormat = format
            return value
        }
        clock = formatter("HH:mm:ss")
        preciseClock = formatter("HH:mm:ss.S")
    }

    public func string(_ seconds: Double, clockTime: Bool, precise: Bool = false) -> String {
        if clockTime, let start {
            return (precise ? preciseClock : clock).string(from: start.addingTimeInterval(seconds))
        }
        return String(format: "%02d:%02d", Int(seconds) / 60, Int(seconds) % 60)
    }
}
