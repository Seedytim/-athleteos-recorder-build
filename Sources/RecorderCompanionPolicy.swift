import Foundation

/// The widget never guesses recording state from a cached timeline. The host app
/// resolves its one-button action from the durable night state when it opens.
enum RecorderCompanionPolicy {
    static func isNightAction(_ url: URL) -> Bool {
        url.scheme?.lowercased() == "athleteos-recorder" &&
        url.host?.lowercased() == "night-action" &&
        (url.path.isEmpty || url.path == "/") && url.query == nil && url.fragment == nil
    }

    static func morningReminder(startedAt: Date, hour: Int, minute: Int,
                                now: Date, calendar: Calendar = .current) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute),
              let date = calendar.nextDate(after: startedAt,
                  matching: DateComponents(hour: hour, minute: minute),
                  matchingPolicy: .nextTime), date > now else { return nil }
        return date
    }
}

/// Covers the whole foreground action, including archive work, not only Bluetooth.
struct NightActionGate {
    private(set) var running = false
    private var lastFinished: Date?
    mutating func begin(now: Date = Date()) -> Bool {
        guard !running, lastFinished.map({ now.timeIntervalSince($0) >= 2 }) ?? true else { return false }
        running = true
        return true
    }
    mutating func finish(now: Date = Date()) { running = false; lastFinished = now }
}
