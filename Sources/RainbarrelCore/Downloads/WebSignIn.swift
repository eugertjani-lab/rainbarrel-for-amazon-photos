import Foundation

/// Helpers for the menu-bar app's sign-in window, which collects the cookies of a browser sign-in.
/// They hold no cookie values in any text they produce.
public enum WebSignIn {
    /// The cookies of a sign-in browser that belong to the registrable domain of `host`
    /// (`www.amazon.co.uk` gives `amazon.co.uk`), without expired or unusable ones. Cookies of other
    /// sites are dropped here, so they never reach the stored session.
    public static func sessionCookies(from cookies: [SessionCookie], host: String, now: Date = Date()) -> [SessionCookie] {
        let own = AmazonEndpoints.registrableDomain(of: host)
        guard !own.isEmpty else { return [] }
        return cookies.filter { cookie in
            var domain = cookie.domain.lowercased()
            if domain.hasPrefix(".") { domain.removeFirst() }
            guard domain == own || domain.hasSuffix("." + own) else { return false }
            return !cookie.isExpired(at: now) && cookie.isHeaderSafe
        }
    }

    /// True when the cookies hold the `session-id` cookie and one that only a signed-in browser has.
    /// Amazon also sets `session-id` for visitors who are not signed in, so it is not enough alone.
    /// This only decides when it is worth asking Amazon; the answer to that call is what counts.
    public static func looksSignedIn(_ cookies: [SessionCookie], now: Date = Date()) -> Bool {
        let live = cookies.filter { !$0.value.isEmpty && !$0.isExpired(at: now) }
        guard live.contains(where: { $0.name == "session-id" }) else { return false }
        return live.contains { isAuthCookieName($0.name) }
    }

    /// Amazon's sign-in cookies: `at-main`, `sess-at-main`, `x-main` and the regional forms such as
    /// `at-acbuk` or `x-acbde`.
    static func isAuthCookieName(_ name: String) -> Bool {
        let lower = name.lowercased()
        return lower == "x-main" || lower.hasPrefix("at-") || lower.hasPrefix("sess-at-") || lower.hasPrefix("x-acb")
    }
}
