import Foundation
import CoreLocation
import UserNotifications
import AudioToolbox
import UIKit

/// Owns background GPS tracking, arrival detection, alert sound/vibration,
/// follower ntfy pushes and local notifications.
/// Port of Android's TrackingService (foreground service + wake lock).
/// On iOS the UIBackgroundModes=location capability keeps updates flowing
/// with the screen off — no wake lock concept exists.
///
/// Route model: one page (index.html) hosts both routes as tabs; the ride
/// config's `page` field names the route — "am" has 13 numbered stops,
/// "pm" has 16 stops S,0,01,02,A–L whose labels carry the AM number in
/// brackets (e.g. "Stop L (7)"). On load the page syncs with an active
/// native ride via getStatus() and adopts its tab, exactly like Android.
final class LocationTracker: NSObject {
    static let shared = LocationTracker()

    private let manager = CLLocationManager()
    private var ride: RideState?
    // Phase 4 (ENABLED): one-stop restore recovery. Armed ONLY in
    // restore() when a stored active ride resumes (restore is
    // launch-only, so this is inherently process-death-only). Evaluated
    // once on the first FRESH fix handleLocation processes, or logged
    // immediately at restore for the no-established-position / final-
    // stop cases. A progression verdict with recovery credit available
    // APPLIES the advance: stop N is marked reached+skipped silently
    // (the skipNext marking mechanics, applied directly — no arrival
    // popup, no arrival ntfy, no My Stop event, no on-bus synthesis),
    // the credit is spent, and the same fix then continues through the
    // normal sequential logic against the new next stop. At most ONE
    // stop is advanced per restore.
    private var recoveryPending: (rideId: String, route: String, nextIndex: Int,
                                  nextLabel: String, nextLat: Double, nextLng: Double,
                                  followingLabel: String, followingLat: Double, followingLng: Double)?
    private var nearCount = 0
    private var nearTargetIdx = -1
    /// v46: stamp (Toronto day + minute) of the last off-stop tick
    /// evaluation, so the location tick checks at most once a minute.
    private var lastOffCheckStamp = ""
    private var pendingConfig: String?
    // On-bus detection (AM only)
    private var checkpointProgress: [Int: Int] = [:]
    private var lastCpLogAt: Date = .distantPast
    private var onBusStop: String? = nil
    // On-bus detection checkpoints (AM only): 3 per stop at 50/100/150m
    // Format: (stopIdx, seq, lat, lng)
    private static let amCheckpoints: [(Int, Int, Double, Double)] = [
        (0, 0, 43.505625, -79.705961),
        (0, 1, 43.505888, -79.706464),
        (0, 2, 43.506151, -79.706967),
        (1, 0, 43.508779, -79.70988),
        (1, 1, 43.509137, -79.710255),
        (1, 2, 43.508927, -79.710664),
        (2, 0, 43.504323, -79.709994),
        (2, 1, 43.503971, -79.710379),
        (2, 2, 43.503619, -79.710765),
        (3, 0, 43.499106, -79.711594),
        (3, 1, 43.498878, -79.711063),
        (3, 2, 43.498769, -79.710462),
        (4, 0, 43.495965, -79.718631),
        (4, 1, 43.495573, -79.718365),
        (4, 2, 43.495253, -79.717928),
        (5, 0, 43.49269, -79.719513),
        (5, 1, 43.492455, -79.718985),
        (5, 2, 43.492213, -79.718463),
        (6, 0, 43.487931, -79.713094),
        (6, 1, 43.487493, -79.712958),
        (6, 2, 43.487045, -79.712972),
        (7, 0, 43.491142, -79.71158),
        (7, 1, 43.490896, -79.71109),
        (7, 2, 43.4906, -79.710622),
        (8, 0, 43.488165, -79.707759),
        (8, 1, 43.48812, -79.707252),
        (8, 2, 43.487866, -79.706747),
        (9, 0, 43.493808, -79.70794),
        (9, 1, 43.494129, -79.707508),
        (9, 2, 43.494393, -79.707007),
        (10, 0, 43.49871, -79.70363),
        (10, 1, 43.499058, -79.703239),
        (10, 2, 43.499413, -79.702858),
        (11, 0, 43.501012, -79.70069),
        (11, 1, 43.500963, -79.700085),
        (11, 2, 43.501009, -79.699468),
    ]

    // MARK: - Diagnostic logging (viewable from the web page's Logs panel)
    private var nativeLogs: [String] = []
    private var lastGpsLogAt: Date = .distantPast
    private static let logTimeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()

    private func nativeLog(_ cat: String, _ msg: String) {
        let ts = Self.logTimeFormatter.string(from: Date())
        nativeLogs.append("[\(ts)] [\(cat)] \(msg)")
        if nativeLogs.count > 200 { nativeLogs.removeFirst(nativeLogs.count - 200) }
    }

    /// Joined log text for the WebView via NativeBridge.getNativeLogs().
    func nativeLogsText() -> String {
        return nativeLogs.joined(separator: "\n")
    }

    func clearNativeLogs() {
        nativeLogs.removeAll()
    }

    /// ScheduleManager has no log buffer of its own; route its lines here
    /// (main-thread safe: notification callbacks arrive on other queues).
    func schedLog(_ msg: String) {
        if Thread.isMainThread {
            nativeLog("SCHED", msg)
        } else {
            DispatchQueue.main.async { [weak self] in self?.nativeLog("SCHED", msg) }
        }
    }

    /// LiveActivityManager's log route (same pattern as schedLog).
    func liveLog(_ msg: String) {
        if Thread.isMainThread {
            nativeLog("LIVE", msg)
        } else {
            DispatchQueue.main.async { [weak self] in self?.nativeLog("LIVE", msg) }
        }
    }

    /// Set by ViewController: evaluates JS in the page.
    var jsEval: ((String) -> Void)?
    /// Called when a permission-deferred ride auto-starts.
    var onAutoStarted: (() -> Void)?
    /// Page requested by tapping a schedule notification ("am"/"pm").
    var pendingScheduledTab: String?

    /// Quiet local ride-start confirmation (first GPS fix, with
    /// accuracy). One fixed identifier, so a new ride's notification
    /// replaces the previous one instead of stacking.
    static let startNotificationID = "bus.ride.start"
    private var startNotificationPending = false
    /// Accuracy (rounded m) the posted start note currently shows;
    /// a later fix that beats it re-posts the note (same identifier).
    private var startNotificationShownAccuracy: Int? = nil

    var isTracking: Bool { ride != nil }

    // MARK: - Phase 2 helpers

    /// Removes the ride-start note and resets its bookkeeping.
    private func removeStartNote() {
        startNotificationPending = false
        startNotificationShownAccuracy = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.startNotificationID])
    }

    /// Tears down the in-memory ride (the persisted store is the caller's
    /// business): drops the reference, stops location updates and removes
    /// the start note.
    private func teardownLiveRide() {
        ride = nil
        nearCount = 0
        nearTargetIdx = -1
        manager.stopUpdatingLocation()
        removeStartNote()
    }

    // Settings acknowledgment (Phase 2): persisted in UserDefaults so the
    // snapshot can report which page-settings revision the native side
    // has accepted/applied.
    private var settingsRev: Int { UserDefaults.standard.integer(forKey: "busalerts_settings_rev") }
    private var settingsAcked: Bool { UserDefaults.standard.bool(forKey: "busalerts_settings_acked") }

    private func settingsSignature(for cfg: RideState) -> String {
        return [cfg.followerOn, cfg.sound].map { $0 ? "1" : "0" }.joined(separator: "|")
            + "|" + cfg.myStopAm + "|" + cfg.myStopPm
            + "|" + cfg.deviceId + "|" + cfg.deviceLabel
            + "|" + (cfg.schedEnabled ? "1" : "0")
            + "|" + "\(cfg.schedOn1)|\(cfg.schedOff1)|\(cfg.schedOn2)|\(cfg.schedOff2)"
            + "|" + (cfg.schedWeekdaysOnly ? "1" : "0")
    }

    /// Settings handshake/apply bookkeeping for an incoming page config;
    /// call BEFORE applying it. First contact logs the handshake; a later
    /// signature change bumps the revision and logs the apply; an
    /// unchanged signature logs nothing.
    private func acknowledgeSettings(cfg: RideState) {
        let d = UserDefaults.standard
        let signature = settingsSignature(for: cfg)
        let stored = d.string(forKey: "busalerts_settings_tuple") ?? ""
        if !settingsAcked {
            d.set(true, forKey: "busalerts_settings_acked")
            if signature != stored {
                d.set(settingsRev + 1, forKey: "busalerts_settings_rev")
                d.set(signature, forKey: "busalerts_settings_tuple")
            }
            nativeLog("SET", "handshake: page settings accepted rev=\(settingsRev)")
        } else if signature != stored {
            d.set(settingsRev + 1, forKey: "busalerts_settings_rev")
            d.set(signature, forKey: "busalerts_settings_tuple")
            nativeLog("SET", "applied rev=\(settingsRev)")
        }
    }

    // MARK: - Reconciliation (Phase 2)

    /// Brings the stored/in-memory ride state in line with the unified
    /// lifecycle rules (legacy end, interrupted-ending finalize, complete
    /// classification, stale discard, expired-completed housekeeping).
    /// Logs ONLY when it acts. Idempotent — safe to call repeatedly.
    func reconcile() {
        // (a) Stored state exists but is undecodable → quarantine it.
        if RideStore.storedDataExists(), RideStore.load() == nil {
            RideStore.clear()
            nativeLog("RECON", "quarantined corrupt state")
            if ride == nil { return }
        }

        // Subject ride: the in-memory ride if present, else the stored one.
        guard let subject = ride ?? RideStore.load() else { return }
        let isLive = (ride != nil && subject === ride)
        let now = Date()
        let nowMs = Int(now.timeIntervalSince1970 * 1000)

        // A live tracked ride is in use — its own event handlers
        // govern it, so the disposition rules (b), (d), (e) skip it.
        // (Fix age does not matter: a stationary phone may go minutes
        // between fixes while its ride is genuinely still tracking.
        // Cold state is unaffected — at launch restore() reconciles
        // with ride == nil, so isLive is false there.)
        var liveProgressing = false
        if isLive {
            liveProgressing = true
        }

        // (b) Legacy active ride (no identity — startedAt == 0) → end it.
        if !liveProgressing, !subject.completed, !subject.ended, subject.startedAt == 0 {
            subject.ended = true
            subject.endedAt = nowMs
            subject.endReason = "legacy"
            subject.revision += 1
            EndedStore.save(subject)
            LiveActivityManager.shared.end(rideId: subject.rideId)
            RideStore.clear()
            if isLive { teardownLiveRide() }
            nativeLog("RECON", "ended legacy ride (no startedAt)")
            nativeLog("SNAP", snapLogLine(ride: subject, state: "ended"))
            return
        }

        // (c) A ride caught mid-ending (e.g. the got-off teardown was
        // interrupted) → finalize it: completed if every stop is reached,
        // otherwise ended.
        if subject.ending {
            let id8 = String(subject.rideId.prefix(8))
            if firstUnreached(subject) == -1 {
                subject.ending = false
                subject.completed = true
                subject.completedAt = now
                subject.revision += 1
                RideStore.save(subject)
                if subject.scheduledRide { markSchedConsumed(page: subject.page) }
                LiveActivityManager.shared.endCompleted(ride: subject)
                nativeLog("SNAP", snapLogLine(ride: subject, state: "completed"))
                if isLive { teardownLiveRide() }
            } else {
                subject.ending = false
                subject.ended = true
                subject.endedAt = nowMs
                subject.endReason = "ending-finalized"
                subject.revision += 1
                EndedStore.save(subject)
                LiveActivityManager.shared.end(rideId: subject.rideId)
                RideStore.clear()
                if isLive { teardownLiveRide() }
                nativeLog("SNAP", snapLogLine(ride: subject, state: "ended"))
            }
            nativeLog("RECON", "finalized interrupted ending ride=\(id8)")
            return
        }

        // (d) Active ride with nothing left to reach → it completed.
        if !liveProgressing, !subject.completed, !subject.ended,
           firstUnreached(subject) == -1 {
            subject.completed = true
            subject.completedAt = now
            subject.revision += 1
            RideStore.save(subject)
            if subject.scheduledRide { markSchedConsumed(page: subject.page) }
            LiveActivityManager.shared.endCompleted(ride: subject)
            nativeLog("SNAP", snapLogLine(ride: subject, state: "completed"))
            if isLive { teardownLiveRide() }
            nativeLog("RECON", "classified complete ride=\(String(subject.rideId.prefix(8)))")
            return
        }

        // (e) Stale active ride → discard it (no ended record, no ntfy).
        if !liveProgressing, !subject.completed, !subject.ended, subject.startedAt != 0 {
            let startDay = torontoDayKey(subject.startedAt)
            let today = torontoDayKey(now)
            var reason: String? = nil
            if startDay < today {
                reason = "prev-day"
            } else {
                let window = ScheduleManager.shared.latestWindow(forPage: subject.page)
                if window.off > window.on,
                   torontoMinutes(subject.startedAt) <= window.off,
                   torontoMinutes(now) > window.off {
                    reason = "window-passed"
                }
            }
            if let reason = reason {
                let id8 = String(subject.rideId.prefix(8))
                let page = subject.page
                RideStore.clear()
                LiveActivityManager.shared.end(rideId: subject.rideId)
                if isLive { teardownLiveRide() }
                nativeLog("RECON", "discarded stale ride=\(id8) route=\(page) reason=\(reason)")
                return
            }
        }

        // Housekeeping: an expired completed record is dropped (silent).
        // This mutation moved here from statusJson().
        if subject.completed, let at = subject.completedAt,
           now.timeIntervalSince(at) >= 60 {
            RideStore.clear()
            if isLive { teardownLiveRide() }
        }
    }

    var hasBackgroundPermission: Bool {
        CLLocationManager.authorizationStatus() == .authorizedAlways
    }

    private override init() {
        super.init()
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyBest
        manager.distanceFilter = 5
        manager.activityType = .automotiveNavigation
        // Setting this without the 'location' UIBackgroundModes key throws
        // NSException and kills the app at launch — guard it. (This exact
        // crash shipped once via a bad cloud build; never again.)
        let bgModes = Bundle.main.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] ?? []
        if bgModes.contains("location") {
            manager.allowsBackgroundLocationUpdates = true
        }
        manager.pausesLocationUpdatesAutomatically = false
        if #available(iOS 11.0, *) {
            manager.showsBackgroundLocationIndicator = true
        }
    }

    // MARK: - Bridge API (mirrors Android NativeBridge + TrackingService)

    /// Returns "started" / "permission_needed" / "error", exactly like Android.
    /// Phase 2 check-first semantics: a live ride is never clobbered — a
    /// manual start resumes it untouched, a same-page schedule event just
    /// resyncs it, and only a different-page schedule event ends it (into
    /// EndedStore, reason "schedule-override") before a fresh create.
    func startRide(configJson: String?, scheduled: Bool = false) -> String {
        nativeLog("SYS", "startRide scheduled=\(scheduled)")
        guard let configJson = configJson, !configJson.isEmpty,
              let data = configJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            nativeLog("SYS", "startRide: invalid config -> error")
            return "error"
        }
        switch CLLocationManager.authorizationStatus() {
        case .notDetermined:
            nativeLog("SYS", "startRide: permission_needed (requesting always)")
            pendingConfig = configJson
            manager.requestAlwaysAuthorization()
            return "permission_needed"
        case .authorizedAlways:
            break
        default:
            // denied / restricted / when-in-use: the page shows the
            // "Allow all the time" guidance, same as Android.
            nativeLog("SYS", "startRide: permission_needed (denied/restricted)")
            return "permission_needed"
        }
        let cfg = RideState(json: obj)
        // Scheduled starts carry a currency gate: an event outside
        // [on-5, off] of its page's latest window is stale — ignore it.
        if scheduled {
            let window = ScheduleManager.shared.latestWindow(forPage: cfg.page)
            let nowMin = torontoMinutes(Date())
            if nowMin < window.on - 5 || nowMin > window.off {
                nativeLog("SCHED", "stale event ignored page=\(cfg.page)")
                pushSyncIfActive()
                return "started"
            }
        }
        reconcile()
        // Check-first: a live active ride wins over any new start.
        if let r = ride, !r.ended, !r.completed {
            if !scheduled {
                // Manual start over a live ride: change NOTHING, just resume.
                nativeLog("START", "live ride exists — resuming ride=\(String(r.rideId.prefix(8))) (check-first)")
                beginTracking()
                pushSync(toast: nil)
                return "started"
            }
            if cfg.page == r.page {
                // Same-page schedule event: resync only — except a ride
                // that was started some other way, has no fix and no
                // progress yet gets re-tagged as schedule-started.
                if r.lastFixTime == nil,
                   r.stops.allSatisfy({ !$0.reached && !$0.skipped }),
                   r.startSource != "schedule" {
                    r.startSource = "schedule"
                    r.scheduledRide = true
                    persist()
                    nativeLog("SCHED", "re-tagged startSource=schedule ride=\(String(r.rideId.prefix(8)))")
                }
                pushSync(toast: nil)
                return "started"
            }
            // Different-page schedule event: end the live ride into
            // EndedStore, then fall through to a fresh create that must
            // NOT clear the just-written ended record.
            let old = r
            let oldId8 = String(old.rideId.prefix(8))
            let oldPage = old.page
            if old.scheduledRide { markSchedConsumed(page: oldPage) }
            old.ended = true
            old.endedAt = Int(Date().timeIntervalSince1970 * 1000)
            old.endReason = "schedule-override"
            old.revision += 1
            EndedStore.save(old)
            LiveActivityManager.shared.end(rideId: old.rideId)
            nativeLog("SNAP", snapLogLine(ride: old, state: "ended"))
            nativeLog("SCHED", "schedule override: ended ride=\(oldId8) route=\(oldPage) reason=schedule-override")
            teardownLiveRide()
            RideStore.clear()
            jsEval?("if (typeof nativeNoRide === 'function') { try { nativeNoRide(); } catch(e){} }")
            createFreshRide(configJson: configJson, scheduled: scheduled, clearEnded: false)
            nativeLog("SYS", "startRide: started stops=\(ride?.stops.count ?? 0)")
            return "started"
        }
        createFreshRide(configJson: configJson, scheduled: scheduled, clearEnded: true)
        nativeLog("SYS", "startRide: started stops=\(ride?.stops.count ?? 0)")
        return "started"
    }

    /// Fresh create (Phase 2): builds the ride from the config with ALL
    /// stop flags explicitly zeroed, stamps a fresh identity, persists
    /// and begins tracking. Normally clears EndedStore; the schedule-
    /// override path passes clearEnded=false to keep the record it just
    /// wrote for the ride it ended.
    private func createFreshRide(configJson: String, scheduled: Bool, clearEnded: Bool) {
        if clearEnded { EndedStore.clear() }
        applyConfig(jsonString: configJson, keepProgress: false)
        guard let r = ride else { return }
        for stop in r.stops {
            stop.reached = false
            stop.skipped = false
        }
        r.rideId = UUID().uuidString
        r.startedAt = Int(Date().timeIntervalSince1970 * 1000)
        r.startSource = scheduled ? "schedule" : "manual"
        r.routeFingerprint = r.computeFingerprint()
        r.ended = false
        r.endedAt = 0
        r.endReason = ""
        r.ending = false
        r.completed = false
        r.completedAt = nil
        r.scheduledRide = scheduled
        // Phase 4: a fresh ride always starts with its recovery credit
        // available, regardless of anything the config JSON carried.
        r.recoveryCreditAvailable = true
        persist()
        beginTracking()
        LiveActivityManager.shared.start(ride: r)
    }

    /// A tapped schedule notification for a page (Phase 2): the currency
    /// gate runs here, then the check-first startRide() handles the rest.
    /// Returns true when the tap was consumed.
    func handleScheduleTap(page: String) -> Bool {
        let window = ScheduleManager.shared.latestWindow(forPage: page)
        let nowMin = torontoMinutes(Date())
        if nowMin < window.on - 5 || nowMin > window.off {
            nativeLog("SCHED", "stale event ignored page=\(page)")
            pushSyncIfActive()
            return true
        }
        reconcile()
        guard let cfg = ScheduleManager.shared.configJSON(forPage: page),
              startRide(configJson: cfg, scheduled: true) == "started" else {
            return false
        }
        if let r = ride, r.scheduledRide, r.page == page {
            markSchedConsumed(page: page)
        }
        jsEval?("if (typeof nativeAutoStarted === 'function') { try { nativeAutoStarted(); } catch(e){} }")
        if ride != nil {
            pushSync(toast: nil)
        } else {
            pushSyncIfActive()
        }
        return true
    }

    // MARK: - Scheduled start on activation (v44)
    //
    // The banner tap is no longer the only scheduled-start trigger: an app
    // open / foreground also checks whether a scheduled occurrence is
    // current, and if so runs the SAME handleScheduleTap path (currency
    // gate, reconcile, completed-hold, check-first all inherited). The
    // consumption marker is the one new guard: per route it records
    // "yyyy-MM-dd|on" (Toronto date + the occurrence's on-minutes) once
    // that occurrence has produced its ride, so a ride that was stopped
    // or completed inside its window is never resurrected by a later
    // open. The marker is written when a scheduled start creates or
    // re-tags a ride, when a schedule ride is stopped or completed, and
    // when one is ended by a schedule override. It is read ONLY here -
    // the tap path never reads it, so taps behave exactly as before.

    private func schedOccurrence(page: String) -> String {
        return torontoDayKey(Date()) + "|" + String(ScheduleManager.shared.latestWindow(forPage: page).on)
    }

    private func markSchedConsumed(page: String) {
        UserDefaults.standard.set(schedOccurrence(page: page), forKey: "busalerts_sched_consumed_" + page)
    }

    private func schedConsumed(page: String) -> Bool {
        return UserDefaults.standard.string(forKey: "busalerts_sched_consumed_" + page) == schedOccurrence(page: page)
    }

    /// Activation trigger: called on cold launch (after restore(), before
    /// the page loads) and on every foreground. Fires handleScheduleTap
    /// for a route only when ALL hold: schedule enabled, weekday rule
    /// satisfied, now inside [on-5, off], occurrence not consumed, and
    /// no live ride on the OTHER route (skip - a mere open must not
    /// override a live ride; the banner tap keeps that power).
    /// v46: end a live schedule-started ride whose window off-time has
    /// passed. iOS schedules only start notifications, so without this
    /// a schedule-started ride that never completes tracks past its off
    /// until it finishes or is stopped by hand (found in v9.21
    /// acceptance). Evaluated in the scheduler's own space — Toronto
    /// day key + minutes — never as an absolute instant, so DST
    /// transition days stay exact.
    ///
    /// Guards: a live ride only; scheduledRide only (set solely by the
    /// schedule start paths, so manual rides are immune); not completed
    /// or ended (finishRide keeps its record — a completed ride opened
    /// later the same day must stay untouched); degenerate carried
    /// windows (off <= on or unset) never fire. On firing: log, post
    /// the end notification, then stopRide() itself (which writes the
    /// consumption marker and ends the Live Activity immediately).
    /// Returns true when it ended the ride.
    @discardableResult
    private func checkScheduleOff() -> Bool {
        guard let r = ride, r.scheduledRide, !r.completed, !r.ended else { return false }
        let on = r.page == "am" ? r.schedOn1 : r.schedOn2
        let off = r.page == "am" ? r.schedOff1 : r.schedOff2
        guard off > 0, off > on else { return false }
        let now = Date()
        let startDay = torontoDayKey(r.startedAt)
        let today = torontoDayKey(now)
        guard today >= startDay else { return false }
        let nowMin = torontoMinutes(now)
        guard today > startDay || nowMin > off else { return false }
        nativeLog("SCHED", "off-stop ride=\(String(r.rideId.prefix(8))) page=\(r.page) off=\(off) now=\(nowMin)")
        postOffStopNotification()
        stopRide()
        return true
    }

    func checkScheduleOnActivation(source: String) {
        // v46: an already-live schedule ride past its off ends here
        // first — before the enabled/weekday gates, so the end depends
        // only on the ride itself, never on today's toggles.
        _ = checkScheduleOff()
        let d = UserDefaults.standard
        guard d.bool(forKey: "busalerts_sched_enabled") else {
            nativeLog("SCHED", "activation (\(source)): skip - schedule disabled")
            return
        }
        let now = Date()
        if d.bool(forKey: "busalerts_sched_weekdays") {
            var cal = Calendar(identifier: .gregorian)
            cal.timeZone = torontoTimeZone
            let wd = cal.component(.weekday, from: now)
            if wd == 1 || wd == 7 {
                nativeLog("SCHED", "activation (\(source)): skip - weekend, weekdays-only")
                return
            }
        }
        let nowMin = torontoMinutes(now)
        for page in ["am", "pm"] {
            let window = ScheduleManager.shared.latestWindow(forPage: page)
            if nowMin < window.on - 5 || nowMin > window.off {
                nativeLog("SCHED", "activation (\(source)): page=\(page) outside window [\(window.on - 5),\(window.off)] now=\(nowMin)")
                continue
            }
            if schedConsumed(page: page) {
                nativeLog("SCHED", "activation (\(source)): page=\(page) skip - occurrence consumed")
                continue
            }
            if let r = ride, !r.ended, !r.completed, r.page != page {
                nativeLog("SCHED", "activation (\(source)): page=\(page) skip - live ride on \(r.page)")
                continue
            }
            nativeLog("SCHED", "activation (\(source)): page=\(page) FIRE")
            _ = handleScheduleTap(page: page)
        }
    }

    /// v45 launch adoption: after restore(), adopt the live ride's Live
    /// Activity (start hook — keyed by rideId, so it adopts rather than
    /// duplicates). With no live ride, keep a still-lingering completed
    /// card (it carries its own 5-minute dismissal) and end the rest.
    func adoptLiveActivityOnLaunch() {
        if let r = ride, !r.completed, !r.ended {
            LiveActivityManager.shared.start(ride: r)
            return
        }
        var keepId: String? = nil
        if let stored = RideStore.load(), stored.completed, let at = stored.completedAt,
           Date().timeIntervalSince(at) < 300 {
            keepId = stored.rideId
        }
        LiveActivityManager.shared.sweep(currentRideId: keepId)
    }

    func stopRide() {
        nativeLog("SYS", "stopRide")
        guard let ending = ride else { return }
        removeStartNote()
        if ending.scheduledRide { markSchedConsumed(page: ending.page) }
        LiveActivityManager.shared.end(rideId: ending.rideId)
        ride = nil
        nearCount = 0
        nearTargetIdx = -1
        manager.stopUpdatingLocation()
        RideStore.clear()
        // Stop clears lifecycle records too: no ended record survives it.
        EndedStore.clear()
        nativeLog("SNAP", snapLogLine(ride: nil, state: "none"))
        jsEval?("if (typeof nativeNoRide === 'function') { try { nativeNoRide(); } catch(e){} }")
    }

    /// Manual "skip next stop" (Phase 2, D7): marks the next unreached
    /// stop reached+skipped — the snap-forward precedent — with NO arrival
    /// side-effects (no ntfy/notification/sound/on-bus/My Stop). Skipping
    /// the final stop ends the ride as ENDED (reason "skip-final").
    func skipNext() {
        guard let r = ride else {
            nativeLog("SKIP", "no-op (no active ride)")
            return
        }
        guard let idx = r.stops.firstIndex(where: { !$0.reached && !$0.skipped }) else {
            nativeLog("SKIP", "no-op (no unreached stop)")
            return
        }
        let stop = r.stops[idx]
        stop.reached = true
        stop.skipped = true
        persist()
        nativeLog("SKIP", "skipped next stop \(stop.label) ride=\(String(r.rideId.prefix(8)))")
        if firstUnreached(r) == -1 {
            // Final stop skipped: end as ENDED. The end writes via
            // EndedStore with an explicit revision bump — NOT persist()
            // (which already bumped for the skip itself).
            r.ended = true
            r.endedAt = Int(Date().timeIntervalSince1970 * 1000)
            r.endReason = "skip-final"
            r.revision += 1
            EndedStore.save(r)
            RideStore.clear()
            teardownLiveRide()
            nativeLog("SNAP", snapLogLine(ride: r, state: "ended"))
            jsEval?("if (typeof nativeNoRide === 'function') { try { nativeNoRide(); } catch(e){} }")
        } else {
            pushSync(toast: nil)
        }
    }

    func markReached() {
        guard let r = ride else { return }
        let idx = r.stops.firstIndex(where: { !$0.reached }) ?? -1
        if idx >= 0 && idx < r.stops.count {
            nativeLog("STOP", "markReached manual: \(r.stops[idx].label)")
            arrive(at: idx)
        }
    }

    func updateConfig(configJson: String?) {
        nativeLog("SYS", "updateConfig")
        guard let configJson = configJson,
              let data = configJson.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let cfg = RideState(json: obj)
        // Settings acknowledgment runs BEFORE anything is applied.
        acknowledgeSettings(cfg: cfg)
        // Always refresh the schedule (must survive with no active ride).
        ScheduleManager.shared.apply(config: cfg)
        // During a ride (Phase 2, §5): copy ONLY settings fields into the
        // live ride — page/stops/progress/identity/scheduledRide are the
        // running ride's own and are never touched by a page config push.
        if let r = ride {
            r.followerOn = cfg.followerOn
            r.sound = cfg.sound
            r.myStopAm = cfg.myStopAm
            r.myStopPm = cfg.myStopPm
            r.deviceId = cfg.deviceId
            r.deviceLabel = cfg.deviceLabel
            r.topic = cfg.topic
            r.snapDistance = cfg.snapDistance
            r.schedEnabled = cfg.schedEnabled
            r.schedOn1 = cfg.schedOn1
            r.schedOff1 = cfg.schedOff1
            r.schedOn2 = cfg.schedOn2
            r.schedOff2 = cfg.schedOff2
            r.schedWeekdaysOnly = cfg.schedWeekdaysOnly
            persist()
            nativeLog("CFG", "settings applied during ride (route unchanged)")
            pushSync(toast: nil)
        }
    }

    /// Status JSON for the WebView to resync; "" when no ride is active.
    /// A recently completed ride (within 15 min) is returned with
    /// active=false so the page can show the arrived UI after a background
    /// finish. Shape mirrors Android's getStatusJson(). The `page` field is
    /// how the pages detect a ride started for the OTHER route and stop it.
    func statusJson() -> String {
        // Reconcile first (Phase 2): dispositions and the expired-
        // completed housekeeping all live there now.
        reconcile()
        if let r = ride, !r.stops.isEmpty {
            return statusPayload(ride: r, active: true)
        }
        if let r = RideStore.load(), !r.stops.isEmpty, r.completed {
            if let at = r.completedAt, Date().timeIntervalSince(at) < 60 {
                return statusPayload(ride: r, active: false)
            }
        }
        if let r = EndedStore.load(), !r.stops.isEmpty, r.ended {
            return statusPayload(ride: r, active: false)
        }
        return ""
    }

    private func statusPayload(ride r: RideState, active: Bool) -> String {
        var payload: [String: Any] = [
            "active": active,
            "completed": r.completed,
            "ended": r.ended,
            "page": r.page,
            "reached": r.stops.map { $0.reached },
            "skipped": r.stops.map { $0.skipped },
            "next": firstUnreached(r),
            "total": r.stops.count
        ]
        // on-bus pill for driver map: poll path must include it (like pushSync).
        if active, let obs = onBusStop {
            payload["onBus"] = obs
        }
        // Phase 1 (shadow mode): the unified snapshot rides alongside the
        // legacy fields. Nothing reads it yet; the GUI still uses the
        // legacy fields above.
        payload["snapshot"] = buildSnapshot(ride: r, active: active)
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    /// Phase 1 unified ride-state snapshot (schema 1), built fresh from
    /// the ride being served on every status call. Pure read: no state
    /// changes. Identity fields are null until stamped (legacy rides).
    private func buildSnapshot(ride r: RideState, active: Bool) -> [String: Any] {
        var rideIdVal: Any = NSNull()
        if !r.rideId.isEmpty { rideIdVal = r.rideId }
        var startedAtVal: Any = NSNull()
        if r.startedAt != 0 { startedAtVal = r.startedAt }
        var startSourceVal: Any = NSNull()
        if !r.startSource.isEmpty { startSourceVal = r.startSource }
        var fingerprintVal: Any = NSNull()
        if !r.routeFingerprint.isEmpty { fingerprintVal = r.routeFingerprint }
        var nextIndex = -1
        var nextLabelVal: Any = NSNull()
        for i in 0..<r.stops.count {
            if !r.stops[i].reached && !r.stops[i].skipped {
                nextIndex = i
                nextLabelVal = r.stops[i].label
                break
            }
        }
        var onBusVal: Any = NSNull()
        if active, let obs = onBusStop { onBusVal = obs }
        // lastFix only when the served ride is the live tracker ride.
        var lastFixVal: Any = NSNull()
        if active, self.ride === r, let t = r.lastFixTime {
            lastFixVal = ["at": Int(t.timeIntervalSince1970 * 1000),
                          "acc": r.lastFixAccuracy] as [String: Any]
        }
        var healthVal: Any = NSNull()
        if active {
            if let t = r.lastFixTime, Date().timeIntervalSince(t) <= 30 {
                healthVal = "live"
            } else {
                healthVal = "waiting"
            }
        }
        var snapshot: [String: Any] = [
            "schema": 1,
            "rideId": rideIdVal,
            "revision": r.revision,
            "state": r.ended ? "ended" : (active ? "active" : "completed"),
            "startedAt": startedAtVal,
            "startSource": startSourceVal,
            "route": [
                "page": r.page,
                "fingerprint": fingerprintVal,
                "stops": r.stops.map { s in
                    ["label": s.label, "name": s.name, "lat": s.lat, "lng": s.lng,
                     "reached": s.reached, "skipped": s.skipped] as [String: Any]
                }
            ] as [String: Any],
            "progress": [
                "reached": r.stops.filter { $0.reached }.count,
                "skipped": r.stops.filter { $0.skipped }.count,
                "total": r.stops.count,
                "nextIndex": nextIndex,
                "nextLabel": nextLabelVal
            ] as [String: Any],
            "onBus": onBusVal,
            "lastFix": lastFixVal,
            "schedule": [
                "enabled": r.schedEnabled,
                "on1": r.schedOn1,
                "off1": r.schedOff1,
                "on2": r.schedOn2,
                "off2": r.schedOff2,
                "weekdaysOnly": r.schedWeekdaysOnly
            ] as [String: Any],
            "settings": [
                "followerOn": r.followerOn,
                "sound": r.sound,
                "myStopAm": r.myStopAm,
                "myStopPm": r.myStopPm,
                "deviceId": r.deviceId,
                "settingsRev": settingsRev,
                "settingsAcked": settingsAcked
            ] as [String: Any],
            "updatedAt": Int(Date().timeIntervalSince1970 * 1000),
            "health": healthVal
        ]
        if r.ended {
            snapshot["endedAt"] = r.endedAt != 0 ? r.endedAt : NSNull()
            snapshot["endReason"] = r.endReason
        }
        return snapshot
    }

    /// Phase 1 SNAP log line (shadow mode). Format:
    /// rev=<n> state=<active|completed|none> route=<page|-> fp=<fp8|->
    /// ride=<id8|-> startedAt=<ms|-> src=<source|-> reached=<n>/<total>
    /// next=<label|->
    private func snapLogLine(ride r: RideState?, state: String) -> String {
        guard let r = r else {
            return "rev=0 state=none route=- fp=- ride=- startedAt=- src=- reached=0/0 next=-"
        }
        let reachedCount = r.stops.filter { $0.reached }.count
        var nextLabel = "-"
        for s in r.stops where !s.reached && !s.skipped {
            nextLabel = s.label
            break
        }
        let route = r.page.isEmpty ? "-" : r.page
        let fp = r.routeFingerprint.isEmpty ? "-" : String(r.routeFingerprint.prefix(8))
        let rid = r.rideId.isEmpty ? "-" : String(r.rideId.prefix(8))
        let started = r.startedAt == 0 ? "-" : "\(r.startedAt)"
        let src = r.startSource.isEmpty ? "-" : r.startSource
        return "rev=\(r.revision) state=\(state) route=\(route) fp=\(fp) ride=\(rid) startedAt=\(started) src=\(src) reached=\(reachedCount)/\(r.stops.count) next=\(nextLabel)"
    }

    /// Resume a persisted ride on launch (mirrors Android's START_STICKY restart).
    /// A completed ride is for display only — never resume it as an active ride.
    func restore() {
        // Reconcile first (Phase 2): a stored legacy/stale/ending ride is
        // disposed of there and never resumes; a completed record stays
        // display-only below.
        reconcile()
        guard let r = RideStore.load(), !r.stops.isEmpty, !r.completed else { return }
        ride = r
        // No stamping here: identity loads with the state (a legacy state
        // has none and keeps none).
        nativeLog("SNAP", snapLogLine(ride: r, state: "active"))
        // Phase 4 (enabled): arm the one-shot recovery evaluation for
        // this restored ride (the no-established-position and
        // final-stop cases are judged and logged here, at restore).
        armRecoveryEvaluation(for: r)
        beginTracking()
    }

    /// Phase 4 (enabled): arm the recovery evaluation for a ride
    /// restored in restore(). Captures the next unpassed stop N (first
    /// stop neither reached nor skipped) and the following unpassed
    /// stop after it. Judge order at restore:
    /// (a) ESTABLISHED-POSITION GUARD — if no stop is already passed
    ///     (reached or skipped), first-stop misses are not covered:
    ///     log would-not/no-established-position here and arm nothing.
    /// (b) Else if N has no following unpassed stop, log the final-stop
    ///     verdict here and arm nothing.
    /// Otherwise arm the one-shot evaluation for the first fresh fix.
    private func armRecoveryEvaluation(for r: RideState) {
        recoveryPending = nil
        guard let nextIdx = r.stops.firstIndex(where: { !$0.reached && !$0.skipped }) else { return }
        let next = r.stops[nextIdx]
        var following: RideStop? = nil
        if nextIdx + 1 < r.stops.count {
            for i in (nextIdx + 1)..<r.stops.count where !r.stops[i].reached && !r.stops[i].skipped {
                following = r.stops[i]
                break
            }
        }
        let id8 = String(r.rideId.prefix(8))
        // (a) Established-position guard (see doc comment above).
        if !r.stops.contains(where: { $0.reached || $0.skipped }) {
            nativeLog("RECOVERY", "verdict=would-not ride=\(id8) route=\(r.page) next=\(next.label) following=\(following?.label ?? "-") distNext=-1 distFollowing=-1 acc=-1 reason=no-established-position fixSource=none")
            return
        }
        // (b) Final stop: judged at restore, nothing armed.
        guard let fol = following else {
            nativeLog("RECOVERY", "verdict=would-not ride=\(id8) route=\(r.page) next=\(next.label) following=- distNext=-1 distFollowing=-1 acc=-1 reason=final-stop fixSource=none")
            return
        }
        recoveryPending = (rideId: r.rideId, route: r.page, nextIndex: nextIdx,
                           nextLabel: next.label, nextLat: next.lat, nextLng: next.lng,
                           followingLabel: fol.label, followingLat: fol.lat, followingLng: fol.lng)
    }

    /// Phase 4 (enabled): evaluate the armed recovery check on the
    /// first FRESH fix processed after restore, then disarm (one-shot).
    /// A fix whose own CLLocation timestamp is more than 30s old is a
    /// stale cached fix: it is ignored entirely and the evaluation
    /// STAYS ARMED for the next fix. On a progression verdict with the
    /// ride's recovery credit available, the advance is APPLIED here:
    /// stop N is marked reached+skipped directly (the exact marking
    /// mechanics of skipNext(), minus its entry point — skipNext()'s
    /// skip-final ENDED branch can never fire from here because an
    /// advance is only applied when a following unpassed stop exists,
    /// re-checked below), the credit is spent, and the ride persists.
    /// The marking path contains no arrival side-effects: no popup /
    /// local notification, no ntfy, no sound, no My Stop event, no
    /// on-bus synthesis. handleLocation then keeps processing this same
    /// fix against the NEW next stop, so a genuine arrival at the
    /// following stop can still fire from it.
    private func evaluateRecoveryIfArmed(loc: CLLocation, accuracy: Double, ride r: RideState) {
        guard let pending = recoveryPending else { return }
        // FIX FRESHNESS: stale cached fixes are ignored; stay armed.
        if Date().timeIntervalSince(loc.timestamp) > 30 { return }
        recoveryPending = nil
        // A different ride than the restored one must not be evaluated.
        guard pending.rideId == r.rideId else { return }
        let distNext = Int(loc.distance(from: CLLocation(latitude: pending.nextLat, longitude: pending.nextLng)))
        let distFollowing = Int(loc.distance(from: CLLocation(latitude: pending.followingLat, longitude: pending.followingLng)))
        let acc = Int(accuracy)
        let id8 = String(pending.rideId.prefix(8))
        if accuracy < 0 || accuracy > 100 {
            nativeLog("RECOVERY", "verdict=would-not ride=\(id8) route=\(pending.route) next=\(pending.nextLabel) following=\(pending.followingLabel) distNext=\(distNext) distFollowing=\(distFollowing) acc=\(acc) reason=poor-accuracy fixSource=first-fix")
            return
        }
        guard distNext - distFollowing >= 20 else {
            nativeLog("RECOVERY", "verdict=would-not ride=\(id8) route=\(pending.route) next=\(pending.nextLabel) following=\(pending.followingLabel) distNext=\(distNext) distFollowing=\(distFollowing) acc=\(acc) reason=no-progression fixSource=first-fix")
            return
        }
        // Progression judged. Without credit, nothing is applied (the
        // one-shot is still consumed — it was disarmed above).
        guard r.recoveryCreditAvailable else {
            nativeLog("RECOVERY", "verdict=would-advance ride=\(id8) route=\(pending.route) next=\(pending.nextLabel) following=\(pending.followingLabel) distNext=\(distNext) distFollowing=\(distFollowing) acc=\(acc) reason=credit-spent fixSource=first-fix")
            return
        }
        // Apply-time safety re-checks: N must still be the first
        // unpassed stop, and a following unpassed stop must still exist
        // (structurally bars any skip-final / ride-end from recovery).
        let currentFirst = r.stops.firstIndex(where: { !$0.reached && !$0.skipped })
        var hasFollowing = false
        if let cf = currentFirst, cf + 1 < r.stops.count {
            hasFollowing = ((cf + 1)..<r.stops.count).contains(where: { !r.stops[$0].reached && !r.stops[$0].skipped })
        }
        guard currentFirst == pending.nextIndex, hasFollowing else {
            nativeLog("RECOVERY", "verdict=would-advance ride=\(id8) route=\(pending.route) next=\(pending.nextLabel) following=\(pending.followingLabel) distNext=\(distNext) distFollowing=\(distFollowing) acc=\(acc) reason=progression fixSource=first-fix")
            return
        }
        // APPLY: mark N passed-but-silent, spend the credit, persist
        // (persist() bumps the snapshot revision and saves via
        // RideStore). No other calls — see the doc comment above.
        let stop = r.stops[pending.nextIndex]
        stop.reached = true
        stop.skipped = true
        r.recoveryCreditAvailable = false
        nativeLog("RECOVERY", "verdict=advanced ride=\(id8) route=\(pending.route) next=\(pending.nextLabel) following=\(pending.followingLabel) distNext=\(distNext) distFollowing=\(distFollowing) acc=\(acc) reason=progression fixSource=first-fix")
        persist()
        pushSync(toast: nil)
    }

    // MARK: - Internals

    private func applyConfig(jsonString: String, keepProgress: Bool) {
        guard let data = jsonString.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return
        }
        let cfg = RideState(json: obj)
        if keepProgress, let r = ride, r.stops.count == cfg.stops.count {
            for i in 0..<cfg.stops.count {
                cfg.stops[i].reached = r.stops[i].reached
                cfg.stops[i].skipped = r.stops[i].skipped
            }
            cfg.scheduledRide = r.scheduledRide
            // Same ride continuing (Phase 1): identity carries over too.
            cfg.rideId = r.rideId
            cfg.startedAt = r.startedAt
            cfg.startSource = r.startSource
            cfg.routeFingerprint = r.routeFingerprint
            cfg.revision = r.revision
            // Same ride continuing (Phase 4): its recovery credit
            // state carries over too.
            cfg.recoveryCreditAvailable = r.recoveryCreditAvailable
        } else {
            // No merge: identity must not leak in from the incoming JSON
            // (a stored schedule config is serialized via toJSON and can
            // carry a previous ride's identity). startRide stamps a fresh
            // identity when it finds rideId empty; restore() never comes
            // through here.
            cfg.rideId = ""
            cfg.startedAt = 0
            cfg.startSource = ""
            cfg.routeFingerprint = ""
            cfg.revision = 0
            // No merge: a previous ride's spent recovery credit must
            // not leak in either (Phase 4).
            cfg.recoveryCreditAvailable = true
        }
        ride = cfg
        ScheduleManager.shared.apply(config: cfg)
        persist()
    }

    private func beginTracking() {
        guard ride != nil else { return }
        nearCount = 0
        nearTargetIdx = -1
        checkpointProgress.removeAll()
        lastCpLogAt = .distantPast
        onBusStop = nil
        startNotificationPending = true
        startNotificationShownAccuracy = nil
        persist()
        manager.startUpdatingLocation()
    }

    private func persist() {
        if let r = ride {
            r.revision += 1
            RideStore.save(r)
            nativeLog("SNAP", snapLogLine(ride: r, state: r.completed ? "completed" : "active"))
            LiveActivityManager.shared.sync(ride: r)
        }
    }

    private func firstUnreached(_ r: RideState) -> Int {
        for i in 0..<r.stops.count {
            if !r.stops[i].reached { return i }
        }
        return -1
    }

    private func finishRide() {
        nativeLog("SYS", "finishRide")
        startNotificationPending = false
        startNotificationShownAccuracy = nil
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: [Self.startNotificationID])
        // Keep the state marked completed (with a timestamp) instead of
        // deleting it, so the WebView can show the arrived UI on resume.
        if let r = ride {
            r.completed = true
            r.completedAt = Date()
            r.revision += 1
            RideStore.save(r)
            if r.scheduledRide { markSchedConsumed(page: r.page) }
            LiveActivityManager.shared.endCompleted(ride: r)
            nativeLog("SNAP", snapLogLine(ride: r, state: "completed"))
        }
        ride = nil
        nearCount = 0
        nearTargetIdx = -1
        manager.stopUpdatingLocation()
        jsEval?("if (typeof nativeFinished === 'function') { try { nativeFinished(); } catch(e){} }")
    }

    // MARK: - Arrival detection (port of TrackingService.handleLocation)

    private func handleLocation(_ loc: CLLocation, accuracy: Double, ride r: RideState) {
        // Phase 4 (enabled): first FRESH fix after a restore evaluates
        // the armed recovery check before anything else here can mutate
        // the ride (e.g. snap-forward). If it applies an advance, the
        // code below then processes this same fix against the NEW next
        // stop (idx is computed after this call) — a genuine arrival at
        // the following stop can still fire from this fix.
        evaluateRecoveryIfArmed(loc: loc, accuracy: accuracy, ride: r)
        let lat = loc.coordinate.latitude
        let lng = loc.coordinate.longitude
        r.lastFixTime = Date()
        r.lastFixAccuracy = accuracy
        jsEval?("if (typeof nativePosition === 'function') { try { nativePosition(\(lat),\(lng),\(Int(accuracy))); } catch(e){} }")

        // Throttled GPS log for the Logs panel (1/sec max).
        let now = Date()
        if now.timeIntervalSince(lastGpsLogAt) >= 1.0 {
            lastGpsLogAt = now
            nativeLog("GPS", String(format: "fix lat=%.6f lng=%.6f acc=%dm", lat, lng, Int(accuracy)))
        }

        var idx = firstUnreached(r)
        // Snap-forward ONLY at ride start (no stops reached yet).
        // Mid-ride stays strictly sequential — never reintroduce mid-ride snap
        // (it once caused a false B->L jump skipping C–K on the PM route).
        if idx != -1 && idx == 0 && accuracy <= 150 {
            var best = -1
            var bestDist = Double.greatestFiniteMagnitude
            for i in idx..<r.stops.count {
                if r.stops[i].reached { continue }
                let d = haversine(lat1: lat, lon1: lng,
                                  lat2: r.stops[i].lat, lon2: r.stops[i].lng)
                if d < bestDist { bestDist = d; best = i }
            }
            // Safeguard: never snap more than 3 stops ahead on startup,
            // UNLESS high-accuracy (<=30m). Precise fix near far stop = real
            // mid-route boarding; coarse fix jumping far = cold-GPS glitch.
            let maxSkip = 3
            let highAccuracy = accuracy <= 30
            if !highAccuracy && best > idx && (best - idx) > maxSkip {
                best = -1
            }
            if best > idx && bestDist <= r.snapDistance {
                nativeLog("STOP", "Snap forward \(idx)->\(best) (\(r.stops[best].label)) dist=\(Int(bestDist))m")
                for i in idx..<best {
                    r.stops[i].reached = true
                    r.stops[i].skipped = true
                }
                idx = best
                persist()
                pushSync(toast: "Starting from \(r.stops[best].label) — earlier stops skipped.")
            }
        }
        guard idx != -1 else { finishRide(); return }

        let stop = r.stops[idx]
        let distance = haversine(lat1: lat, lon1: lng, lat2: stop.lat, lon2: stop.lng)
        let limit = stop.acc ?? 50
        if distance <= stop.radius && accuracy <= limit {
            // Tier 1: confident fix — arrive immediately.
            arrive(at: idx, genuineGPS: true)
        } else if distance <= 15 && accuracy <= 150 {
            // Very close to the pin — trust it even with moderate accuracy.
            arrive(at: idx, genuineGPS: true)
        } else if accuracy <= 200 && distance <= stop.radius + accuracy {
            // Tier 2: poor accuracy (phone pocketed) — 3 consecutive fixes
            // near the stop confirm the arrival. A GPS jump won't persist.
            if nearTargetIdx != idx { nearTargetIdx = idx; nearCount = 0 }
            nearCount += 1
            if nearCount >= 3 {
                nearCount = 0
                nearTargetIdx = -1
                arrive(at: idx, genuineGPS: true)
            }
        } else {
            nearCount = 0
            nearTargetIdx = -1
        }

        // Ride-start confirmation: once per ride, on the first fix, after
        // snap/arrival processing so the counts reflect this fix.
        if startNotificationPending {
            startNotificationPending = false
            if ride != nil { postStartNotification(accuracy: accuracy, ride: r) }
        } else if ride != nil, let shown = startNotificationShownAccuracy,
                  Int(accuracy.rounded()) < shown {
            // Accuracy beat what the start note shows: quietly re-post
            // (same identifier) so the note tracks the best fix, like
            // Android's live banner. No threshold \u2014 any improvement.
            postStartNotification(accuracy: accuracy, ride: r)
        }

        // On-bus detection (AM only)
        checkOnBusCheckpoints(lat: lat, lng: lng, accuracy: accuracy, ride: r)
    }

    private func checkOnBusCheckpoints(lat: Double, lng: Double, accuracy: Double, ride r: RideState) {
        guard r.page == "am" else { return }
        guard !Self.amCheckpoints.isEmpty else {
            nativeLog("BUS-DETECT", "No checkpoints loaded!")
            return
        }
        let now = Date()
        let shouldLog = now.timeIntervalSince(lastCpLogAt) >= 10.0
        for (stopIdx, seq, cpLat, cpLng) in Self.amCheckpoints {
            guard stopIdx < r.stops.count else { continue }
            let stop = r.stops[stopIdx]
            guard stop.reached else { continue }
            let prog = checkpointProgress[stopIdx] ?? 0
            guard prog == seq else { continue }
            let d = haversine(lat1: lat, lon1: lng, lat2: cpLat, lon2: cpLng)
            if shouldLog {
                nativeLog("BUS-DETECT", "Stop \(stop.label) cp\(seq+1)/3: \(Int(d))m away (need <=50m), acc=\(Int(accuracy))m")
            }
            if d <= 50 && accuracy <= 100 {
                checkpointProgress[stopIdx] = seq + 1
                nativeLog("BUS-DETECT", "Stop \(stop.label) checkpoint \(seq+1)/3 HIT (\(Int(d))m)")
                if seq == 2 && stopIdx + 1 < r.stops.count {
                    let next = r.stops[stopIdx + 1]
                    let devTag = r.deviceId.isEmpty ? "" : " [\(r.deviceId)]" + (r.deviceLabel.isEmpty ? "" : " (\(r.deviceLabel))")
                    let msg = "\u{1F4F1}\(devTag) on bus, heading to \(next.label)."
                    if r.followerOn && !r.topic.isEmpty {
                        nativeLog("NTFY", "Sending on-bus: \(msg)")
                        NtfyClient.post(topic: r.topic, message: msg) { }
                    } else {
                        nativeLog("NTFY", "Suppressed on-bus (follower alerts off): \(msg)")
                    }
                    onBusStop = next.label
                    pushSync(toast: nil)
                }
            }
        }
        if shouldLog { lastCpLogAt = now }
    }

    /// Arrival at a stop. `genuineGPS` is true ONLY for the calls from
    /// handleLocation's sequential GPS tiers — the one genuine-arrival
    /// code path. Manual markReached() calls with the default false, so
    /// it (like skipNext, snap-forward and the recovery advance, none
    /// of which come through here with genuineGPS) never regains the
    /// Phase 4 recovery credit; a genuine GPS arrival does.
    private func arrive(at idx: Int, genuineGPS: Bool = false) {
        guard let r = ride, idx < r.stops.count else { return }
        nearCount = 0
        nearTargetIdx = -1
        onBusStop = nil
        // Phase 4: a genuine GPS arrival REGAINS the recovery credit.
        // Set before this function's persist() below so it is saved
        // with the arrival.
        if genuineGPS { r.recoveryCreditAvailable = true }
        let stop = r.stops[idx]
        stop.reached = true
        let isFinal = idx == r.stops.count - 1
        if r.sound { AlertPlayer.shared.play() }
        vibrate()
        // My Stop format: "📱 [X##] waiting at Stop 1: Mia." (AM) / "got off at" (PM)
        // Regular: "🚌 [X##] at Stop 2: Walking."
        let myStopLabel = (r.page == "pm") ? r.myStopPm : r.myStopAm
        var labelPart = stop.label
        if labelPart.hasPrefix("Stop ") { labelPart = String(labelPart.dropFirst(5)) }
        if let colonIdx = labelPart.firstIndex(of: ":") { labelPart = String(labelPart[..<colonIdx]).trimmingCharacters(in: .whitespaces) }
        if let parenIdx = labelPart.firstIndex(of: "(") { labelPart = String(labelPart[..<parenIdx]).trimmingCharacters(in: .whitespaces) }
        let isMyStop = !myStopLabel.isEmpty && myStopLabel == labelPart
        nativeLog("STOP", "Arrival: \(stop.label) myStop=\(isMyStop) final=\(isFinal)")
        // Per spec: device ID after emoji, e.g. "🚌 [A82] at Stop 1: Mia."
        let devTag = r.deviceId.isEmpty ? "" : " [" + r.deviceId + "]" + (r.deviceLabel.isEmpty ? "" : " (" + r.deviceLabel + ")")
        let msg: String
        let gotOff = isMyStop && r.page == "pm"
        if isMyStop {
            msg = (r.page == "pm")
                ? "📱\(devTag) got off at \(stop.label)."
                : "📱\(devTag) waiting at \(stop.label)."
        } else if isFinal {
            msg = "🚌\(devTag) at \(stop.label). Route complete."
        } else {
            msg = "🚌\(devTag) at \(stop.label)."
        }
        postArrivalNotification(message: msg)
        if r.followerOn && !r.topic.isEmpty {
            // The final stop tears down location updates right after this
            // (finishRide), which would let iOS suspend us before the POST
            // completes. A background task keeps us alive until it lands.
            var taskID: UIBackgroundTaskIdentifier = .invalid
            taskID = UIApplication.shared.beginBackgroundTask(withName: "ntfy-post") {
                UIApplication.shared.endBackgroundTask(taskID)
            }
            let fullMsg = msg // device ID already in message per spec
            NtfyClient.post(topic: r.topic, message: fullMsg) { [weak self] in
                DispatchQueue.main.async { self?.nativeLog("NTFY", "Sent: \(fullMsg)") }
                UIApplication.shared.endBackgroundTask(taskID)
                // Auto-stop on "got off" (PM My Stop): journey done.
                // Phase 2 (§7): the ride is marked ending=true BEFORE the
                // off-bus post, and the off-bus completion finalizes it as
                // ENDED (reason "got-off") — not finishRide()/completed —
                // but only if the ride state is exactly as captured, so an
                // interrupted or superseded teardown never clobbers a
                // newer state (reconcile rule (c) is the backstop).
                if gotOff {
                    let offMsg = "📱\(devTag) off bus. Tracking stopped."
                    var offTaskID: UIBackgroundTaskIdentifier = .invalid
                    offTaskID = UIApplication.shared.beginBackgroundTask(withName: "ntfy-offbus") {
                        UIApplication.shared.endBackgroundTask(offTaskID)
                    }
                    DispatchQueue.main.async {
                        guard let self = self, self.ride === r else {
                            UIApplication.shared.endBackgroundTask(offTaskID)
                            return
                        }
                        r.ending = true
                        self.persist()
                        let endingRideId = r.rideId
                        let endingRevision = r.revision
                        NtfyClient.post(topic: r.topic, message: offMsg) { [weak self] in
                            DispatchQueue.main.async { self?.nativeLog("NTFY", "Sent: \(offMsg)") }
                            UIApplication.shared.endBackgroundTask(offTaskID)
                            DispatchQueue.main.async {
                                guard let self = self else { return }
                                if self.ride === r, r.rideId == endingRideId,
                                   r.revision == endingRevision {
                                    r.ending = false
                                    r.ended = true
                                    r.endedAt = Int(Date().timeIntervalSince1970 * 1000)
                                    r.endReason = "got-off"
                                    r.revision += 1
                                    EndedStore.save(r)
                                    RideStore.clear()
                                    self.teardownLiveRide()
                                    self.nativeLog("SNAP", self.snapLogLine(ride: r, state: "ended"))
                                    self.jsEval?("if (typeof nativeNoRide === 'function') { try { nativeNoRide(); } catch(e){} }")
                                } else {
                                    self.nativeLog("SYS", "got-off finalize skipped (state changed)")
                                }
                            }
                        }
                    }
                }
            }
        } else {
            nativeLog("NTFY", "skipped followerOn=\(r.followerOn) topicSet=\(!r.topic.isEmpty)")
        }
        persist()
        pushSync(toast: "\(stop.label) reached")
        if firstUnreached(r) == -1 { finishRide() }
    }

    private func vibrate() {
        // Approximates Android's [260,120,260,120,420] waveform.
        AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            AudioServicesPlaySystemSound(kSystemSoundID_Vibrate)
        }
    }

    /// Quiet (no sound) local confirmation that tracking started, posted
    /// on the first GPS fix so it can include the real accuracy — the iOS
    /// counterpart of Android's foreground-service notification line.
    /// Local only: never sent to ntfy (follower formats stay untouched).
    private func postStartNotification(accuracy: Double, ride r: RideState) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Bus Stop Alerts"
        let route = r.page == "pm" ? "PM" : "AM"
        let reached = r.stops.filter { $0.reached }.count
        var body = "Tracking started — \(route) route · Stop \(reached) of \(r.stops.count) · ±\(Int(accuracy.rounded()))m"
        let next = firstUnreached(r)
        if next >= 0 { body += " · Next: \(r.stops[next].label)" }
        content.body = body
        content.sound = nil
        let req = UNNotificationRequest(
            identifier: Self.startNotificationID,
            content: content, trigger: nil)
        let isUpdate = startNotificationShownAccuracy != nil
        center.add(req) { error in
            if let error = error {
                self.nativeLog("SYS", "ride-start notification FAILED: \(error.localizedDescription)")
            } else {
                self.startNotificationShownAccuracy = Int(accuracy.rounded())
                self.nativeLog("SYS", "ride-start notification \(isUpdate ? "updated" : "posted"): \(body)")
            }
        }
    }

    private func postArrivalNotification(message: String) {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Bus Stop Alerts"
        content.body = message
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "bus.arrival.\(Int(Date().timeIntervalSince1970))",
            content: content, trigger: nil)
        center.add(req)
    }

    /// v46: tell the user when the off-stop check ends a scheduled
    /// ride (hard cutoff + notification). Mirrors
    /// postArrivalNotification; own identifier prefix.
    private func postOffStopNotification() {
        let center = UNUserNotificationCenter.current()
        center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        let content = UNMutableNotificationContent()
        content.title = "Bus Stop Alerts"
        content.body = "Scheduled ride ended — off time reached."
        content.sound = .default
        let req = UNNotificationRequest(
            identifier: "bus.schedoff.\(Int(Date().timeIntervalSince1970))",
            content: content, trigger: nil)
        center.add(req)
    }

    func pushSync(toast: String?) {
        guard let r = ride else { return }
        var payload: [String: Any] = [
            "reached": r.stops.map { $0.reached },
            "skipped": r.stops.map { $0.skipped },
            "next": firstUnreached(r)
        ]
        if let obs = onBusStop {
            payload["onBus"] = obs
            nativeLog("BUS-DETECT", "Sync includes onBus: \(obs)")
        }
        guard let data = try? JSONSerialization.data(withJSONObject: payload) else { return }
        let b64 = data.base64EncodedString()
        jsEval?("if (typeof nativeSync === 'function') { try { nativeSync('\(b64)',\(jsLiteral(toast))); } catch(e){} }")
    }

    /// Convergence helper for a freshly loaded page (mirrors Android
    /// MainActivity.pushCurrentStatus): pushes the native ride state, or
    /// tells the page no ride is active so it resets its UI.
    func pushSyncIfActive() {
        guard ride != nil else {
            jsEval?("if (typeof nativeNoRide === 'function') { try { nativeNoRide(); } catch(e){} }")
            return
        }
        pushSync(toast: nil)
    }

    private func jsLiteral(_ s: String?) -> String {
        guard let s = s else { return "null" }
        var out = "\""
        for ch in s {
            switch ch {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            default: out.append(ch)
            }
        }
        out += "\""
        return out
    }
}

// MARK: - CLLocationManagerDelegate

extension LocationTracker: CLLocationManagerDelegate {
    func locationManager(_ manager: CLLocationManager,
                         didUpdateLocations locations: [CLLocation]) {
        guard let loc = locations.last, let r = ride else { return }
        // horizontalAccuracy < 0 means invalid on iOS.
        guard loc.horizontalAccuracy >= 0 else { return }
        // v46: off-stop evaluation, throttled to once per Toronto
        // minute; if it ended the ride, this fix has nothing to do.
        let stamp = "\(torontoDayKey(Date()))-\(torontoMinutes(Date()))"
        if stamp != lastOffCheckStamp {
            lastOffCheckStamp = stamp
            if checkScheduleOff() { return }
        }
        handleLocation(loc, accuracy: loc.horizontalAccuracy, ride: r)
    }

    func locationManager(_ manager: CLLocationManager,
                         didFailWithError error: Error) {
        // Ignore transient GPS errors; the next fix will come.
        nativeLog("GPS", "error: \(error.localizedDescription)")
    }

    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        nativeLog("SYS", "auth changed: \(CLLocationManager.authorizationStatus().rawValue)")
        if CLLocationManager.authorizationStatus() == .authorizedAlways,
           let cfg = pendingConfig {
            pendingConfig = nil
            if startRide(configJson: cfg) == "started" {
                onAutoStarted?()
                pushSync(toast: nil)
            }
        }
    }
}
