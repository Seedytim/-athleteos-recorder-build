import Foundation
import Combine
import UserNotifications

@MainActor
final class RecorderNotifications: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var enabled: Bool { didSet { savePreferences() } }
    @Published var eveningEnabled: Bool { didSet { savePreferences() } }
    @Published var morningEnabled: Bool { didSet { savePreferences() } }
    @Published var eveningTime: Date { didSet { savePreferences() } }
    @Published var morningTime: Date { didSet { savePreferences() } }
    @Published private(set) var authorization: UNAuthorizationStatus = .notDetermined
    @Published private(set) var error: String?
    private let center = UNUserNotificationCenter.current()
    private let defaults = UserDefaults.standard
    private var nightPending = false
    private var nightStartedAt: Date?
    private var scheduleDirty = false
    private var scheduling = false
    private var sending = Set<String>()
    private static let reminderIDs = ["recorder.evening", "recorder.morning"]

    override init() {
        let d = UserDefaults.standard
        enabled = d.bool(forKey: "notifications.enabled")
        eveningEnabled = d.object(forKey: "notifications.evening") as? Bool ?? true
        morningEnabled = d.object(forKey: "notifications.morning") as? Bool ?? true
        func time(_ key: String, hour: Int) -> Date {
            let minutes = d.object(forKey: key) as? Int ?? hour * 60
            return Calendar.current.date(bySettingHour: minutes / 60, minute: minutes % 60, second: 0, of: Date()) ?? Date()
        }
        eveningTime = time("notifications.eveningTime", hour: 21)
        morningTime = time("notifications.morningTime", hour: 9)
        super.init()
        center.delegate = self
    }

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
        requestReschedule()
    }

    func enable() async {
        do {
            let allowed = try await center.requestAuthorization(options: [.alert, .sound])
            enabled = allowed
            error = allowed ? nil : "Notifications are off. You can allow them in iPhone Settings."
            await refreshAuthorization()
        } catch { self.error = error.localizedDescription }
    }

    func syncNight(pending: Bool, startedAt: Date?) {
        if pending && !nightPending {
            // Legacy/recovered sensor nights may not have a start timestamp. Keep
            // their first reminder anchor across launches instead of moving it.
            nightStartedAt = startedAt ?? defaults.object(forKey: "notifications.pendingAnchor") as? Date ?? Date()
            defaults.set(nightStartedAt, forKey: "notifications.pendingAnchor")
        }
        if !pending {
            nightStartedAt = nil
            defaults.removeObject(forKey: "notifications.pendingAnchor")
        }
        nightPending = pending
        requestReschedule()
    }

    private func savePreferences() {
        defaults.set(enabled, forKey: "notifications.enabled")
        defaults.set(eveningEnabled, forKey: "notifications.evening")
        defaults.set(morningEnabled, forKey: "notifications.morning")
        for (key, time) in [("notifications.eveningTime", eveningTime), ("notifications.morningTime", morningTime)] {
            let c = Calendar.current.dateComponents([.hour, .minute], from: time)
            defaults.set((c.hour ?? 0) * 60 + (c.minute ?? 0), forKey: key)
        }
        if !enabled { center.removeAllDeliveredNotifications() }
        requestReschedule()
    }

    // Serialize async notification-center writes. A preference/state change during
    // an add triggers another complete pass, so a stale add cannot win a race.
    private func requestReschedule() {
        scheduleDirty = true
        guard !scheduling else { return }
        scheduling = true
        Task {
            while scheduleDirty {
                scheduleDirty = false
                await replaceReminders()
            }
            scheduling = false
        }
    }

    private var allowed: Bool {
        enabled && (authorization == .authorized || authorization == .provisional || authorization == .ephemeral)
    }

    private func replaceReminders() async {
        center.removePendingNotificationRequests(withIdentifiers: Self.reminderIDs)
        let morning = Calendar.current.dateComponents([.hour, .minute], from: morningTime)
        let plan = RecorderCompanionPolicy.reminderPlan(enabled: enabled, authorized: allowed,
            eveningEnabled: eveningEnabled, morningEnabled: morningEnabled, nightPending: nightPending,
            startedAt: nightStartedAt, morningHour: morning.hour ?? 7, morningMinute: morning.minute ?? 0,
            now: Date())
        do {
            if plan.evening {
                let c = Calendar.current.dateComponents([.hour, .minute], from: eveningTime)
                try await center.add(UNNotificationRequest(identifier: "recorder.evening",
                    content: content("Ready for tonight?", "Put on your H10 and open Recorder to start your night."),
                    trigger: UNCalendarNotificationTrigger(dateMatching: c, repeats: true)))
            }
            if let date = plan.morning {
                let components = Calendar.current.dateComponents([.year, .month, .day, .hour, .minute], from: date)
                try await center.add(UNNotificationRequest(identifier: "recorder.morning",
                    content: content("Bring your night into AthleteOS", "Open Recorder and tap End night to save and archive your H10 recording."),
                    trigger: UNCalendarNotificationTrigger(dateMatching: components, repeats: false)))
            }
        } catch { self.error = "Could not schedule reminders: \(error.localizedDescription)" }
    }

    private func content(_ title: String, _ body: String) -> UNMutableNotificationContent {
        let c = UNMutableNotificationContent()
        c.title = title; c.body = body; c.sound = .default
        c.threadIdentifier = "athleteos-recorder"
        return c
    }

    /// Bounded persisted deduplication prevents retry/foreground notification spam.
    func event(key: String, title: String, body: String) async {
        guard allowed, !sending.contains(key) else { return }
        var sent = defaults.stringArray(forKey: "notifications.sent") ?? []
        guard !sent.contains(key) else { return }
        sending.insert(key)
        defer { sending.remove(key) }
        do {
            try await center.add(UNNotificationRequest(identifier: "recorder.event.\(key)",
                content: content(title, body), trigger: nil))
            // Reload after suspension: another event may have completed meanwhile.
            sent = defaults.stringArray(forKey: "notifications.sent") ?? []
            sent.append(key)
            defaults.set(Array(sent.suffix(100)), forKey: "notifications.sent")
        } catch { self.error = "Could not send notification: \(error.localizedDescription)" }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter,
        willPresent notification: UNNotification,
        withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }
}
