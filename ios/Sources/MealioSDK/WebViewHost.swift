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
// - show_login: while a MealioCartFlow sheet is open, the sign-in WebView is
//   published in `login` and the flow draws it inside its own sheet (one sheet
//   for the whole flow). With no flow open, the host presents its own sheet.
// - While Mealio drives a page, it carries a WKContentRuleList that blocks
//   every checkout path on the store's own hosts and store-owned sign-in
//   hosts (never a shared identity provider), for every request in every
//   frame (NetworkBlock.swift): added right before the first server script
//   for a document (the hidden page) or before each check script (sign-in),
//   dropped when the top frame's response for a new document arrives
//   (decidePolicyFor navigationResponse, before WebKit commits it). Other hosts are never
//   blocked by it, nor is a store page's boot before Mealio drives it. No
//   page loads or runs a script without its store's list compiled, and jobs
//   are refused if WebKit cannot compile the rules.

#if canImport(UIKit) && canImport(WebKit)
import Combine
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
public final class WebViewHost: NSObject, MealioHost, ObservableObject {
    public typealias Presenter = @MainActor () -> UIViewController?

    private let presenter: Presenter

    /// Main-frame navigations of the hidden WebView are checked with this.
    /// MealioCart sets it to the allowlist check `page_open` uses, widened to
    /// the store's sign-in hosts (a store sign-in can bounce the storefront
    /// through its identity host), so a redirect inside the hidden page cannot
    /// leave the store's own hosts or its sign-in hosts. Until then the bundled
    /// allowlist answers, so a navigation is never let through unchecked.
    var hiddenNavigationPolicy: (_ store: String, _ url: String) -> Bool = WebViewHost.bundledPolicy

    nonisolated static func bundledPolicy(_ store: String, _ url: String) -> Bool {
        let allowlist = Allowlist()
        return allowlist.check(store, url, .page).ok || allowlist.check(store, url, .login).ok
    }

    /// The hosts whose checkout paths the network block refuses for a store:
    /// its own hosts and its store-owned sign-in hosts, never a shared
    /// identity provider (SharedIdentity.nativeBlockHosts, round 7).
    /// MealioCart sets it to the client's allowlist, with any signed
    /// widening; until then the bundled allowlist answers.
    var storeHosts: (_ store: String) -> [String] = WebViewHost.bundledHosts

    nonisolated static func bundledHosts(_ store: String) -> [String] {
        Allowlist().hostsFor(store).map(SharedIdentity.nativeBlockHosts) ?? []
    }

    private(set) var hidden: WKWebView?
    /// The block list on the hidden page now (added when Mealio started
    /// driving this document), and the hosts it was made for.
    private var hiddenRules: WKContentRuleList?
    private var hiddenRulesKey = ""
    private var hiddenStore = ""
    /// The load one job is waiting for. Events and its timer settle it and no other.
    var pageWait: JobWaiter<PageOpenOutcome>?
    /// The script one job is waiting on, with what it has posted so far.
    var scriptWait: ScriptWait?
    private var cachedUserAgent: String?

    /// The sign-in in progress, while a cart flow sheet is hosting it.
    @Published var login: LoginSheet?
    /// Open cart flow sheets that will draw the sign-in themselves.
    private var flowHosts = 0

    /// A cart flow sheet opened (`true`) or closed (`false`). When the last
    /// one closes with a sign-in on screen (the sheet was hidden mid-add), the
    /// sign-in moves to a modal of its own instead of being cancelled.
    func hostLogin(_ on: Bool) {
        flowHosts = max(0, flowHosts + (on ? 1 : -1))
        if !on, flowHosts == 0, let shown = login {
            login = nil
            shown.moveToModal(presenter)
        }
    }

    private(set) var madeFetchSession: URLSession?

    /// Made on first use. URLSession keeps its delegate until it is
    /// invalidated, so `tearDown` invalidates it.
    var fetchSession: URLSession {
        if let s = madeFetchSession { return s }
        // The SDK's own cookie handling: nothing is stored by URLSession, the
        // Cookie header is built from the WebView's store for each request.
        let c = URLSessionConfiguration.ephemeral
        c.httpCookieStorage = nil
        c.httpShouldSetCookies = false
        c.httpCookieAcceptPolicy = .never
        c.urlCache = nil
        c.requestCachePolicy = .reloadIgnoringLocalCacheData
        let s = URLSession(configuration: c, delegate: RedirectGuard(), delegateQueue: nil)
        madeFetchSession = s
        return s
    }

    /// - Parameter presenter: Returns the view controller to present the login
    ///   sheet from. Defaults to the key window's top-most view controller.
    public init(presenter: Presenter? = nil) {
        self.presenter = presenter ?? { WebViewHost.topViewController() }
        super.init()
        // WebKit compiles the probe list now, off the jobs' path.
        BlockedPathRules.shared.prepare(hosts: NetworkBlock.probeHosts)
    }

    /// Jobs run only when WebKit compiles the network block. MealioHost.
    public func ready() async throws {
        try await BlockedPathRules.shared.ready()
    }

    /// The compiled list for a store's own hosts (nil: it has none).
    func blockList(for store: String, waitingAtMost ms: Int = NetworkBlock.waitMs) async throws -> WKContentRuleList? {
        try await BlockedPathRules.shared.list(hosts: storeHosts(store), waitingAtMost: ms)
    }

    // MARK: - Configuration shared by both WebViews

    /// Tests only: serves their pages from a local scheme handler, so no
    /// test WebView ever reaches a store.
    static var testConfiguration: ((WKWebViewConfiguration) -> Void)?

    /// No block list here: it is added only while Mealio drives the page
    /// (`armRules`, LoginSheet.inject). `rules` is for tests that want a page
    /// blocked from its first load.
    static func makeConfiguration(handler: WKScriptMessageHandler, rules: WKContentRuleList? = nil) -> WKWebViewConfiguration {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = WKWebsiteDataStore.default()
        let content = WKUserContentController()
        content.addUserScript(WKUserScript(source: Bridge.nativePostScript, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        content.addUserScript(WKUserScript(source: MealioScripts.bridgeShim, injectionTime: .atDocumentStart, forMainFrameOnly: true))
        // The guard in EVERY frame, before any of the frame's own scripts run,
        // UNARMED: its hooks pass everything through, so the store's own boot
        // code (workers, /payment config fetches) runs untouched, and in a
        // cross-origin frame (a captcha, an identity provider) it installs
        // nothing. Each server script is preceded by `guardArmScript`, which
        // arms it in the page and its same-origin frames until the page
        // navigates. The in-page hooks stay as a second layer (a frame a
        // script adds and uses in the same tick).
        content.addUserScript(WKUserScript(source: MealioScripts.guardScript, injectionTime: .atDocumentStart, forMainFrameOnly: false))
        content.add(handler, name: Bridge.messageHandlerName)
        if let rules = rules { content.add(rules) }
        config.userContentController = content
        testConfiguration?(config)
        return config
    }

    /// The hidden page, made on first use with no block list.
    func hiddenWebView() -> WKWebView {
        if let web = hidden { return web }
        let handler = ScriptHandler { [weak self] body in self?.hiddenMessage(body) }
        let web = WKWebView(frame: CGRect(x: 0, y: 0, width: 1, height: 1),
                            configuration: WebViewHost.makeConfiguration(handler: handler))
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

    /// Mealio starts driving the hidden page's document: its store's block
    /// list goes on (once per document and store; a list for other hosts
    /// comes off first).
    private func armRules(_ list: WKContentRuleList?, on web: WKWebView) {
        let key = list?.identifier ?? ""
        if hiddenRulesKey == key, hiddenRules != nil || list == nil { return }
        disarmRules(on: web)
        if let list = list {
            web.configuration.userContentController.add(list)
            hiddenRules = list
            hiddenRulesKey = key
        }
    }

    /// The page left the document Mealio drove: its block list comes off.
    private func disarmRules(on web: WKWebView?) {
        if hiddenRules != nil {
            web?.configuration.userContentController.removeAllContentRuleLists()
        }
        hiddenRules = nil
        hiddenRulesKey = ""
    }

    private func hiddenMessage(_ body: Any) {
        guard let msg = parseMessage(body), let wait = scriptWait else { return }
        wait.messages.append(msg)
        if matchesAny(msg, wait.until) {
            wait.waiter.settle(ScriptOutcome(messages: wait.messages, timedOut: false))
        }
    }

    /// Drop the hidden page (after a sign-out, so nothing of the old session
    /// stays in memory). The next page_open makes a fresh one. A job waiting
    /// on the page is answered now instead of waiting out its timer.
    /// MealioHost: before a job, after exclusive work outlived its cap.
    public func resetPage() {
        resetHiddenPage()
    }

    public func resetHiddenPage() {
        pageWait?.settle(PageOpenOutcome(ok: false, error: "load_failed"))
        pageWait = nil
        if let wait = scriptWait {
            wait.waiter.settle(ScriptOutcome(messages: wait.messages, timedOut: false, error: "page_reset"))
        }
        scriptWait = nil
        if let web = hidden {
            web.stopLoading()
            web.navigationDelegate = nil
            web.configuration.userContentController.removeScriptMessageHandler(forName: Bridge.messageHandlerName)
            web.removeFromSuperview()
        }
        disarmRules(on: hidden)
        hidden = nil
    }

    /// This host is being replaced (MealioCart.configure ran again). Drops the
    /// hidden page, closes any sign-in, and lets go of the fetch session.
    func tearDown() {
        resetHiddenPage()
        login?.cancel()
        login = nil
        madeFetchSession?.invalidateAndCancel()
        madeFetchSession = nil
    }

    // MARK: - page_open

    public func openPage(store: String, url: String, timeoutMs: Int) async throws -> PageOpenOutcome {
        guard let target = URL(string: url) else { return PageOpenOutcome(ok: false, error: "load_failed") }
        // Never a load whose store's block list is not compiled, ready for
        // the first script. It is not on the page yet: the store's own boot
        // requests run untouched until Mealio drives the page.
        do {
            _ = try await blockList(for: store, waitingAtMost: min(max(timeoutMs, 0), NetworkBlock.waitMs))
        } catch {
            return PageOpenOutcome(ok: false, error: "no_network_block")
        }
        let web = hiddenWebView()
        // Another store: Mealio no longer drives the old one's page.
        if store != hiddenStore { disarmRules(on: web) }
        hiddenStore = store
        // A load still waiting from before is superseded. Its timer is its own.
        pageWait?.settle(PageOpenOutcome(ok: false, error: "superseded"))
        let waiter = JobWaiter<PageOpenOutcome>()
        pageWait = waiter
        let outcome = await waiter.wait {
            web.load(URLRequest(url: target))
            waiter.timer = after(timeoutMs) { [weak web, weak waiter] in
                if waiter?.settle(PageOpenOutcome(ok: false, finalUrl: web?.url?.absoluteString, error: "timeout")) == true {
                    web?.stopLoading()
                }
            }
        }
        if pageWait === waiter { pageWait = nil }
        return outcome
    }

    // MARK: - page_script

    public func runScript(store: String, guardScript: String, script: String, until: [Matcher], timeoutMs: Int) async throws -> ScriptOutcome {
        guard hidden?.url != nil else {
            return ScriptOutcome(messages: [], timedOut: false, error: "no_page")
        }
        // Mealio drives the page from here: the store's block list goes on
        // first, with the guard's arming. No list, no script.
        let list: WKContentRuleList?
        do {
            list = try await blockList(for: store, waitingAtMost: min(max(timeoutMs, 0), NetworkBlock.waitMs))
        } catch {
            return ScriptOutcome(messages: [], timedOut: false, error: "no_network_block")
        }
        guard let web = hidden, web.url != nil else {
            return ScriptOutcome(messages: [], timedOut: false, error: "no_page")
        }
        armRules(list, on: web)
        // One script at a time; one still waiting from before is superseded.
        if let old = scriptWait {
            old.waiter.settle(ScriptOutcome(messages: old.messages, timedOut: false, error: "superseded"))
        }
        let wait = ScriptWait(until: until)
        scriptWait = wait
        let outcome = await wait.waiter.wait {
            // Listening starts here, before injecting, so a message the guard
            // or the script posts straight away is not missed.
            wait.waiter.timer = after(timeoutMs) { [weak wait] in
                guard let wait = wait else { return }
                wait.waiter.settle(ScriptOutcome(messages: wait.messages, timedOut: true))
            }
            // Results and JS exceptions are ignored, as React Native's
            // injectJavaScript ignores them. Scripts report through messages.
            web.evaluateJavaScript(guardScript, completionHandler: nil)
            web.evaluateJavaScript(script, completionHandler: nil)
        }
        if scriptWait === wait { scriptWait = nil }
        return outcome
    }

    // MARK: - show_login

    public func showLogin(_ request: LoginRequest) async throws -> LoginOutcome {
        guard let url = URL(string: request.url) else {
            throw MealioError(code: MealioError.Code.blocked, message: "The login URL is not valid")
        }
        // Cancelled while it was queued behind the runner's check: never show it.
        if request.cancel?.cancelled == true {
            return LoginOutcome(outcome: .cancelled, messages: [])
        }
        // Never a sign-in page whose store's block list is not compiled. It
        // goes on before each check script, not before the page's own boot.
        let rules = try await blockList(for: request.store)
        if request.cancel?.cancelled == true {
            return LoginOutcome(outcome: .cancelled, messages: [])
        }
        let sheet = LoginSheet(request: request, rules: rules)
        if flowHosts > 0 {
            // Inside the open flow sheet: publish it, the flow draws it.
            let publish: @MainActor (LoginSheet?) -> Void = { [weak self, weak sheet] shown in
                guard let self = self else { return }
                if let shown = shown {
                    self.login = shown
                } else if self.login == nil || self.login === sheet {
                    self.login = nil
                }
            }
            return await sheet.run(url: url, mode: .inline(publish))
        }
        guard let from = presenter() else {
            throw MealioError(code: MealioError.Code.unsupported, message: "No view controller to present the store login from")
        }
        let outcome = await sheet.run(url: url, mode: .modal(from))
        if let failure = sheet.failure { throw failure }
        return outcome
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
        // RedirectGuard stopped a redirect: its 3xx is not handed back, as on React Native.
        if RedirectGuard.stopped(status: http.statusCode, location: http.value(forHTTPHeaderField: "Location"), from: url) {
            return FetchOutcome(ok: false, error: "redirect_blocked")
        }

        var headers: [String: String] = [:]
        var rawFields: [String: String] = [:]
        for (k, v) in http.allHeaderFields {
            guard let name = k as? String else { continue }
            let value = "\(v)"
            rawFields[name] = value
            // Like a browser fetch, cookies the store sets are not handed back
            // to the server. They go into the WebView's cookie store instead.
            if WebViewHost.privateHeaders.contains(name.lowercased()) { continue }
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

    /// Response headers never handed back to the server.
    static let privateHeaders: Set<String> = ["set-cookie", "set-cookie2"]

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
        if s == "about:blank" || hiddenNavigationPolicy(hiddenStore, s) {
            decisionHandler(.allow)
        } else {
            decisionHandler(.cancel)
            pageWait?.settle(PageOpenOutcome(ok: false, finalUrl: s, error: "blocked"))
        }
    }

    /// The top frame's response for a new document is in: Mealio is not
    /// driving that document (yet), so the block list comes off HERE, before
    /// WebKit is told to go on, so before the new document's first byte and
    /// first subresource (round 7). Not at didCommit: that callback reaches
    /// the app after the web process has committed, so the new page's first
    /// subresources could still meet the old list, and a script that armed
    /// the new page in between would lose its list. Re-armed only by
    /// runScript. Same-document navigations have no response and keep it.
    public func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                        decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if webView === hidden, WebViewHost.startsNewDocument(navigationResponse) {
            disarmRules(on: webView)
        }
        // WebKit's own default when no delegate answers.
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
    }

    /// A top-frame response that becomes a new document: one WebKit can show,
    /// and not a 204 or 205 (which leave the current document in place).
    static func startsNewDocument(_ r: WKNavigationResponse) -> Bool {
        guard r.isForMainFrame, r.canShowMIMEType else { return false }
        if let http = r.response as? HTTPURLResponse, http.statusCode == 204 || http.statusCode == 205 { return false }
        return true
    }

    public func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        pageWait?.settle(PageOpenOutcome(ok: true, finalUrl: webView.url?.absoluteString))
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
        pageWait?.settle(PageOpenOutcome(ok: false, finalUrl: hidden?.url?.absoluteString, error: "load_failed"))
    }
}

// MARK: - Login sheet

/// One show_login: a visible WKWebView on the same data store as the hidden
/// WebView, either drawn inside the cart flow sheet (`.inline`) or in a modal
/// sheet of its own (`.modal`). The navigation checks are the same either way.
@MainActor
final class LoginSheet: NSObject, WKNavigationDelegate, WKUIDelegate, UIAdaptivePresentationControllerDelegate {
    enum Mode {
        /// Present a sheet from this view controller.
        case modal(UIViewController)
        /// Hand the sheet to the flow (`self` to show, nil to take it down).
        case inline(@MainActor (LoginSheet?) -> Void)
    }

    private let request: LoginRequest
    private let doneUrlRegex: NSRegularExpression?
    /// The visible sign-in WebView.
    let webView: WKWebView
    private var nav: UINavigationController?
    private var unpublish: (@MainActor () -> Void)?
    private var once: ResumeOnce<LoginOutcome>?
    private var messages: [JSONMessage] = []
    private var timers: [Task<Void, Never>] = []
    private var finished = false
    /// A navigation matching doneWhenUrl is loading; finish when it lands.
    private var doneUrlLoading = false
    /// Stops listening to the job's cancel token.
    private var stopListening: (() -> Void)?
    /// Why the sheet could not be shown, when it could not. The run then
    /// fails with this instead of waiting out its timeout.
    private(set) var failure: MealioError?
    /// The store's block list, added before each check script.
    private let rules: WKContentRuleList?
    /// It is on the sheet's page now (until a new document's response arrives).
    private var rulesOn = false

    /// How long a modal presentation may take to start before it counts as refused.
    static let presentCheckMs = 1000

    /// `rules`: the store's checkout-path block list. WebViewHost always
    /// passes it when the store has hosts of its own.
    init(request: LoginRequest, rules: WKContentRuleList? = nil) {
        self.request = request
        self.rules = rules
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

    /// The store's own title for the sign-in ("Sign in to H-E-B").
    var title: String { request.title }
    var url: String { request.url }

    /// The user closed the sign-in.
    func cancel() {
        finish(.cancelled)
    }

    func run(url: URL, mode: Mode) async -> LoginOutcome {
        await withCheckedContinuation { cont in
            once = ResumeOnce(cont)
            switch mode {
            case .modal(let presenter):
                // UIKit refuses to present from a controller that is off screen
                // or already presenting, and only logs it. Fail now instead.
                guard presenter.viewIfLoaded?.window != nil, presenter.presentedViewController == nil else {
                    failure = LoginSheet.notShown
                    finish(.cancelled)
                    return
                }
                let screen = LoginViewController(title: request.title, webView: webView) { [weak self] in
                    self?.finish(.cancelled)
                }
                let nav = UINavigationController(rootViewController: screen)
                nav.presentationController?.delegate = self
                self.nav = nav
                presenter.present(nav, animated: true)
                timers.append(after(LoginSheet.presentCheckMs) { [weak self, weak nav] in
                    guard let self = self, !self.finished else { return }
                    if nav?.presentingViewController == nil {
                        self.failure = LoginSheet.notShown
                        self.finish(.cancelled)
                    }
                })
            case .inline(let publish):
                unpublish = { publish(nil) }
                publish(self)
            }
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
            // The job was cancelled (the sheet closed, the user changed): close.
            if let token = request.cancel {
                stopListening = token.onCancel { [weak self] in self?.finish(.cancelled) }
            }
        }
    }

    /// The flow sheet that drew this sign-in went away (hidden mid-add): show
    /// it in a modal sheet instead, once the flow sheet has finished leaving.
    /// It is retried for a short while, since UIKit refuses to present from a
    /// controller that is still dismissing; if it never can, the sign-in ends
    /// as cancelled, as a closed one would.
    func moveToModal(_ presenter: @escaping @MainActor () -> UIViewController?, tries: Int = 12) {
        guard !finished, nav == nil else { return }
        // Off the flow: it no longer draws or takes down this sign-in.
        unpublish = nil
        if let from = presenter(), from.viewIfLoaded?.window != nil, from.presentedViewController == nil,
           !from.isBeingDismissed, !from.isBeingPresented {
            let screen = LoginViewController(title: request.title, webView: webView) { [weak self] in
                self?.finish(.cancelled)
            }
            let nav = UINavigationController(rootViewController: screen)
            nav.presentationController?.delegate = self
            self.nav = nav
            from.present(nav, animated: true)
            return
        }
        guard tries > 0 else {
            failure = LoginSheet.notShown
            finish(.cancelled)
            return
        }
        timers.append(after(250) { [weak self] in self?.moveToModal(presenter, tries: tries - 1) })
    }

    static let notShown = MealioError(code: MealioError.Code.unsupported,
                                      message: "Could not show the store sign-in: the presenting view controller is not on screen or is already presenting")

    /// The store's block list (if not on already), GUARD_ARM_SCRIPT, then the
    /// check script, each its own evaluation in the top frame. (GUARD_SCRIPT
    /// is already in every frame at document start.)
    private func inject() {
        if let rules = rules, !rulesOn {
            webView.configuration.userContentController.add(rules)
            rulesOn = true
        }
        webView.evaluateJavaScript(request.armGuardScript, completionHandler: nil)
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
        stopListening?()
        stopListening = nil
        timers.forEach { $0.cancel() }
        timers.removeAll()
        webView.stopLoading()
        webView.configuration.userContentController.removeScriptMessageHandler(forName: Bridge.messageHandlerName)
        let outcome = LoginOutcome(outcome: kind, messages: messages)
        let once = self.once
        if let unpublish = unpublish {
            self.unpublish = nil
            unpublish()
            once?.resume(outcome)
            return
        }
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

    /// A new document's response: Mealio is not driving it until the next
    /// check, so the block list comes off before WebKit goes on (not at
    /// didCommit, which can come after the new page's first subresources and
    /// after a check already armed it; see WebViewHost).
    func webView(_ webView: WKWebView, decidePolicyFor navigationResponse: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        if rulesOn, WebViewHost.startsNewDocument(navigationResponse) {
            webView.configuration.userContentController.removeAllContentRuleLists()
            rulesOn = false
        }
        decisionHandler(navigationResponse.canShowMIMEType ? .allow : .cancel)
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
        attach()
    }

    /// A sign-in moved here from the flow sheet may have been taken off this
    /// view by SwiftUI tearing the old sheet down: put it back.
    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        if webView.superview !== view { attach() }
    }

    private func attach() {
        webView.removeFromSuperview()
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
        // The handler is reachable from every frame, but only the top page
        // speaks for the store: an ad or tracker iframe must not be able to
        // post a message a `until` or `doneWhen` matcher would accept.
        guard message.frameInfo.isMainFrame else { return }
        onMessage?(message.body)
    }
}

/// One job's wait: a page load or a script. Only its own timer and the
/// events meant for it settle it, once.
@MainActor
final class JobWaiter<T> {
    private var once: ResumeOnce<T>?
    /// This wait's own timer, cancelled when it settles.
    var timer: Task<Void, Never>?

    init() {}

    /// Wait until settled. `start` runs once the wait can be settled.
    func wait(_ start: () -> Void) async -> T {
        await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
            once = ResumeOnce(cont)
            start()
        }
    }

    /// Returns true if this call settled it.
    @discardableResult
    func settle(_ value: T) -> Bool {
        guard let once = once, once.resume(value) else { return false }
        timer?.cancel()
        timer = nil
        return true
    }
}

/// The script one runScript is waiting on, and the messages it has posted.
@MainActor
final class ScriptWait {
    let until: [Matcher]
    var messages: [JSONMessage] = []
    let waiter: JobWaiter<ScriptOutcome>

    init(until: [Matcher]) {
        self.until = until
        self.waiter = JobWaiter<ScriptOutcome>()
    }
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

    /// A 3xx this guard refused to follow: the response is the redirect itself.
    static func stopped(status: Int, location: String?, from: URL) -> Bool {
        guard (300..<400).contains(status), let location = location, !location.isEmpty,
              let to = URL(string: location, relativeTo: from)?.absoluteURL else { return false }
        return !allows(from: from, to: to)
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
