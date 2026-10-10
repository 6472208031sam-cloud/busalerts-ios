import UIKit
import WebKit

/// Single full-screen WKWebView over the live Bus Stop Alerts pages.
/// Mirrors Android's MainActivity: the pages are the entire UI, the native
/// side owns background tracking and feeds the page through the NativeBridge
/// shim. The AM/PM switcher navigates between index.html and pm.html inside
/// this WebView; the pages themselves stop a mismatched native ride via
/// getStatus() (page check), exactly like on Android.
class ViewController: UIViewController, WKNavigationDelegate, WKUIDelegate {
    static weak var shared: ViewController?

    private static let amBase = "https://6472208031sam-cloud.github.io/bus-stop-alerts/"
    private static let pmBase = "https://6472208031sam-cloud.github.io/bus-stop-alerts/pm.html"

    private var webView: WKWebView!
    /// "am" or "pm" — which page is currently loaded.
    private var currentPage = "am"

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

        // Cold start from a schedule notification goes straight to that page.
        loadPage(LocationTracker.shared.pendingScheduledPage ?? "am")
    }

    /// Loads the AM or PM page, with a cache-buster like Android's
    /// MainActivity (the hosted pages change often: alert channel, tuning).
    func loadPage(_ page: String) {
        currentPage = (page == "pm") ? "pm" : "am"
        let base = currentPage == "pm" ? Self.pmBase : Self.amBase
        var comps = URLComponents(string: base)!
        comps.queryItems = [URLQueryItem(name: "v", value: "\(Int(Date().timeIntervalSince1970))")]
        webView.load(URLRequest(url: comps.url!))
    }

    // MARK: - Page lifecycle (mirrors MainActivity)

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        // Track which page actually loaded (the user may have used the
        // in-page AM/PM switcher since the last load).
        if let url = webView.url?.absoluteString, url.contains("pm.html") {
            currentPage = "pm"
        } else {
            currentPage = "am"
        }
        // The page arms its own schedule on open (pushScheduleToNative) and
        // stops a mismatched native ride via getStatus() — same as Android.
        // Here we only handle the leftovers: a tapped schedule notification,
        // and a native ride the freshly loaded page hasn't synced with yet.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
            guard let self = self else { return }
            if !self.startScheduledRideIfPending() {
                LocationTracker.shared.pushSyncIfActive()
            }
        }
    }

    /// Starts the ride for the page named by a tapped schedule notification.
    /// Returns true if the tap was consumed (ride started or navigation begun).
    @discardableResult
    func startScheduledRideIfPending() -> Bool {
        guard let page = LocationTracker.shared.pendingScheduledPage else { return false }
        // Wrong page loaded: navigate there first; didFinish re-runs this.
        if page != currentPage {
            loadPage(page)
            return true
        }
        LocationTracker.shared.pendingScheduledPage = nil
        // Never clobber an already-running ride (mirrors Android's
        // ACTION_SCHEDULE_START, which ignores the alarm while tracking).
        guard !LocationTracker.shared.isTracking,
              let cfg = ScheduleManager.shared.configJSON(forPage: page),
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
            // Not ours — mimic the default behavior.
            completionHandler(defaultText)
        }
    }
}
