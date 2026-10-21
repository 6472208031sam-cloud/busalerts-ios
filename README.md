# Bus Stop Alerts — iOS app (cloud-built)

Native iOS version of the Bus Stop Alerts bus-tracking app (sibling of the
[St Cecilia iOS app](https://github.com/6472208031sam-cloud/stcecilia-ios),
same architecture).
There is no Mac involved: the app is compiled on GitHub Actions macOS runners.

## What it is

- **Bundle ID** `io.github.busstopalerts`, display name **Bus Stop Alerts**, version 1.0 (build 1).
- One full-screen `WKWebView` loading the live page
  `https://6472208031sam-cloud.github.io/bus-stop-alerts/` — the page is the
  entire UI, exactly like the Android app. Both routes live on that single
  page as tabs; AM/PM never changes the URL (v30 removed the old pm.html
  loader — the route is chosen by ride config, not by page).
- A native background location tracker (`LocationTracker.swift`) ports the
  Android `TrackingService` logic 1:1:
  - `CLLocationManager` with `allowsBackgroundLocationUpdates`, best accuracy,
    5 m distance filter, automotive-navigation activity type.
  - Strictly sequential arrival detection; snap-forward **only at ride start**
    (mid-ride snapping once caused a false B→L jump skipping C–K — never
    reintroduced).
  - Two-tier arrival: confident fixes arrive immediately; poor-accuracy fixes
    (±80–200 m, phone pocketed) confirm after 3 consecutive fixes near the stop.
  - On arrival: 660/660/880 Hz beep (if sound enabled — the pages' 🔊 toggle;
    the AM page predates the toggle and defaults to on), vibration, POST to
    the ntfy.sh topic with the exact Android message formats
    (`🚌 Stop 10 reached.` / `🚌 Stop L (7) reached.` /
    `🚌 Final stop reached (AM/PM): <name>.`), plus a local notification so
    backgrounded arrivals are visible.
  - Ride state persisted to `UserDefaults`; restored on launch.
  - Cross-route behavior mirrors Android: the page checks `getStatus()` on
    load and adopts the tab of a native ride already running (`page` "am"
    vs "pm") — it never stops a running ride for being on the other route.
- `window.NativeBridge` exposes the **same interface as Android**
  (`startRide` → `"started"`/`"permission_needed"`/`"error"`, `stopRide`,
  `updateConfig`, `getStatus`, `hasBackgroundPermission`).
  - Implementation detail: iOS's `window.webkit.messageHandlers` cannot return
    values synchronously, but the pages read these returns synchronously (like
    Android's `@JavascriptInterface`). The shim therefore routes calls through
    a `prompt()` interception handled by the Swift `WKUIDelegate`, which runs
    each call synchronously and returns a JSON response. Same interface, same
    semantics.

## iOS schedule limitation (read this)

Android can fire exact alarms with the phone locked and auto-start tracking.
**iOS cannot.** An iOS app is not allowed to wake itself at 8:00 AM and start
GPS in the background.

The honest approximation implemented here: when a page pushes its schedule
config, the app arms **local notifications** at the configured on-times
(Toronto time, weekdays-only respected) saying *"Time for the morning/afternoon
route — tap to start tracking."* Tapping the notification opens the app and
starts the ride from the stored config for that route (AM or PM) — no page
navigation is involved. The schedule toggle and times are still configured
on the web pages, exactly as on Android. There is no off-alarm on iOS.

## The .ipa is unsigned

The CI build archives with `CODE_SIGNING_ALLOWED=NO` and zips an **unsigned**
`.ipa` as a workflow artifact. An unsigned ipa **cannot be installed** on a
stock iPhone — install it with Sideloadly (free Apple ID, refresh every 7 days)
or sign it for TestFlight (below).

### Remaining step for TestFlight

1. Join the **Apple Developer Program** ($99 USD/year).
2. In Xcode (or via the CI job extended with signing), archive with your
   development team / provisioning profile and upload to App Store Connect.
3. Add testers in TestFlight — internal testers get builds in ~1–3 hours with
   no review; the first external build needs a light beta review (~1–3 days).

For a personal app, **TestFlight (not the App Store)** is the right target:
invite-only, fast updates, no full App Store review. Builds expire after 90
days, so re-upload a few times a year.

## Building

Pushes to `main` (or the manual **Run workflow** button) trigger
`.github/workflows/build.yml`: install xcodegen → generate the Xcode project
→ unsigned archive → `.ipa` artifact.

Note: the GitHub token used for automation cannot push workflow files, so
`.github/workflows/build.yml` was added via the web UI, not by the build
script. If you re-create it, upload it manually the same way.

## File layout

```
BusAlerts/
  Sources/
    AppDelegate.swift         launch, ride restore, schedule-notification taps
    ViewController.swift      full-screen WKWebView, AM/PM pages, prompt bridge
    NativeBridge.swift        window.NativeBridge shim (prompt interception)
    LocationTracker.swift     background GPS + arrival detection + alerts
    RideStore.swift           ride config/state models + UserDefaults persistence
    AlertPlayer.swift         660/660/880 Hz beep synthesis (AVAudioEngine)
    NtfyClient.swift          ntfy.sh POST
    ScheduleManager.swift     "tap to start" local notifications (Toronto time)
project.yml                   xcodegen spec (generates Info.plist from properties)
.github/workflows/build.yml  cloud Mac builder
```
