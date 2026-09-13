import Foundation

/// Local disk snapshot of the asset list, so a cold launch can populate rows
/// immediately instead of waiting on a CloudKit round-trip.
///
/// This is a *cache of CloudKit*, never a second source of truth: CloudKit
/// stays authoritative and a successful fetch replaces this wholesale. The
/// offline transaction ledger (`OfflineLedger`) remains the durable record of
/// unsynced local work — that's a different job, and the two are layered at
/// launch (cache first, then queued mutations merged on top).
///
/// Deliberately stored in the app sandbox's Documents directory rather than
/// the iCloud ubiquity container: reaching the latter means
/// `url(forUbiquityContainerIdentifier:)`, a blocking call that was the cause
/// of the launch/typing stalls this cache exists to avoid. Nothing here needs
/// to sync — CloudKit already does that.
enum AssetCache {

    /// Wrapper so the on-disk format can evolve. If `Asset` gains a field and
    /// an older payload no longer decodes, the read fails softly and the app
    /// falls back to a network load rather than crashing or showing nothing.
    private struct Payload: Codable {
        var schemaVersion: Int
        var assets: [Asset]
        var savedAt: Date
    }

    private static let currentSchemaVersion = 1

    private static var fileURL: URL {
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        return docs.appendingPathComponent("asset_cache.json")
    }

    /// Reads the cached assets. Returns an empty array for any failure —
    /// missing file, truncated write, schema change. A bad cache must always
    /// degrade to "load from network", never to a crash.
    static func load() -> [Asset] {
        guard let data = try? Data(contentsOf: fileURL),
              let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.schemaVersion == currentSchemaVersion else {
            return []
        }
        return payload.assets
    }

    /// Encodes and writes off the main thread, atomically. Failures are
    /// swallowed on purpose: an unwritable cache should quietly degrade to
    /// network-only launches, not surface an error the user can't act on.
    static func save(_ assets: [Asset]) async {
        let payload = Payload(
            schemaVersion: currentSchemaVersion,
            assets: assets,
            savedAt: Date()
        )
        await Task.detached(priority: .utility) {
            guard let data = try? JSONEncoder().encode(payload) else { return }
            try? data.write(to: fileURL, options: .atomic)
        }.value
    }

    static func clear() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}
