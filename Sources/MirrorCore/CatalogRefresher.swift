import Foundation

/// Copies a cloud catalog into the state store.
public struct CatalogRefresher {
    public let store: StateStore

    public init(store: StateStore) {
        self.store = store
    }

    /// Replace `cloud_items` with the current catalog of `source`, in one transaction.
    @discardableResult
    public func refresh(from source: CloudCatalogSource, now: Date = Date()) throws -> CatalogReadResult {
        try store.replaceCloudItems(seenAt: now) { sink in
            try source.readCatalog(sink)
        }
    }

    /// True when the catalog was never refreshed or the last refresh is older than `maxAge` seconds.
    public func isStale(maxAge: TimeInterval = 600, now: Date = Date()) throws -> Bool {
        guard let last = try store.getMetaDate(MetaKey.catalogRefreshedAt) else { return true }
        return now.timeIntervalSince(last) > maxAge
    }
}
