import Foundation
import CloudKit

/// Handles all CloudKit I/O on a dedicated background actor.
/// - Custom CKRecordZone with a subscription for differential (push-driven) sync.
/// - Offline mutations are queued to `OfflineLedger` and flushed on reconnect.
/// - Conflicts are resolved last-write-wins by `Asset.modifiedAt` timestamp.
actor CloudKitManager {

    static let zoneName = "AssetZone"
    static let subscriptionID = "AssetZoneSubscription"

    private let container: CKContainer
    private let database: CKDatabase
    private let zoneID: CKRecordZone.ID
    private let ledger: OfflineLedger
    private var isReachable = true

    init(containerIdentifier: String? = nil) {
        self.container = containerIdentifier.map(CKContainer.init(identifier:)) ?? CKContainer.default()
        self.database = container.privateCloudDatabase
        self.zoneID = CKRecordZone.ID(zoneName: Self.zoneName, ownerName: CKCurrentUserDefaultName)
        let docs = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        self.ledger = OfflineLedger(directory: docs)
    }

    // MARK: - Setup

    /// Creates the custom zone + push subscription. Call once at app launch.
    func bootstrap() async throws {
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await database.save(zone)

        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: Self.subscriptionID)
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        _ = try? await database.save(subscription)

        await flushOfflineLedger()
    }

    // MARK: - Fetch

    /// Pulls the full asset set for initial load / manual refresh.
    ///
    /// On a brand-new CloudKit container, the "Asset" record type schema
    /// doesn't exist until the very first record is *saved* — querying it
    /// before that point throws rather than returning an empty result.
    /// That's expected on first launch, so it's treated as "no assets yet"
    /// rather than a real connectivity failure.
    func fetchAllAssets() async throws -> [Asset] {
        let epoch = Date(timeIntervalSince1970: 0) as NSDate
        let query = CKQuery(recordType: Asset.recordType, predicate: NSPredicate(format: "modifiedAt > %@", epoch))
        var results: [Asset] = []
        var cursor: CKQueryOperation.Cursor?

        do {
            repeat {
                let response: (matchResults: [(CKRecord.ID, Result<CKRecord, Error>)], queryCursor: CKQueryOperation.Cursor?)
                if let cursor {
                    response = try await database.records(continuingMatchFrom: cursor)
                } else {
                    response = try await database.records(matching: query, inZoneWith: zoneID)
                }
                for (_, result) in response.matchResults {
                    if case .success(let record) = result, let asset = Asset(record: record) {
                        results.append(asset)
                    }
                }
                cursor = response.queryCursor
            } while cursor != nil
        } catch let error as CKError where error.code == .unknownItem || error.code == .invalidArguments {
            print("⚠️ CloudKit fetch failed for assets : \(error)")
            return []
        }

        return results
    }

    // MARK: - Write

    /// Saves (creates or updates) an asset. Applies last-write-wins conflict
    /// resolution: if the remote record is newer than `asset.modifiedAt`,
    /// the remote wins and is returned instead of overwriting it blindly.
    @discardableResult
    func upsert(_ asset: Asset) async throws -> Asset {
        guard isReachable else {
            ledger.append(PendingMutation(kind: .upsert, assetID: asset.id, assetPayload: asset))
            return asset
        }

        let recordID = CKRecord.ID(recordName: asset.id, zoneID: zoneID)
        do {
            let existing = try? await database.record(for: recordID)
            if let existing, let existingAsset = Asset(record: existing),
               existingAsset.modifiedAt > asset.modifiedAt {
                // Remote copy is newer -> remote wins (last-write-wins by timestamp).
                return existingAsset
            }
            let record = asset.toRecord(zoneID: zoneID, existing: existing)
            let saved = try await database.save(record)
            print("✅ CloudKit upsert succeeded for asset \(asset.id) — recordType: \(saved.recordType), zone: \(saved.recordID.zoneID)")
            return Asset(record: saved) ?? asset
        } catch {
            // Network / CloudKit failure -> queue for later, WITH the full
            // payload so a later app relaunch can still replay it.
            print("⚠️ CloudKit upsert failed for asset \(asset.id): \(error)")
            markUnreachable()
            ledger.append(PendingMutation(kind: .upsert, assetID: asset.id, assetPayload: asset))
            throw error
        }
    }

    func delete(assetID: String) async throws {
        guard isReachable else {
            ledger.append(PendingMutation(kind: .delete, assetID: assetID, assetPayload: nil))
            return
        }
        let recordID = CKRecord.ID(recordName: assetID, zoneID: zoneID)
        do {
            _ = try await database.deleteRecord(withID: recordID)
        } catch {
            markUnreachable()
            ledger.append(PendingMutation(kind: .delete, assetID: assetID, assetPayload: nil))
            throw error
        }
    }

    /// Batch-commits an array of assets (used by the legacy .mcs migration import).
    func batchUpsert(_ assets: [Asset]) async throws {
        let zoneID = self.zoneID
        let records = assets.map { $0.toRecord(zoneID: zoneID) }
        let op = CKModifyRecordsOperation(recordsToSave: records, recordIDsToDelete: nil)
        op.savePolicy = .changedKeys
        try await database.modifyRecords(saving: records, deleting: [])
    }

    // MARK: - Offline ledger flushing

    /// Replays queued mutations — called on reconnect and on every app
    /// launch (via `bootstrap()`). No external asset lookup needed anymore:
    /// each mutation now carries its own payload, so this works correctly
    /// even in a brand-new app session with an empty in-memory asset list.
    func flushOfflineLedger() async {
        isReachable = true
        let pending = ledger.load()
        guard !pending.isEmpty else { return }

        var remaining: [PendingMutation] = []
        for mutation in pending {
            do {
                switch mutation.kind {
                case .upsert:
                    guard let asset = mutation.assetPayload else { continue }
                    _ = try await upsert(asset)
                case .delete:
                    try await delete(assetID: mutation.assetID)
                }
            } catch {
                remaining.append(mutation)
            }
        }
        ledger.save(remaining)
    }

    private func markUnreachable() {
        isReachable = false
    }
}
