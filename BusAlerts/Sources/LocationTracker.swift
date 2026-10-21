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
    private var nearCount = 0
    private var nearTargetIdx = -1
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

    /// Set by ViewController: evaluates JS in the page.
    var jsEval: ((String) -> Void)?
    /// Called when a permission-deferred ride auto-starts.
    var onAutoStarted: (() -> Void)?
    /// Page requested by tapping a schedule notification ("am"/"pm").
    var pendingScheduledTab: String?

    var isTracking: Bool { ride != nil }

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
    func startRide(configJson: String?, scheduled: Bool = false) -> String {
        nativeLog("SYS", "startRide scheduled=\(scheduled)")
        guard let configJson = configJson, !configJson.isEmpty,
              let data = configJson.data(using: .utf8),
              (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) != nil else {
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
        // Already tracking: refresh config but keep the service's progress
        // (safer than Android's ACTION_START, which could wipe progress with
        // the page's stale flags on a mid-ride reopen).
        applyConfig(jsonString: configJson, keepProgress: ride != nil)
        ride?.scheduledRide = scheduled
        beginTracking()
        nativeLog("SYS", "startRide: started stops=\(ride?.stops.count ?? 0)")
        return "started"
    }

    func stopRide() {
        nativeLog("SYS", "stopRide")
        guard ride != nil else { return }
        ride = nil
        nearCount = 0
        nearTargetIdx = -1
        manager.stopUpdatingLocation()
        RideStore.clear()
        jsEval?("if (typeof nativeNoRide === 'function') { try { nativeNoRide(); } catch(e){} }")
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
        // Always refresh the schedule (must survive with no active ride),
        // stop data only applies to a live ride — mirrors Android ACTION_UPDATE.
        ScheduleManager.shared.apply(config: cfg)
        if ride != nil {
            applyConfig(jsonString: configJson, keepProgress: true)
            pushSync(toast: nil)
        }
    }

    /// Status JSON for the WebView to resync; "" when no ride is active.
    /// A recently completed ride (within 15 min) is returned with
    /// active=false so the page can show the arrived UI after a background
    /// finish. Shape mirrors Android's getStatusJson(). The `page` field is
    /// how the pages detect a ride started for the OTHER route and stop it.
    func statusJson() -> String {
        if let r = ride, !r.stops.isEmpty {
            return statusPayload(ride: r, active: true)
        }
        if let r = RideStore.load(), !r.stops.isEmpty, r.completed {
            if let at = r.completedAt, Date().timeIntervalSince(at) < 15 * 60 {
                return statusPayload(ride: r, active: false)
            }
            // Expired: drop it so a fresh page shows no ride.
            RideStore.clear()
        }
        return ""
    }

    private func statusPayload(ride r: RideState, active: Bool) -> String {
        var payload: [String: Any] = [
            "active": active,
            "completed": r.completed,
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
        guard let data = try? JSONSerialization.data(withJSONObject: payload),
              let s = String(data: data, encoding: .utf8) else { return "" }
        return s
    }

    /// Resume a persisted ride on launch (mirrors Android's START_STICKY restart).
    /// A completed ride is for display only — never resume it as an active ride.
    func restore() {
        guard let r = RideStore.load(), !r.stops.isEmpty, !r.completed else { return }
        ride = r
        beginTracking()
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
        persist()
        manager.startUpdatingLocation()
    }

    private func persist() {
        if let r = ride { RideStore.save(r) }
    }

    private func firstUnreached(_ r: RideState) -> Int {
        for i in 0..<r.stops.count {
            if !r.stops[i].reached { return i }
        }
        return -1
    }

    private func finishRide() {
        nativeLog("SYS", "finishRide")
        // Keep the state marked completed (with a timestamp) instead of
        // deleting it, so the WebView can show the arrived UI on resume.
        if let r = ride {
            r.completed = true
            r.completedAt = Date()
            RideStore.save(r)
        }
        ride = nil
        nearCount = 0
        nearTargetIdx = -1
        manager.stopUpdatingLocation()
        jsEval?("if (typeof nativeFinished === 'function') { try { nativeFinished(); } catch(e){} }")
    }

    // MARK: - Arrival detection (port of TrackingService.handleLocation)

    private func handleLocation(_ loc: CLLocation, accuracy: Double, ride r: RideState) {
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
            arrive(at: idx)
        } else if distance <= 15 && accuracy <= 150 {
            // Very close to the pin — trust it even with moderate accuracy.
            arrive(at: idx)
        } else if accuracy <= 200 && distance <= stop.radius + accuracy {
            // Tier 2: poor accuracy (phone pocketed) — 3 consecutive fixes
            // near the stop confirm the arrival. A GPS jump won't persist.
            if nearTargetIdx != idx { nearTargetIdx = idx; nearCount = 0 }
            nearCount += 1
            if nearCount >= 3 {
                nearCount = 0
                nearTargetIdx = -1
                arrive(at: idx)
            }
        } else {
            nearCount = 0
            nearTargetIdx = -1
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
                    nativeLog("NTFY", "Sending on-bus: \(msg)")
                    NtfyClient.post(topic: r.topic, message: msg) { }
                    onBusStop = next.label
                    pushSync(toast: nil)
                }
            }
        }
        if shouldLog { lastCpLogAt = now }
    }

    private func arrive(at idx: Int) {
        guard let r = ride, idx < r.stops.count else { return }
        nearCount = 0
        nearTargetIdx = -1
        onBusStop = nil
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
                if gotOff {
                    let offMsg = "📱\(devTag) off bus. Tracking stopped."
                    var offTaskID: UIBackgroundTaskIdentifier = .invalid
                    offTaskID = UIApplication.shared.beginBackgroundTask(withName: "ntfy-offbus") {
                        UIApplication.shared.endBackgroundTask(offTaskID)
                    }
                    NtfyClient.post(topic: r.topic, message: offMsg) { [weak self] in
                        DispatchQueue.main.async { self?.nativeLog("NTFY", "Sent: \(offMsg)") }
                        UIApplication.shared.endBackgroundTask(offTaskID)
                        DispatchQueue.main.async { self?.finishRide() }
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
