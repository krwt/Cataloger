import Foundation

/// A queued mutation waiting to be flushed to CloudKit once connectivity returns.
/// Persisted to disk so the offline ledger survives app relaunch.
struct PendingMutation: Codable, Identifiable {
    enum Kind: String, Codable {
        case upsert
        case delete
    }
    var id: String = UUID().uuidString
    var kind: Kind
    var assetID: String
    /// Full asset payload for `.upsert` mutations. Without this, a mutation
    /// queued while offline has no data to replay once the app relaunches —
    /// the in-memory `assets` array from the failed session is gone, so the
    /// ledger itself must carry the payload, not just a pointer to it.
    var assetPayload: Asset?
    var timestamp: Date = Date()
    }

/// Simple disk-backed queue implementing the "offline transaction ledger"
/// described in the architecture blueprint.
final class OfflineLedger {
    private let fileURL: URL

    init(directory: URL) {
        self.fileURL = directory.appendingPathComponent("offline_ledger.json")
    }

    func load() -> [PendingMutation] {
        guard let data = try? Data(contentsOf: fileURL) else { return [] }
        return (try? JSONDecoder().decode([PendingMutation].self, from: data)) ?? []
    }

    func save(_ mutations: [PendingMutation]) {
        guard let data = try? JSONEncoder().encode(mutations) else { return }
        try? data.write(to: fileURL, options: .atomic)
    }

    func append(_ mutation: PendingMutation) {
        append(contentsOf: [mutation])
    }

    /// Queues many mutations in a single load-modify-save.
    ///
    /// Calling `append` in a loop costs a full decode + encode + disk write
    /// *per mutation*, which is unusably slow for a bulk import that
    /// write-ahead-logs several thousand payloads before starting.
    func append(contentsOf mutations: [PendingMutation]) {
        guard !mutations.isEmpty else { return }
        var current = load()
        current.append(contentsOf: mutations)
        save(current)
    }

    /// Removes queued mutations by mutation ID — used to retire write-ahead
    /// entries as their batch confirms, so a kill mid-operation leaves only
    /// the genuinely unfinished work queued.
    func remove(ids: Set<String>) {
        guard !ids.isEmpty else { return }
        let remaining = load().filter { !ids.contains($0.id) }
        save(remaining)
    }

    /// Removes queued mutations targeting the given assets, regardless of
    /// which mutation entry they came from. Used when a batch succeeds and
    /// we know the asset IDs rather than the mutation IDs.
    func removeMutations(forAssetIDs assetIDs: Set<String>) {
        guard !assetIDs.isEmpty else { return }
        let remaining = load().filter { !assetIDs.contains($0.assetID) }
        save(remaining)
    }

    func clear() {
        save([])
    }
}
