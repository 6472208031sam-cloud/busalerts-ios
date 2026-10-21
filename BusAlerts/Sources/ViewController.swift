import UIKit
import WebKit

/// Single full-screen WKWebView over the live Bus Stop Alerts page.
/// Mirrors Android's MainActivity and the St Cecilia app: ONE page
/// (index.html) hosts both routes as tabs — the native side owns background
/// tracking and feeds the page through the NativeBridge shim. There is no
/// per-route page and no AM/PM navigation: a scheduled ride starts natively
/// from the stored config for its route, and the page adopts the ride's tab
/// via getStatus()/pushSync.
class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    static weak var shared: ViewController?

    private static let pageBase = "https://6472208031sam-cloud.github.io/bus-stop-alerts/"

    private var webView: WKWebView!

    override func viewDidLoad() {
        super.viewDidLoad()
        ViewController.shared = self

        let config = WKWebViewConfiguration()
        let shim = WKUserScript(source: NativeBridge.shimSource,
                                injectionTime: .atDocumentStart,
                                forMainFrameOnly: true)
        config.userContentController.addUserScript(shim)

        webView = WKWebView(frame: view.bounds, configuration: config)
        webView.navigationDelegate = self
        webView.uiDelegate = self
        webView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(webView)

        LocationTracker.shared.jsEval = { [weak self] js in
            DispatchQueue.main.async {
                self?.webView.evaluateJavaScript(js, completionHandler: nil)
            }
        }
        LocationTracker.shared.onAutoStarted = { [weak self] in
            self?.eval("if (typeof nativeAutoStarted === 'function') { try { nativeAutoStarted(); } catch(e){} }")
        }

        // Load the single page (with a cache-buster like Android's
        // MainActivity — the hosted page changes often: alert channel,
        // tuning). A pending schedule tap is handled after load by
        // startScheduledRideIfPending(); the route never comes from the URL.
        var comps = URLComponents(string: Self.pageBase)!
        comps.queryItems = [URLQueryItem(name: "v", value: "\(Int(Date().timeIntervalSince1970))")]
        webView.load(URLRequest(url: comps.url!))
    }

    // MARK: - Page lifecycle (mirrors MainActivity)

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // The page arms its own schedule on open (pushScheduleToNative) and
        // syncs with any active native ride via getStatus(), adopting the
        // ride's tab — same as Android. Here we only handle the leftovers:
        // a tapped schedule notification, and auto-start on launch.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            if !self.startScheduledRideIfPending() {
                LocationTracker.shared.pushSyncIfActive()
                // Auto-start tracking on launch (matches Android).
                self.eval("(function(){ try { if (typeof startTracking==='function') startTracking(); } catch(e){} })()")
            }
        }
    }

    /// Starts the ride for the route named by a tapped schedule
    /// notification, from the stored config for that route — no page
    /// navigation (the single page hosts both routes and adopts the ride's
    /// tab from the sync that follows). Returns true if the tap was
    /// consumed. The pending tab is consumed exactly once, and a running
    /// ride is never clobbered (mirrors Android's ACTION_SCHEDULE_START,
    /// which ignores the alarm while tracking): if a ride is already
    /// active — same route or not — the tap just resyncs the page to it.
    @discardableResult
    func startScheduledRideIfPending() -> Bool {
        guard let page = LocationTracker.shared.pendingScheduledTab else { return false }
        LocationTracker.shared.pendingScheduledTab = nil
        if LocationTracker.shared.isTracking {
            LocationTracker.shared.pushSyncIfActive()
            return true
        }
        guard let cfg = ScheduleManager.shared.configJSON(forPage: page),
              LocationTracker.shared.startRide(configJson: cfg, scheduled: true) == "started"
        else { return false }
        eval("if (typeof nativeAutoStarted === 'function') { try { nativeAutoStarted(); } catch(e){} }")
        LocationTracker.shared.pushSync(toast: nil)
        return true
    }

    private func eval(_ js: String) {
        webView.evaluateJavaScript(js, completionHandler: nil)
    }

    // MARK: - NativeBridge prompt interception

    func webView(_ webView: WKWebView,
                 runJavaScriptTextInputPanelWithPrompt prompt: String,
                 defaultText: String?,
                 initiatedByFrame frame: WKFrameInfo,
                 completionHandler: @escaping (String?) -> Void) {
        if prompt.hasPrefix(NativeBridge.promptPrefix) {
            completionHandler(NativeBridge.shared.handle(prompt: prompt))
        } else {
            // Not a NativeBridge call — show a real input dialog (e.g. device label).
            let alert = UIAlertController(title: nil, message: prompt, preferredStyle: .alert)
            alert.addTextField { tf in tf.text = defaultText }
            alert.addAction(UIAlertAction(title: "Cancel", style: .cancel) { _ in completionHandler(nil) })
            alert.addAction(UIAlertAction(title: "OK", style: .default) { _ in
                completionHandler(alert.textFields?.first?.text)
            })
            present(alert, animated: true, completion: nil)
        }
    }
}
