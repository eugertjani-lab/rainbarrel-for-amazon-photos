import AppKit
import RainbarrelCore
import WebKit

/// Amazon's own sign-in page in a window. The web view has its own, non-persistent website data
/// store, so nothing of this sign-in is kept by the system once the window is gone. The person types
/// their credentials into Amazon's page; the app never sees or stores the password.
///
/// After each page load the window reads the cookies of the web view's store, keeps those of the
/// configured Amazon host's domain, and (once they look like a signed-in browser) asks Amazon with
/// one cheap call whether they work. Cookie values are never logged, printed or shown.
@MainActor
final class SignInWindowController: NSObject, NSWindowDelegate, WKNavigationDelegate, WKUIDelegate {
    /// Checks and stores a session; throws `DownloadError.sessionExpired` when Amazon does not accept it yet.
    typealias Verifier = @MainActor (StoredSession) async throws -> Void

    private static let invitation = "Sign in with your own Amazon account. Rainbarrel never sees your password."

    private let host: String
    private let verify: Verifier
    private let onClose: @MainActor () -> Void
    private let window: NSWindow
    private let webView: SignInWebView
    private let statusLabel = NSTextField(labelWithString: SignInWindowController.invitation)
    private var isChecking = false
    private var finished = false
    /// A number made from the cookies that were last sent to Amazon, to ask again only when they change.
    private var lastFingerprint: Int?

    init(host: String, verify: @escaping Verifier, onClose: @escaping @MainActor () -> Void) {
        self.host = host
        self.verify = verify
        self.onClose = onClose

        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = WKWebsiteDataStore.nonPersistent()
        webView = SignInWebView(frame: .zero, configuration: configuration)
        webView.translatesAutoresizingMaskIntoConstraints = false

        statusLabel.font = .systemFont(ofSize: 12)
        statusLabel.textColor = .secondaryLabelColor
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.maximumNumberOfLines = 2
        statusLabel.translatesAutoresizingMaskIntoConstraints = false

        let content = NSView(frame: NSRect(x: 0, y: 0, width: 520, height: 720))
        let separator = NSBox()
        separator.boxType = .separator
        separator.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(webView)
        content.addSubview(separator)
        content.addSubview(statusLabel)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: content.topAnchor),
            webView.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            separator.topAnchor.constraint(equalTo: webView.bottomAnchor),
            separator.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            separator.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            statusLabel.topAnchor.constraint(equalTo: separator.bottomAnchor, constant: 8),
            statusLabel.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 14),
            statusLabel.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -14),
            statusLabel.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -8),
        ])

        window = NSWindow(
            contentRect: content.frame, styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered, defer: false)
        window.title = "Sign in to Amazon"
        window.contentView = content
        window.contentMinSize = NSSize(width: 420, height: 520)
        window.isReleasedWhenClosed = false
        window.center()

        super.init()
        window.delegate = self
        webView.navigationDelegate = self
        webView.uiDelegate = self
        if let url = URL(string: "https://\(host)/photos") {
            webView.load(URLRequest(url: url))
        } else {
            show(status: "The Amazon host in the settings is not valid.")
        }
    }

    /// Bring the window to the front.
    func show() {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    private func show(status: String) {
        statusLabel.stringValue = status
    }

    // MARK: Cookies

    private func checkCookies() async {
        guard !isChecking, !finished else { return }
        let httpCookies = await webView.configuration.websiteDataStore.httpCookieStore.allCookies()
        let all = httpCookies.map {
            SessionCookie(
                name: $0.name, value: $0.value, domain: $0.domain, path: $0.path.isEmpty ? "/" : $0.path,
                expiresAt: $0.expiresDate, secure: $0.isSecure)
        }
        let cookies = WebSignIn.sessionCookies(from: all, host: host)
        guard WebSignIn.looksSignedIn(cookies) else { return }
        let fingerprint = Self.fingerprint(of: cookies)
        guard fingerprint != lastFingerprint else { return }
        lastFingerprint = fingerprint

        isChecking = true
        defer { isChecking = false }
        show(status: "Checking your sign-in…")
        let session = StoredSession(host: host, cookies: cookies, savedAt: Date())
        do {
            try await verify(session)
            finished = true
            show(status: "Signed in")
            await clearWebData()
            try? await Task.sleep(for: .milliseconds(900))
            window.close()
        } catch DownloadError.sessionExpired {
            // Amazon does not accept the cookies yet (a second step may still be open). Wait for the next page.
            show(status: Self.invitation)
        } catch {
            // Error texts of the download layer never contain cookie values.
            show(status: "Could not check the sign-in: \(error)")
            lastFingerprint = nil
        }
    }

    /// Equal for equal cookies; the values go into the hash and nowhere else.
    private static func fingerprint(of cookies: [SessionCookie]) -> Int {
        var hasher = Hasher()
        for cookie in cookies.sorted(by: { ($0.domain, $0.name, $0.path) < ($1.domain, $1.name, $1.path) }) {
            hasher.combine(cookie.domain)
            hasher.combine(cookie.name)
            hasher.combine(cookie.value)
        }
        return hasher.finalize()
    }

    private func clearWebData() async {
        let store = webView.configuration.websiteDataStore
        await store.removeData(ofTypes: WKWebsiteDataStore.allWebsiteDataTypes(), modifiedSince: .distantPast)
    }

    // MARK: WKNavigationDelegate

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        Task { await checkCookies() }
    }

    func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: any Error) {
        reportLoadFailure(error)
    }

    func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: any Error) {
        reportLoadFailure(error)
    }

    private func reportLoadFailure(_ error: any Error) {
        let code = (error as NSError).code
        guard code != NSURLErrorCancelled, !finished else { return }
        show(status: "The page did not load: \(error.localizedDescription)")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction) async -> WKNavigationActionPolicy {
        guard let scheme = navigationAction.request.url?.scheme?.lowercased() else { return .cancel }
        return scheme == "https" || scheme == "about" ? .allow : .cancel
    }

    // MARK: WKUIDelegate

    /// Links that ask for a new window open in the same one.
    func webView(
        _ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
        for navigationAction: WKNavigationAction, windowFeatures: WKWindowFeatures
    ) -> WKWebView? {
        if navigationAction.request.url?.scheme?.lowercased() == "https" {
            webView.load(navigationAction.request)
        }
        return nil
    }

    // MARK: NSWindowDelegate

    func windowWillClose(_ notification: Notification) {
        webView.stopLoading()
        webView.navigationDelegate = nil
        webView.uiDelegate = nil
        onClose()
    }
}

/// A web view that also handles the editing shortcuts, because the app has no Edit menu of its own
/// while it runs without a Dock icon. Pasting a password from a password manager needs Cmd+V.
private final class SignInWebView: WKWebView {
    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard event.type == .keyDown,
            event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
            let key = event.charactersIgnoringModifiers?.lowercased()
        else { return super.performKeyEquivalent(with: event) }
        let action: Selector?
        switch key {
        case "v": action = #selector(NSText.paste(_:))
        case "c": action = #selector(NSText.copy(_:))
        case "x": action = #selector(NSText.cut(_:))
        case "a": action = #selector(NSResponder.selectAll(_:))
        default: action = nil
        }
        if let action, NSApp.sendAction(action, to: nil, from: self) { return true }
        return super.performKeyEquivalent(with: event)
    }
}
