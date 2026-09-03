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
        var current = load()
        current.append(mutation)
        save(current)
    }

    func clear() {
        save([])
    }
}
