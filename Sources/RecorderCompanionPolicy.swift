import Foundation

enum RecorderCompanionPolicy {
    static func reminderPlan(enabled: Bool, authorized: Bool, eveningEnabled: Bool,
                             morningEnabled: Bool, nightPending: Bool, startedAt: Date?,
                             morningHour: Int, morningMinute: Int, now: Date,
                             calendar: Calendar = .current) -> (evening: Bool, morning: Date?) {
        guard enabled && authorized else { return (false, nil) }
        let morning = morningEnabled && nightPending ? startedAt.flatMap {
            morningReminder(startedAt: $0, hour: morningHour, minute: morningMinute, now: now, calendar: calendar)
        } : nil
        return (eveningEnabled && !nightPending, morning)
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
