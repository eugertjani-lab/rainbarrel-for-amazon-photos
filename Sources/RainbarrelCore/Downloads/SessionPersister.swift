import Foundation

/// Keeps the session store in step with a running client.
///
/// Amazon refreshes cookies while a run goes on, and the client takes them over. This writes the
/// refreshed cookies back so that the next run starts with them, at most once per `interval` and once
/// at the end of the run. A write never replaces a sign-in the person made in the meantime: the
/// stored session is read first, and only a session with the `savedAt` and host this run started
/// with is overwritten.
///
/// When the sign-in is refused, a newer one in the store can take its place for the rest of the run.
///
/// Everything here is best effort: a store that cannot be read or written never stops a run.
final class SessionPersister: @unchecked Sendable {
    /// The least time between two writes of a run.
    static let saveInterval: TimeInterval = 60

    enum SaveOutcome: Sendable, Equatable {
        /// The cookies are the ones that were last written.
        case unchanged
        /// Changed, but the last write was less than `interval` ago.
        case waiting
        case saved
        /// The store holds another sign-in (or none): it was left alone.
        case storeHoldsAnotherSession
        case failed
    }

    private let client: AmazonClient
    private let store: any SessionStore
    private let now: @Sendable () -> Date
    private let interval: TimeInterval
    private let lock = NSLock()
    /// The sign-in this run works with: what the store must still hold for a write to go through.
    private var baseline: StoredSession
    private var savedGeneration: Int
    private var lastWrite: Date?
    private var adopted: Set<Date>

    init(
        client: AmazonClient, store: any SessionStore, baseline: StoredSession,
        interval: TimeInterval = SessionPersister.saveInterval, now: @escaping @Sendable () -> Date = { Date() }
    ) {
        self.client = client
        self.store = store
        self.baseline = baseline
        self.interval = interval
        self.now = now
        savedGeneration = client.cookieGeneration
        adopted = [baseline.savedAt]
    }

    /// Write the cookies when they changed and the last write is old enough.
    @discardableResult
    func saveIfDue() -> SaveOutcome { save(force: false) }

    /// Write the cookies when they changed, whatever the time since the last write. The end of a run.
    @discardableResult
    func flush() -> SaveOutcome { save(force: true) }

    private func save(force: Bool) -> SaveOutcome {
        lock.withLock {
            let generation = client.cookieGeneration
            guard generation != savedGeneration else { return .unchanged }
            let moment = now()
            if !force, let lastWrite, moment.timeIntervalSince(lastWrite) < interval { return .waiting }
            do {
                guard let stored = try store.load(), stored.savedAt == baseline.savedAt, stored.host == baseline.host
                else { return .storeHoldsAnotherSession }
                try store.save(client.currentSession)
                savedGeneration = generation
                lastWrite = moment
                return .saved
            } catch {
                return .failed
            }
        }
    }

    /// The client was told that the session is refused. Returns true when the request should be tried
    /// again: either the store holds a usable sign-in that this run has not used yet, which the client
    /// now switches to, or another request already switched since `attemptEpoch` (the client's
    /// `sessionEpoch` when the failed request began). Each sign-in is taken over once, so a refused
    /// replacement ends the run instead of repeating.
    func recoverFromRefusal(attemptEpoch: Int) -> Bool {
        lock.withLock {
            if client.sessionEpoch != attemptEpoch { return true }
            guard let stored = try? store.load(), stored.isUsable(), stored.host == baseline.host,
                !adopted.contains(stored.savedAt)
            else { return false }
            adopted.insert(stored.savedAt)
            client.replaceSession(stored)
            baseline = stored
            savedGeneration = client.cookieGeneration
            lastWrite = nil
            return true
        }
    }
}
