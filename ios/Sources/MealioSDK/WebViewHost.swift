// The real Host on iOS.
//
// - One hidden WKWebView per WebViewHost holds the store session. It uses the
//   default persistent WKWebsiteDataStore, so a store login survives app
//   restarts, and the login sheet (a second, visible WKWebView on the same
//   data store) shares its cookies.
// - Both WebViews get BRIDGE_SHIM at document start, so store scripts can call
//   window.ReactNativeWebView.postMessage(...) as they do on React Native. The
//   shim calls window.__mealioNativePost, which a small script defines to
//   forward to the WKScriptMessageHandler named "mealio".
// - `fetch` runs through URLSession with the store's cookies copied from the
//   WebView cookie store for that request's host.

#if canImport(UIKit) && canImport(WebKit)
import UIKit
import WebKit

/// Plain constants, kept outside the @MainActor class so any context can read them.
enum Bridge {
    /// Name of the WKScriptMessageHandler both WebViews post to.
    static let messageHandlerName = "mealio"

    /// Defines the shim's call target. Runs at document start, before the shim.
    static let nativePostScript = """
    (function(){
      window.__mealioNativePost = function (s) { window.webkit.messageHandlers.mealio.postMessage(String(s)); };
    })(); true;
    """
}

@MainActor
public final class WebViewHost: NSObject, MealioHost {
    public typealias Presenter = @MainActor () -> UIViewController?

    private let presenter: Presenter

    /// Main-frame navigations of the hidden WebView are checked with this.
    /// MealioCart sets it to the same allowlist check `page_open` uses, so a
    /// redirect inside the hidden page cannot leave the store's hosts.
    var hiddenNavigationPolicy: ((_ store: String, _ url: String) -> Bool)?

    private var hidden: WKWebView?
    private var hiddenStore = ""
    private var pendingLoad: ResumeOnce<PageOpenOutcome>?
    private var loadTimer: Task<Void, Never>?
    private var scriptListener: ((JSONMessage) -> Void)?
    private var cachedUserAgent: String?

    private lazy var fetchSession: URLSession = {
        // The SDK's own cookie handling: nothing is stored by URLSession, the
        // Cookie header is built from the WebView's store for each request.
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        return URLSession(configuration: c, delegate: RedirectGuard(), delegateQueue: nil)
    }()

    /// - Parameter presenter: Returns the view controller to present the login
    ///   sheet from. Defaults to the key window's top-most view controller.
    public init(presenter: Presenter? = nil) {
        self.presenter = presenter ?? { WebViewHost.topViewController() }
        super.init()
    }

    // MARK: - Configuration shared by both WebViews

    static func makeConfiguration(handler: WKScriptMessageHandler) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: Bridge.nativePostScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: MealioScripts.bridgeShim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.add(handler, name: Bridge.messageHandlerName)
        config.userContentController = content
        return config
    }

    private func hiddenWebView() -> WKWebView {
        if let web = hidden { return web }
        let handler = ScriptHandler { [weak self] body in self?.hiddenMessage(body) }
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1), configuration: WebViewHost.makeConfiguration(handler: handler))
        web.navigationDelegate = self
        web.isUserInteractionEnabled = false
        web.alpha = 0.01
        // VERIFY: a WKWebView that is not in a window can be throttled by
        // WebKit (timers slowed, loads stalled). Parking it, nearly invisible,
        // behind the key window's content keeps it running.
        if let window = WebViewHost.keyWindow() {
            window.addSubview(web)
            window.sendSubviewToBack(web)
        }
        hidden = web
        return web
    }

    private func hiddenMessage(_ body: Any) {
        guard let msg = parseMessage(body) else { return }
        scriptListener?(msg)
    }

    /// Drop the hidden page (after a sign-out, so nothing of the old session
    /// stays in memory). The next page_open makes a fresh one.
    public func resetHiddenPage() {
        pendingLoad?.resume(PageOpenOutcome(ok: false, error: "load_failed"))
        loadTimer?.cancel()
        scriptListener = nil
        if let web = hidden {
            web.stopLoading()
            web.navigationDelegate = nil
            web.configuration.userContentController.removeScriptMessageHandler(forName: Bridge.messageHandlerName)
            web.removeFromSuperview()
        }
        hidden = nil
    }

    // MARK: - page_open

    public func openPage(store: String, url: String, timeoutMs: Int) async throws -> PageOpenOutcome {
        guard let target = URL(string: url) else { return PageOpenOutcome(ok: false, error: "load_failed") }
        let web = hiddenWebView()
        hiddenStore = store
        // A load still waiting from before is superseded.
        pendingLoad?.resume(PageOpenOutcome(ok: false, error: "load_failed"))
        loadTimer?.cancel()

        let outcome: PageOpenOutcome = await withCheckedContinuation { cont in
            let once = ResumeOnce(cont)
            pendingLoad = once
            web.load(URLRequest(url: target))
            loadTimer = after(timeoutMs) { [weak web] in
                if once.resume(PageOpenOutcome(ok: false, finalUrl: web?.url?.absoluteString, error: "timeout")) {
                    web?.stopLoading()
                }
            }
        }
        loadTimer?.cancel()
        loadTimer = nil
        if pendingLoad?.isDone == true { pendingLoad = nil }
        return outcome
    }

    // MARK: - page_script

    public func runScript(store: String, guardScript: String, script: String, until: [Matcher], timeoutMs: Int) async throws -> ScriptOutcome {
        guard let web = hidden, web.url != nil else {
            return ScriptOutcome(messages: [], timedOut: false, error: "no_page")
        }
        let box = MessageBox()
        var timer: Task<Void, Never>?
        let outcome: ScriptOutcome = await withCheckedContinuation { cont in
            let once = ResumeOnce(cont)
            // Listen before injecting, so a message the guard or the script
            // posts straight away is not missed.
            scriptListener = { msg in
                box.messages.append(msg)
                if matchesAny(msg, until) {
                    once.resume(ScriptOutcome(messages: box.messages, timedOut: false))
                }
            }
            timer = after(timeoutMs) {
                once.resume(ScriptOutcome(messages: box.messages, timedOut: true))
            }
            // Results and JS exceptions are ignored, as React Native's
            // injectJavaScript ignores them. Scripts report through messages.
            web.evaluateJavaScript(guardScript, completionHandler: nil)
            web.evaluateJavaScript(script, completionHandler: nil)
        }
        timer?.cancel()
        scriptListener = nil
        return outcome
    }

    // MARK: - show_login

    public func showLogin(_ request: LoginRequest) async throws -> LoginOutcome {
        guard let from = presenter() else {
            throw MealioError(code: MealioError.Code.unsupported, message: "No view controller to present the store login from")
        }
        guard let url = URL(string: request.url) else {
            throw MealioError(code: MealioError.Code.blocked, message: "The login URL is not valid")
        }
        let sheet = LoginSheet(request: request)
        return await sheet.run(from: from, url: url)
    }

    // MARK: - fetch

    public func fetch(store: String, request: FetchRequest, timeoutMs: Int, maxBytes: Int) async throws -> FetchOutcome {
        guard let url = URL(string: request.url), url.scheme?.lowercased() == "https" else {
            return FetchOutcome(ok: false, error: "bad_url")
        }
        var req = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData,
                             timeoutInterval: max(1, Double(timeoutMs) / 1000))
        let method = request.method.uppercased()
        req.httpMethod = method
        for (name, value) in request.headers ?? [:] {
            req.setValue(value, forHTTPHeaderField: name)
        }
        if let body = request.body, method != "GET", method != "HEAD" {
            req.httpBody = Data(body.utf8)
        }

        // The store's cookies, from the same store the WebViews use.
        let jar = await WebViewHost.cookies(for: url)
        if !jar.isEmpty {
            let ours = HTTPCookie.requestHeaderFields(with: jar)["Cookie"] ?? ""
            let theirs = req.value(forHTTPHeaderField: "Cookie") ?? ""
            let joined = [ours, theirs].filter { !$0.isEmpty }.joined(separator: "; ")
            req.setValue(joined, forHTTPHeaderField: "Cookie")
        }
        // Look like the WebView that holds the session, unless told otherwise.
        if req.value(forHTTPHeaderField: "User-Agent") == nil, let ua = await userAgent() {
            req.setValue(ua, forHTTPHeaderField: "User-Agent")
        }

        let session = fetchSession
        let finalRequest = req
        let (data, response, error): (Data?, URLResponse?, Error?) = await withCheckedContinuation { cont in
            let once = ResumeOnce(cont)
            let task = session.dataTask(with: finalRequest) { d, r, e in
                once.resume((d, r, e))
            }
            task.resume()
            // timeoutInterval on the request is an idle timeout. This is the
            // total time the instruction allows.
            DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(max(timeoutMs, 0))) {
                if once.resume((nil, nil, URLError(.timedOut))) { task.cancel() }
            }
        }

        guard let http = response as? HTTPURLResponse else {
            let timedOut = (error as? URLError)?.code == .timedOut
            return FetchOutcome(ok: false, error: timedOut ? "timeout" : "no_response")
        }

        var headers: [String: String] = [:]
        var rawFields: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            guard let name = k as? String else { continue }
            let value = "\(v)"
            rawFields[name] = value
            // Like a browser fetch, cookies the store sets are not handed back
            // to the server. They go into the WebView's cookie store instead.
            if name.lowercased() == "set-cookie" { continue }
            headers[name.lowercased()] = value
        }
        await WebViewHost.storeCookies(HTTPCookie.cookies(withResponseHeaderFields: rawFields, for: http.url ?? url))

        var bytes = data ?? Data()
        var truncated = false
        if maxBytes >= 0 && bytes.count > maxBytes {
            bytes = bytes.prefix(maxBytes)
            truncated = true
        }
        // A cut can split a multi-byte character; it decodes as U+FFFD.
        let body = String(decoding: bytes, as: UTF8.self)
        return FetchOutcome(ok: true, status: http.statusCode, headers: headers, body: body, truncated: truncated)
    }

    private func userAgent() async -> String? {
        if let ua = cachedUserAgent { return ua }
        let web = hiddenWebView()
        // VERIFY: evaluateJavaScript on a WebView that has not loaded a page
        // yet runs against about:blank and still returns navigator.userAgent.
        let ua: String? = await withCheckedContinuation { cont in
            web.evaluateJavaScript("navigator.userAgent") { result, _ in
                cont.resume(returning: result as? String)
            }
        }
        cachedUserAgent = ua
        return ua
    }

    // MARK: - Cookies and website data

    static func cookies(for url: URL) async -> [HTTPCookie] {
        let all: [HTTPCookie] = await withCheckedContinuation { cont in
            WKWebsiteDataStore.default().httpCookieStore.getAllCookies { cookies in
                cont.resume(returning: cookies)
            }
        }
        return all.filter { cookie($0, appliesTo: url) }
    }

    /// Domain, path, secure and expiry match for one cookie.
    static func cookie(_ c: HTTPCookie, appliesTo url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        var domain = c.domain.lowercased()
        if domain.hasPrefix(".") { domain.removeFirst() }
        // VERIFY: HTTPCookie marks domain cookies with a leading dot and
        // host-only cookies without one. Host-only cookies are matched to
        // subdomains here too. That can over-send within one store's domain,
        // never across domains, and it avoids missing a session cookie.
        guard host == domain || host.hasSuffix("." + domain) else { return false }
        let requestPath = url.path.isEmpty ? "/" : url.path
        let cookiePath = c.path.isEmpty ? "/" : c.path
        let pathOK = requestPath == cookiePath
            || (requestPath.hasPrefix(cookiePath)
                && (cookiePath.hasSuffix("/") || requestPath.dropFirst(cookiePath.count).first == "/"))
        guard pathOK else { return false }
        if c.isSecure && url.scheme?.lowercased() != "https" { return false }
        if let expires = c.expiresDate, expires < Date() { return false }
        return true
    }

    static func storeCookies(_ cookies: [HTTPCookie]) async {
        let store = WKWebsiteDataStore.default().httpCookieStore
        for c in cookies {
            await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
                store.setCookie(c) { cont.resume() }
            }
        }
    }

    /// Remove every kind of website data (cookies, storage, caches) whose
    /// record belongs to one of `domains` (registrable domains like "heb.com").
    /// Only these domains are touched, so the app's own web content is left alone.
    public static func clearWebsiteData(forDomains domains: Set<String>) async {
        guard !domains.isEmpty else { return }
        let store = WKWebsiteDataStore.default()
        let types = WKWebsiteDataStore.allWebsiteDataTypes()
        let records: [WKWebsiteDataRecord] = await withCheckedContinuation { cont in
            store.fetchDataRecords(ofTypes: types) { cont.resume(returning: $0) }
        }
        // VERIFY: WKWebsiteDataRecord.displayName is the registrable domain
        // ("heb.com"). registrableDomain() is applied anyway in case it is not.
        let targets = records.filter { domains.contains(Allowlist.registrableDomain($0.displayName)) }
        guard !targets.isEmpty else { return }
        await withCheckedContinuation { (cont: CheckedContinuation<Void, Never>) in
            store.removeData(ofTypes: types, for: targets) { cont.resume() }
        }
    }

    // MARK: - Finding a presenter

    static func keyWindow() -> UIWindow? {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        let active = scenes.filter { $0.activationState == .foregroundActive }
        let windows = (active.isEmpty ? scenes : active).flatMap { $0.windows }
        return windows.first { $0.isKeyWindow } ?? windows.first
    }

    /// The key window's top-most view controller.
    public static func topViewController() -> UIViewController? {
        var top = keyWindow()?.rootViewController
        while let current = top {
            if let presented = current.presentedViewController, !presented.isBeingDismissed {
                top = presented
            } else if let nav = current as? UINavigationController, let child = nav.topViewController {
                top = child
            } else if let tabs = current as? UITabBarController, let child = tabs.selectedViewController {
                top = child
            } else {
                break
            }
        }
        return top
    }
}

// MARK: - Hidden WebView navigation

extension WebViewHost: WKNavigationDelegate {
    // VERIFY: these delegate signatures match the SDK's WKNavigationDelegate
    // (Xcode 15 imports it as @MainActor; the closure parameter may carry
    // @MainActor/@Sendable, which Swift 5 mode accepts for this form).
    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        guard navigationAction.targetFrame?.isMainFrame == true, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let s = url.absoluteString
        if s == "about:blank" || (hiddenNavigationPolicy?(hiddenStore, s) ?? true) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            pendingLoad?.resume(PageOpenOutcome(ok: false, finalUrl: s, error: "blocked"))
        }
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pendingLoad?.resume(PageOpenOutcome(ok: true, finalUrl: webView.url?.absoluteString))
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        loadFailed(error)
    }

    private func loadFailed(_ error: Error) {
        // A cancelled load is usually a page replacing itself with a new
        // navigation (a JS redirect). Wait for that one instead.
        let ns = error as NSError
        if ns.domain == NSURLErrorDomain && ns.code == NSURLErrorCancelled { return }
        pendingLoad?.resume(PageOpenOutcome(ok: false, finalUrl: hidden?.url?.absoluteString, error: "load_failed"))
    }
}

// MARK: - Login sheet

/// One show_login: a visible WKWebView in a modal sheet, on the same data store
/// as the hidden WebView.
@MainActor
final class LoginSheet: NSObject, WKNavigationDelegate, WKUIDelegate, UIAdaptivePresentationControllerDelegate {
    private let request: LoginRequest
    private let doneUrlRegex: NSRegularExpression?
    private let webView: WKWebView
    private var nav: UINavigationController?
    private var once: ResumeOnce<LoginOutcome>?
    private var messages: [JSONMessage] = []
    private var timers: [Task<Void, Never>] = []
    private var finished = false
    /// A navigation matching doneWhenUrl is loading; finish when it lands.
    private var doneUrlLoading = false

    init(request: LoginRequest) {
        self.request = request
        if let source = request.doneWhenUrl, !source.isEmpty {
            // A JS regex source with no flags. Most sources mean the same in
            // ICU; one that does not compile is ignored.
            doneUrlRegex = try? NSRegularExpression(pattern: source)
        } else {
            doneUrlRegex = nil
        }
        let proxy = ScriptHandler()
        webView = WKWebView(frame: .zero, configuration: WebViewHost.makeConfiguration(handler: proxy))
        super.init()
        proxy.onMessage = { [weak self] body in self?.received(body) }
        webView.navigationDelegate = self
        webView.uiDelegate = self
    }

    func run(from presenter: UIViewController, url: URL) async -> LoginOutcome {
        await withCheckedContinuation { cont in
            once = ResumeOnce(cont)
            let screen = LoginViewController(title: request.title, webView: webView) { [weak self] in
                self?.finish(.cancelled)
            }
            let nav = UINavigationController(rootViewController: screen)
            nav.presentationController?.delegate = self
            self.nav = nav
            presenter.present(nav, animated: true)
            webView.load(URLRequest(url: url))

            timers.append(after(request.timeoutMs) { [weak self] in self?.finish(.timeout) })
            if let check = request.check {
                let interval = max(check.intervalMs, 250)
                timers.append(Task { @MainActor [weak self] in
                    while true {
                        do { try await Task.sleep(nanoseconds: nanoseconds(interval)) } catch { return }
                        guard let self = self, !self.finished else { return }
                        self.inject()
                    }
                })
            }
        }
    }

    /// GUARD_SCRIPT, then the check script.
    private func inject() {
        webView.evaluateJavaScript(request.guardScript, completionHandler: nil)
        if let check = request.check {
            webView.evaluateJavaScript(check.script, completionHandler: nil)
        }
    }

    private func received(_ body: Any) {
        guard !finished, let msg = parseMessage(body) else { return }
        messages.append(msg)
        if matchesAny(msg, request.doneWhen) { finish(.signedIn) }
    }

    private func matchesDoneUrl(_ url: String) -> Bool {
        guard let re = doneUrlRegex else { return false }
        let ns = url as NSString
        return re.firstMatch(in: url, options: [], range: NSRange(location: 0, length: ns.length)) != nil
    }

    private func finish(_ kind: LoginOutcomeKind) {
        guard !finished else { return }
        finished = true
        timers.forEach { $0.cancel() }
        timers.removeAll()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Bridge.messageHandlerName)
        let outcome = LoginOutcome(outcome: kind, messages: messages)
        let once = self.once
        if let nav = nav, nav.presentingViewController != nil {
            nav.dismiss(animated: true) { once?.resume(outcome) }
            // If the dismissal never reports back, do not hang the run.
            _ = after(1500) { once?.resume(outcome) }
        } else {
            once?.resume(outcome)
        }
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if finished { decisionHandler(.cancel); return }
        // Only top-frame navigations are checked. Captcha and consent iframes
        // inside a store page are not navigations of the sheet.
        let isMainFrame = navigationAction.targetFrame?.isMainFrame ?? true
        guard isMainFrame, let url = navigationAction.request.url else {
            decisionHandler(.allow)
            return
        }
        let s = url.absoluteString
        if s == "about:blank" { decisionHandler(.allow); return }
        let allowed = request.allowNavigation(s)
        if matchesDoneUrl(s) {
            if allowed {
                // Let the return page load (the server may need to see it),
                // then finish. The timer covers a load that never lands.
                doneUrlLoading = true
                decisionHandler(.allow)
                timers.append(after(5000) { [weak self] in self?.finish(.signedIn) })
            } else {
                // The URL alone is the signal (for example an app-scheme return).
                decisionHandler(.cancel)
                finish(.signedIn)
            }
            return
        }
        decisionHandler(allowed ? .allow : .cancel)
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard !finished else { return }
        inject()
        if doneUrlLoading || matchesDoneUrl(webView.url?.absoluteString ?? "") {
            finish(.signedIn)
        }
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        if doneUrlLoading { finish(.signedIn) }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        if doneUrlLoading { finish(.signedIn) }
    }

    // MARK: WKUIDelegate

    /// A link or window.open that asks for a new window loads in the sheet
    /// instead, so it still goes through the allowlist check above.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        if navigationAction.targetFrame == nil, navigationAction.request.url != nil {
            webView.load(navigationAction.request)
        }
        return nil
    }

    // MARK: UIAdaptivePresentationControllerDelegate

    /// The user swiped the sheet away.
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        finish(.cancelled)
    }
}

/// The sheet's screen: the store's page, its title, and a Close button.
final class LoginViewController: UIViewController {
    private let webView: WKWebView
    private let onClose: () -> Void

    init(title: String, webView: WKWebView, onClose: @escaping () -> Void) {
        self.webView = webView
        self.onClose = onClose
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) is not used")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .systemBackground
        navigationItem.largeTitleDisplayMode = .never
        navigationItem.leftBarButtonItem = UIBarButtonItem(barButtonSystemItem: .close, target: self, action: #selector(closeTapped))
        webView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
    }

    @objc private func closeTapped() {
        onClose()
    }
}

// MARK: - Helpers

/// Forwards script messages to a closure. WKUserContentController keeps its
/// handlers strongly, so this proxy (holding its owner weakly through the
/// closure) breaks the retain cycle.
@MainActor
final class ScriptHandler: NSObject, WKScriptMessageHandler {
    var onMessage: ((Any) -> Void)?

    init(_ onMessage: ((Any) -> Void)? = nil) {
        self.onMessage = onMessage
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        onMessage?(message.body)
    }
}

/// Messages collected by one runScript.
final class MessageBox {
    var messages: [JSONMessage] = []
}

/// Run `body` on the main actor after `ms` milliseconds, unless cancelled first.
@MainActor
@discardableResult
func after(_ ms: Int, _ body: @escaping @MainActor () -> Void) -> Task<Void, Never> {
    Task { @MainActor in
        do { try await Task.sleep(nanoseconds: nanoseconds(ms)) } catch { return }
        body()
    }
}

/// Follows a redirect from a `fetch` only when it stays on the same host, on
/// https, and off the blocked paths. Otherwise the 3xx response itself is
/// returned to the server.
final class RedirectGuard: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                    newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(RedirectGuard.allows(from: task.originalRequest?.url, to: request.url) ? request : nil)
    }

    static func allows(from: URL?, to: URL?) -> Bool {
        guard let from = from, let to = to,
              to.scheme?.lowercased() == "https",
              let fromHost = from.host?.lowercased(),
              to.host?.lowercased() == fromHost else { return false }
        var pathAndQuery = to.path.isEmpty ? "/" : to.path
        if let q = to.query { pathAndQuery += "?" + q }
        return !Allowlist.isBlockedPath(pathAndQuery)
    }
}
#endif
