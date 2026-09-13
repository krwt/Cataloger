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
    /// Returns how many previously-queued offline mutations still failed
    /// after this retry attempt (0 if none, or if there was nothing queued).
    @discardableResult
    func bootstrap() async throws -> Int {
        let zone = CKRecordZone(zoneID: zoneID)
        _ = try await database.save(zone)

        let subscription = CKRecordZoneSubscription(zoneID: zoneID, subscriptionID: Self.subscriptionID)
        let notificationInfo = CKSubscription.NotificationInfo()
        notificationInfo.shouldSendContentAvailable = true
        subscription.notificationInfo = notificationInfo
        _ = try? await database.save(subscription)

        return await flushOfflineLedger()
    }

    /// Current count of mutations still waiting to sync (queued because a
    /// previous attempt failed). Exposed so the UI can show "N items
    /// awaiting sync" without needing to know about the ledger's storage
    /// format.
    func pendingMutationCount() -> Int {
        ledger.load().count
    }

    /// The queued mutations themselves. Each `.upsert` carries a full
    /// `Asset` payload, so callers can show locally-made-but-not-yet-synced
    /// work without waiting for (or depending on) a successful push.
    func pendingMutations() -> [PendingMutation] {
        ledger.load()
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
        // Queries against a real custom field (`modifiedAt`, always set on
        // every saved Asset) rather than the system `recordName` field.
        // `recordName` requires a Queryable index too, but it's a reserved
        // system field that can't be indexed through the normal "Add Field"
        // flow in the CloudKit Dashboard — a real field sidesteps that.
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
            print("⚠️ CloudKit fetch returned unknownItem/invalidArguments, treating as empty: \(error)")
            return []
        }

        return results
    }

    // MARK: - Write

    /// Performs the actual CloudKit write with last-write-wins resolution,
    /// WITHOUT touching the offline ledger or reachability state. Used by
    /// `upsert` (which adds the queueing behavior around it) and by
    /// `flushOfflineLedger` (which must not re-queue what it's draining).
    private func performUpsert(_ asset: Asset) async throws -> Asset {
        let recordID = CKRecord.ID(recordName: asset.id, zoneID: zoneID)
        let existing = try? await database.record(for: recordID)
        if let existing, let existingAsset = Asset(record: existing),
           existingAsset.modifiedAt > asset.modifiedAt {
            // Remote copy is newer -> remote wins (last-write-wins by timestamp).
            return existingAsset
        }
        let record = asset.toRecord(zoneID: zoneID, existing: existing)
        let saved = try await database.save(record)
        return Asset(record: saved) ?? asset
    }

    /// Saves (creates or updates) an asset. Applies last-write-wins conflict
    /// resolution: if the remote record is newer than `asset.modifiedAt`,
    /// the remote wins and is returned instead of overwriting it blindly.
    @discardableResult
    func upsert(_ asset: Asset) async throws -> Asset {
        guard isReachable else {
            ledger.append(PendingMutation(kind: .upsert, assetID: asset.id, assetPayload: asset))
            return asset
        }

        do {
            let resolved = try await performUpsert(asset)
            print("✅ CloudKit upsert succeeded for asset \(asset.id)")
            return resolved
        } catch {
            // Network / CloudKit failure -> queue for later, WITH the full
            // payload so a later app relaunch can still replay it.
            print("⚠️ CloudKit upsert failed for asset \(asset.id): \(error)")
            markUnreachable()
            ledger.append(PendingMutation(kind: .upsert, assetID: asset.id, assetPayload: asset))
            throw error
        }
    }

    /// Ledger-free delete — see `performUpsert` for why this split exists.
    private func performDelete(assetID: String) async throws {
        let recordID = CKRecord.ID(recordName: assetID, zoneID: zoneID)
        _ = try await database.deleteRecord(withID: recordID)
    }

    func delete(assetID: String) async throws {
        guard isReachable else {
            ledger.append(PendingMutation(kind: .delete, assetID: assetID, assetPayload: nil))
            return
        }
        do {
            try await performDelete(assetID: assetID)
        } catch {
            markUnreachable()
            ledger.append(PendingMutation(kind: .delete, assetID: assetID, assetPayload: nil))
            throw error
        }
    }

    /// CloudKit hard-caps how many records a single modifyRecords call can
    /// carry (roughly 400 in practice). Anything larger needs to be split
    /// into multiple sequential batch calls.
    private static let maxBatchSize = 400

    /// Deletes many assets in a single batched CloudKit call, instead of
    /// one `deleteRecord` round-trip per item awaited sequentially. The
    /// sequential version was slow enough for large collections that
    /// users would close the app before it finished — this is the delete
    /// counterpart to `batchUpsert`. Any record that fails is queued into
    /// the offline ledger, same as single-item delete, so it's retried on
    /// next launch instead of being silently dropped.
    func batchDelete(assetIDs: [String]) async throws {
        let recordIDs = assetIDs.map { CKRecord.ID(recordName: $0, zoneID: zoneID) }
        var firstError: Error?
        var failedIDs: [String] = []

        for chunk in recordIDs.chunked(into: Self.maxBatchSize) {
            do {
                let result = try await database.modifyRecords(
                    saving: [],
                    deleting: chunk,
                    savePolicy: .changedKeys,
                    atomically: false
                )
                for (recordID, deleteResult) in result.deleteResults {
                    if case .failure(let error) = deleteResult {
                        if firstError == nil { firstError = error }
                        failedIDs.append(recordID.recordName)
                    }
                }
            } catch {
                // Whole chunk failed outright (e.g. network) — queue every
                // ID in this chunk for retry, not just log an error.
                if firstError == nil { firstError = error }
                failedIDs.append(contentsOf: chunk.map(\.recordName))
            }
        }

        for id in failedIDs {
            ledger.append(PendingMutation(kind: .delete, assetID: id, assetPayload: nil))
        }

        if let firstError { throw firstError }
    }

    /// Batch-commits an array of assets (used by legacy .mcs migration and
    /// CSV restore), automatically chunked to stay under CloudKit's
    /// per-request record limit. Any asset that fails to save is queued
    /// into the offline ledger with its full payload, same as single-item
    /// save, so it's retried on next launch instead of being lost.
    func batchUpsert(_ assets: [Asset]) async throws {
        let zoneID = self.zoneID
        let assetsByRecordID = Dictionary(
            uniqueKeysWithValues: assets.map { (CKRecord.ID(recordName: $0.id, zoneID: zoneID), $0) }
        )
        let records = assets.map { $0.toRecord(zoneID: zoneID) }
        var firstError: Error?
        var failedAssets: [Asset] = []

        for chunk in records.chunked(into: Self.maxBatchSize) {
            do {
                let result = try await database.modifyRecords(
                    saving: chunk,
                    deleting: [],
                    savePolicy: .changedKeys,
                    atomically: false
                )
                // atomically: false means one bad record doesn't roll back
                // the whole chunk — but we still want to surface if
                // anything failed, rather than silently reporting success
                // while some records never actually made it to CloudKit.
                for (recordID, saveResult) in result.saveResults {
                    if case .failure(let error) = saveResult {
                        if firstError == nil { firstError = error }
                        if let asset = assetsByRecordID[recordID] {
                            failedAssets.append(asset)
                        }
                    }
                }
            } catch {
                if firstError == nil { firstError = error }
                let chunkRecordIDs = Set(chunk.map(\.recordID))
                failedAssets.append(contentsOf: assetsByRecordID.compactMap { key, value in
                    chunkRecordIDs.contains(key) ? value : nil
                })
            }
        }

        for asset in failedAssets {
            ledger.append(PendingMutation(kind: .upsert, assetID: asset.id, assetPayload: asset))
        }

        if let firstError { throw firstError }
    }

    // MARK: - Offline ledger flushing

    /// Replays queued mutations — called on reconnect and on every app
    /// launch (via `bootstrap()`). Each mutation carries its own payload,
    /// so this works even in a brand-new session with an empty asset list.
    /// Returns how many mutations still failed after this attempt.
    ///
    /// Uses the ledger-free `performUpsert` / `performDelete` rather than
    /// the public `upsert` / `delete`. That distinction is load-bearing:
    /// the public versions queue their own failures into the ledger, and
    /// this method ends by overwriting the ledger with `remaining` — so
    /// anything they appended got wiped. Worse, once one failure flipped
    /// `isReachable` to false, every later `upsert` took its early-return
    /// guard, which appends and returns WITHOUT throwing. Those never
    /// landed in `remaining`, and the final `save` erased their appends,
    /// so a single mid-flush network failure silently dropped every
    /// remaining queued mutation. Now failures are tracked here, in one
    /// place, and nothing is lost.
    @discardableResult
    func flushOfflineLedger() async -> Int {
        isReachable = true
        let pending = ledger.load()
        guard !pending.isEmpty else { return 0 }

        var remaining: [PendingMutation] = []

        for mutation in pending {
            // Once the connection has dropped, stop hammering it — keep
            // every remaining mutation queued for the next attempt rather
            // than burning a failed round-trip on each one.
            guard isReachable else {
                remaining.append(mutation)
                continue
            }

            do {
                switch mutation.kind {
                case .upsert:
                    guard let asset = mutation.assetPayload else {
                        // No payload means this was queued by a build from
                        // before `assetPayload` existed. There's nothing to
                        // replay, so it's dropped rather than retried forever.
                        continue
                    }
                    _ = try await performUpsert(asset)
                case .delete:
                    try await performDelete(assetID: mutation.assetID)
                }
            } catch {
                markUnreachable()
                remaining.append(mutation)
            }
        }

        ledger.save(remaining)
        return remaining.count
    }

    private func markUnreachable() {
        isReachable = false
    }
}
