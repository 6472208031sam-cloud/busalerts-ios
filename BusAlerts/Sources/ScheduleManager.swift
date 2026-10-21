import Foundation
import UserNotifications

/// Tracking schedule, ported from Android's ScheduleManager/ScheduleReceiver.
///
/// iOS LIMITATION (honest): iOS does not allow exact background execution
/// like Android's setAlarmClock(). An iOS app cannot wake itself up at 8:00 AM
/// and start GPS tracking with the phone locked. The closest iOS equivalent
/// is a local notification at the configured on-time saying "Tap to start
/// tracking" — tapping it opens the app (single page for both routes) and
/// starts the ride from the stored config for the tapped route. That is
/// what this class implements.
///
/// Android schedule semantics mirrored here: schedOn1/schedOff1 is the AM
/// window, schedOn2/schedOff2 the PM window (Toronto time, weekdays-only
/// option). iOS only implements the on-time tap-to-start; there is no
/// off-alarm (nothing to stop without user interaction).
final class ScheduleManager {
    static let shared = ScheduleManager()

    private let center = UNUserNotificationCenter.current()
    private let toronto = TimeZone(identifier: "America/Toronto")!
    private let idPrefix = "bus.sched."

    private init() {}

    /// Stores the per-page route config + schedule settings from the web page
    /// and (re)arms the notification triggers. Mirrors Android's
    /// applyScheduleSettings() — safe to call with no active ride.
    func apply(config: RideState) {
        let pageKey = config.page == "pm" ? "pm" : "am"
        LocationTracker.shared.schedLog("apply page=\(pageKey) enabled=\(config.schedEnabled) on1=\(config.schedOn1) on2=\(config.schedOn2) weekdaysOnly=\(config.schedWeekdaysOnly)")
        if let data = try? JSONSerialization.data(withJSONObject: config.toJSON()) {
            UserDefaults.standard.set(data, forKey: "busalerts_sched_config_" + pageKey)
        }
        let d = UserDefaults.standard
        d.set(config.schedEnabled, forKey: "busalerts_sched_enabled")
        d.set(config.schedOn1, forKey: "busalerts_sched_on1")
        d.set(config.schedOn2, forKey: "busalerts_sched_on2")
        d.set(config.schedWeekdaysOnly, forKey: "busalerts_sched_weekdays")
        schedule()
    }

    /// Full config JSON last saved for a page ("am"/"pm").
    func configJSON(forPage page: String) -> String? {
        let key = "busalerts_sched_config_" + (page == "pm" ? "pm" : "am")
        guard let data = UserDefaults.standard.data(forKey: key) else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// (Re)programs the start-time notifications from stored settings.
    func schedule() {
        LocationTracker.shared.schedLog("schedule() begin")
        removeAlarms()
        let d = UserDefaults.standard
        let enabled = d.bool(forKey: "busalerts_sched_enabled")
        let on1 = d.integer(forKey: "busalerts_sched_on1")
        let on2 = d.integer(forKey: "busalerts_sched_on2")
        let weekdaysOnly = d.bool(forKey: "busalerts_sched_weekdays")
        LocationTracker.shared.schedLog("stored enabled=\(enabled) on1=\(on1) on2=\(on2) weekdaysOnly=\(weekdaysOnly)")
        guard enabled else {
            LocationTracker.shared.schedLog("schedule SKIPPED: enabled=false")
            return
        }
        // Note: integer(forKey:) returns 0 when unset; fall back to defaults
        // (08:00 AM window, 15:30 PM window — same as Android).
        let morning = on1 > 0 ? on1 : 480
        let afternoon = on2 > 0 ? on2 : 930
        center.getNotificationSettings { settings in
            LocationTracker.shared.schedLog("notification authorizationStatus=\(settings.authorizationStatus.rawValue) (0=notDetermined 1=denied 2=authorized 3=provisional)")
        }
        center.requestAuthorization(options: [.alert, .sound]) { granted, error in
            LocationTracker.shared.schedLog("requestAuthorization granted=\(granted) error=\(error?.localizedDescription ?? "none")")
        }
        addStartAlarm(minutes: morning, page: "am", weekdaysOnly: weekdaysOnly, morning: true)
        addStartAlarm(minutes: afternoon, page: "pm", weekdaysOnly: weekdaysOnly, morning: false)
        verifyPending(after: "schedule")
    }

    /// Read-only check, ~1s later: what notifications are actually pending.
    private func verifyPending(after label: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
            guard let self = self else { return }
            self.center.getPendingNotificationRequests { reqs in
                let ids = reqs.map { $0.identifier }.filter { $0.hasPrefix(self.idPrefix) }.sorted()
                LocationTracker.shared.schedLog("pending after \(label): count=\(ids.count) ids=\(ids.joined(separator: ","))")
            }
        }
    }

    private func removeAlarms() {
        center.getPendingNotificationRequests { [weak self] reqs in
            guard let self = self else { return }
            let ids = reqs.map { $0.identifier }.filter { $0.hasPrefix(self.idPrefix) }
            LocationTracker.shared.schedLog("removeAlarms: found count=\(ids.count) ids=\(ids.sorted().joined(separator: ","))")
            self.center.removePendingNotificationRequests(withIdentifiers: ids)
        }
    }

    private func addStartAlarm(minutes: Int, page: String,
                              weekdaysOnly: Bool, morning: Bool) {
        LocationTracker.shared.schedLog("addStartAlarm page=\(page) minutes=\(minutes) weekdaysOnly=\(weekdaysOnly)")
        let content = UNMutableNotificationContent()
        content.title = "Bus Stop Alerts"
        content.body = morning
            ? "Time for the morning route — tap to start tracking."
            : "Time for the afternoon route — tap to start tracking."
        content.sound = .default
        content.userInfo = ["schedTab": page]

        var components = DateComponents()
        components.timeZone = toronto
        components.hour = (minutes / 60) % 24
        components.minute = minutes % 60

        if weekdaysOnly {
            // UNCalendarNotificationTrigger can't express Mon–Fri in one
            // trigger, so schedule five weekly ones.
            for weekday in 2...6 { // 1=Sun … 7=Sat
                var c = components
                c.weekday = weekday
                let trigger = UNCalendarNotificationTrigger(dateMatching: c, repeats: true)
                let req = UNNotificationRequest(
                    identifier: "\(idPrefix)\(page).\(weekday)",
                    content: content, trigger: trigger)
                center.add(req) { error in
                    if let error = error {
                        LocationTracker.shared.schedLog("add FAILED id=\(req.identifier) error=\(error.localizedDescription)")
                    } else {
                        LocationTracker.shared.schedLog("add OK id=\(req.identifier)")
                    }
                }
            }
        } else {
            let trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: true)
            let req = UNNotificationRequest(
                identifier: "\(idPrefix)\(page).daily",
                content: content, trigger: trigger)
            center.add(req) { error in
                if let error = error {
                    LocationTracker.shared.schedLog("add FAILED id=\(req.identifier) error=\(error.localizedDescription)")
                } else {
                    LocationTracker.shared.schedLog("add OK id=\(req.identifier)")
                }
            }
        }
    }
}
