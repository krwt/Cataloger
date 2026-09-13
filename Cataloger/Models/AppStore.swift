import Foundation
import Observation

/// The single source of truth for all active views, per the architecture
/// blueprint. All filtering, search, and tag auto-complete happen entirely
/// in-memory against `assets`.
@Observable
final class AppStore {

    // MARK: - Core state
    private(set) var assets: [Asset] = []
    /// Bumped by `bumpRevision()` every time `assets` is mutated. Lets
    /// `visibleAssets` cheaply detect "have the assets actually changed
    /// since I last filtered/sorted them?" without deep-comparing the
    /// array itself. Reading this property inside `visibleAssets` is what
    /// keeps it participating in `@Observable`'s tracking, so a change
    /// still correctly triggers a re-render.
    private var assetsRevision: Int = 0
    var searchText: String = ""
    var selectedAssetIDs: Set<String> = []
    var isLoading = false
    var lastError: String?
    /// Set during any bulk CloudKit operation (delete all, legacy import,
    /// CSV restore) so the UI can show a visible "don't close the app yet"
    /// status — the local list updates instantly, but the actual CloudKit
    /// write happens after, and closing the app before it finishes means
    /// relaunch shows whatever *actually* made it to the server, not what
    /// you saw a moment ago.
    var isSyncing = false
    var syncStatusMessage = ""
    /// Live count of mutations still queued in the offline ledger, shown
    /// as "N items awaiting sync" in the sidebar.
    var pendingSyncCount = 0

    // Sidebar filter state (widescreen NavigationSplitView).
    enum SidebarFilter: Hashable {
        case all
        case checkedOut
        case container(String)
        case tag(String)
    }
    var activeSidebarFilter: SidebarFilter? = .all

    private let cloudKit = CloudKitManager(containerIdentifier: "iCloud.Cataloger")
    private var exportDirectory: URL {
        get throws {
            guard let dir = FileManager.iCloudDocumentsDirectory else {
                throw ExportError.iCloudUnavailable
            }
            return dir
        }
    }

    enum ExportError: LocalizedError {
        case iCloudUnavailable
        var errorDescription: String? {
            "iCloud Drive isn't available right now — make sure you're signed into iCloud and iCloud Documents is enabled for Cataloger."
        }
    }

    /// Off by default: list rows show a placeholder instead of fetching
    /// each item's Imgur image, since eagerly loading images for every row
    /// as they scroll into view can mean a lot of network activity for a
    /// large collection. Turning this on restores the old always-load
    /// behavior. Detail view and the full-screen preview always load the
    /// real image regardless of this setting — it only governs list rows.
    /// Backed by a stored property that's read from `UserDefaults` once at
    /// init and written through on change. Previously both the getter and
    /// setter hit `UserDefaults` directly, which meant every row in the
    /// list performed a `UserDefaults` lookup on every render pass — and,
    /// because a bare computed property over `UserDefaults` isn't part of
    /// `@Observable`'s tracking, toggling it didn't reliably refresh the
    /// list either. This fixes both.
    var preloadAllImages: Bool = UserDefaults.standard.bool(forKey: "preloadAllImages") {
        didSet {
            guard oldValue != preloadAllImages else { return }
            UserDefaults.standard.set(preloadAllImages, forKey: "preloadAllImages")
        }
    }

    // Imgur OAuth state, passed through from ImgurAuthManager for view binding.
    var imgurIsLoggedIn: Bool { ImgurAuthManager.shared.isLoggedIn }
    var imgurUserName: String? { ImgurAuthManager.shared.userName }
    var imgurAlbumId: String? { ImgurAuthManager.shared.albumId }

    func imgurLogIn() async throws {
        try await ImgurAuthManager.shared.login()
    }

    func imgurLogOut() {
        ImgurAuthManager.shared.logout()
    }

    @discardableResult
    func imgurCreateNewAlbum() async throws -> String {
        try await ImgurAuthManager.shared.createNewAlbum()
    }

    // MARK: - Derived / computed

    /// Memoizes the last computed `visibleAssets` result, keyed on the
    /// inputs that actually affect it. `@ObservationIgnored` because this
    /// is a private implementation detail, not user-facing state — it
    /// should never itself be treated as an observed dependency.
    @ObservationIgnored
    private var visibleAssetsCache: (revision: Int, searchText: String, filter: SidebarFilter?, result: [Asset])?

    /// Search + sidebar filtering, entirely in-memory. Sorted newest-first
    /// by `createdAt` ("latest addition on top") — deliberately not
    /// `modifiedAt`, since that would reorder the whole list every time
    /// someone just edits a description.
    ///
    /// Previously this re-filtered and re-sorted the *entire* `assets`
    /// array from scratch on every single access — and since it's a plain
    /// computed property read by SwiftUI's diffing, that could happen
    /// several times per render pass, on every keystroke in search. Now
    /// it's cached: if `assets` hasn't changed (`assetsRevision` is the
    /// same) and the search/filter inputs are the same, the previous
    /// result is returned directly instead of recomputing.
    var visibleAssets: [Asset] {
        if let cache = visibleAssetsCache,
           cache.revision == assetsRevision,
           cache.searchText == searchText,
           cache.filter == activeSidebarFilter {
            return cache.result
        }

        var result = assets

        switch activeSidebarFilter ?? .all {
        case .all: break
        case .checkedOut:
            result = result.filter { $0.isCheckedOut }
        case .container(let name):
            result = result.filter { Asset.normalizedContainerKey($0.containerLocation) == Asset.normalizedContainerKey(name) }
        case .tag(let tag):
            let target = Asset.normalizeTag(tag)
            result = result.filter { asset in asset.tags.contains { Asset.normalizeTag($0) == target } }
        }

        let trimmed = searchText.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty {
            let needle = trimmed.lowercased()
            result = result.filter {
                $0.name.lowercased().contains(needle)
                    || $0.qrLabelDisplayText.lowercased().contains(needle)
                    || $0.tags.contains { $0.lowercased().contains(needle) }
            }
        }

        let sorted = result.sorted { $0.createdAt > $1.createdAt }
        visibleAssetsCache = (assetsRevision, searchText, activeSidebarFilter, sorted)
        return sorted
    }

    /// True when the active search yields zero matches - drives the
    /// "pre-fill new item name from search" behavior in the Add flow.
    var searchHasNoMatches: Bool {
        !searchText.trimmingCharacters(in: .whitespaces).isEmpty && visibleAssets.isEmpty
    }

    /// All distinct tags currently in use, for auto-complete + the sidebar
    /// taxonomy tree. Normalized so legacy mixed-case tags saved before this
    /// fix still collapse together, not just newly-saved ones.
    var allTagsWithCounts: [(tag: String, count: Int)] {
        var counts: [String: Int] = [:]
        for asset in assets {
            for tag in asset.tags {
                let key = Asset.normalizeTag(tag)
                guard !key.isEmpty else { continue }
                counts[key, default: 0] += 1
            }
        }
        return counts.sorted { $0.key < $1.key }.map { (tag: $0.key, count: $0.value) }
    }

    /// Deduped container list, case-insensitive and whitespace-trimmed so
    /// "A1", "a1", and " A1 " are treated as the same container everywhere
    /// (sidebar, batch move, filtering) even if individual assets still
    /// have slightly different raw casing saved on them.
    var allContainers: [String] {
        var seen: [String: String] = [:] // normalized key -> first-seen display casing
        for asset in assets {
            let trimmed = asset.containerLocation.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let key = trimmed.lowercased()
            if seen[key] == nil { seen[key] = trimmed }
        }
        return seen.values.sorted()
    }

    /// Exact match (case-insensitive, whitespace-trimmed) duplicate-name lookup
    /// for the Add-view name matching dropdown. Deliberately modular so the
    /// matching strategy (exact -> fuzzy) can be swapped later without
    /// touching call sites.
    func nameMatches(_ query: String) -> [Asset] {
        let needle = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !needle.isEmpty else { return [] }
        return assets.filter {
            $0.name.trimmingCharacters(in: .whitespaces).lowercased() == needle
        }
    }

    // MARK: - Lifecycle

    /// Invalidates `visibleAssetsCache` by advancing the revision counter.
    /// Must be called after every mutation of `assets` — assignment,
    /// append, in-place element replacement, or removal.
    private func bumpRevision() {
        assetsRevision &+= 1
    }

    func bootstrap() async {
        // Fire-and-forget: resolving the iCloud ubiquity container is slow,
        // and nothing about loading the asset list depends on it. It only
        // needs to finish before a thumbnail renders, so awaiting it here
        // just delayed the list for no reason.
        Task { await ImageStore.prepare() }

        isLoading = true
        do {
            // Fetched FIRST, before zone/subscription setup and the ledger
            // flush. Those are two-plus network round-trips that only
            // matter for writes, and putting them ahead of the fetch meant
            // the list couldn't appear until they finished. On a brand-new
            // container the zone doesn't exist yet and this throws
            // `unknownItem` — which `fetchAllAssets` already catches and
            // reports as empty, so running it first is safe.
            assets = try await cloudKit.fetchAllAssets()
            bumpRevision()
        } catch {
            lastError = "Could not connect to iCloud: \(error.localizedDescription)"
        }
        isLoading = false

        // Zone + subscription setup and the offline-ledger replay happen
        // after the list is already on screen.
        do {
            let stillFailedCount = try await cloudKit.bootstrap()
            if stillFailedCount > 0 {
                lastError = "\(stillFailedCount) item(s) still couldn't sync to iCloud after retrying. They're saved on this device and will keep retrying — check your internet connection."
            }
        } catch {
            // Don't clobber a fetch error that's already being shown.
            if lastError == nil {
                lastError = "Could not connect to iCloud: \(error.localizedDescription)"
            }
        }
        await refreshPendingSyncCount()
    }

    /// Refreshes the visible "N items awaiting sync" count from the
    /// offline ledger. Called after any operation that could add to or
    /// drain that queue.
    func refreshPendingSyncCount() async {
        pendingSyncCount = await cloudKit.pendingMutationCount()
    }

    func refresh() async {
        do {
            assets = try await cloudKit.fetchAllAssets()
            bumpRevision()
        } catch {
            lastError = "Refresh failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Mutations

    /// Shared sanitization used by both single-item save and bulk import,
    /// so the two paths can't silently drift apart.
    private func sanitized(_ asset: Asset) -> Asset {
        var result = asset
        result.name = Asset.sanitize(result.name)
        result.itemDescription = Asset.sanitize(result.itemDescription)
        result.containerLocation = Asset.sanitize(result.containerLocation)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .capitalized
        var seenTags = Set<String>()
        result.tags = result.tags
            .map(Asset.normalizeTag)
            .filter { !$0.isEmpty && seenTags.insert($0).inserted }
        result.modifiedAt = Date()
        return result
    }

    @discardableResult
    func save(_ asset: Asset) async -> Asset {
        let toSave = sanitized(asset)

        if let index = assets.firstIndex(where: { $0.id == toSave.id }) {
            assets[index] = toSave
        } else {
            assets.append(toSave)
        }
        bumpRevision()

        do {
            let resolved = try await cloudKit.upsert(toSave)
            if let index = assets.firstIndex(where: { $0.id == resolved.id }) {
                assets[index] = resolved // may reflect remote last-write-wins result
                bumpRevision()
            }
            await refreshPendingSyncCount()
            return resolved
        } catch {
            lastError = "Saved locally; will sync when online."
            await refreshPendingSyncCount()
            return toSave
        }
    }

    /// Bulk-saves many assets at once (legacy `.mcs` import, CSV restore)
    /// using a single batched CloudKit write instead of one fetch-then-save
    /// round-trip per item. `save()`'s per-item existence check exists to
    /// support last-write-wins conflict resolution on regular edits, but
    /// for a bulk import of mostly-new items, that per-item "does this
    /// already exist?" check is an expected-but-still-counted failure for
    /// every new record — enough of them in a row triggers CloudKit's own
    /// error-rate throttling. This path skips that check entirely.
    func bulkSave(_ newAssets: [Asset]) async {
        let sanitizedAssets = newAssets.map(sanitized)

        // Defensive dedup by ID, keeping the last occurrence — CloudKit's
        // batch write hard-rejects a request containing the same record ID
        // more than once ("You can't save the same record twice"), failing
        // the *entire* batch. LegacyMigrationManager already dedupes at
        // the source, but this is cheap insurance against any other future
        // source of duplicate-ID batches (e.g. a manually concatenated
        // CSV backup file).
        var deduped: [String: Asset] = [:]
        var order: [String] = []
        for asset in sanitizedAssets {
            if deduped[asset.id] == nil { order.append(asset.id) }
            deduped[asset.id] = asset
        }
        let toSave = order.compactMap { deduped[$0] }

        isSyncing = true
        syncStatusMessage = "Syncing \(toSave.count) item(s) to iCloud…"
        defer { isSyncing = false }

        var indexByID: [String: Int] = [:]
        indexByID.reserveCapacity(assets.count)
        for (index, existing) in assets.enumerated() {
            indexByID[existing.id] = index
        }
        for asset in toSave {
            if let index = indexByID[asset.id] {
                assets[index] = asset
            } else {
                assets.append(asset)
                indexByID[asset.id] = assets.count - 1
            }
        }
        bumpRevision()

        do {
            try await cloudKit.batchUpsert(toSave)
        } catch {
            lastError = "Items saved locally but some failed to sync: \(error.localizedDescription)"
        }
        await refreshPendingSyncCount()
    }

    func delete(assetID: String) async {
        assets.removeAll { $0.id == assetID }
        bumpRevision()
        selectedAssetIDs.remove(assetID)
        do {
            try await cloudKit.delete(assetID: assetID)
        } catch {
            lastError = "Deleted locally; will sync when online."
        }
    }

    /// Returns the asset (if any) that already owns the given QR/barcode UUID,
    /// checked against the local in-memory cache only. Sync-time collisions
    /// (two offline devices assigning the same code) are resolved by
    /// last-write-wins at CloudKit sync time.
    func assetOwningQRCode(_ code: String, excluding assetID: String?) -> Asset? {
        assets.first { $0.qrcodeUUID == code && $0.id != assetID }
    }

    // MARK: - Batch operations (all require confirmation except Batch Checkout)

    /// Applies `mutate` to every targeted asset and commits all of them in
    /// a single batched CloudKit write.
    ///
    /// The three batch operations below used to each loop `ids` and call
    /// `save()` per item. That was O(N·K) locally — `save()`'s own
    /// `firstIndex(where:)` rescans the *entire* `assets` array for every
    /// one of the K selected items — and, separately, K fully sequential
    /// `await`ed network round-trips to CloudKit, one at a time. Neither
    /// cost is CloudKit-storage-related; both come from the loop shape
    /// itself. This builds an id -> index map once (O(N)), applies all K
    /// mutations against it (O(K)), and syncs with one `batchUpsert` call
    /// — the same batching approach `bulkSave` already uses for legacy/CSV
    /// import.
    private func applyBatchUpdate(
        ids: Set<String>,
        statusVerb: String,
        mutate: (inout Asset) -> Void
    ) async {
        guard !ids.isEmpty else { return }

        var indexByID: [String: Int] = [:]
        indexByID.reserveCapacity(assets.count)
        for (index, asset) in assets.enumerated() {
            indexByID[asset.id] = index
        }

        var updated: [Asset] = []
        updated.reserveCapacity(ids.count)

        for id in ids {
            guard let index = indexByID[id] else { continue }
            var asset = assets[index]
            mutate(&asset)
            let toSave = sanitized(asset)
            assets[index] = toSave
            updated.append(toSave)
        }

        guard !updated.isEmpty else { return }
        bumpRevision()

        isSyncing = true
        syncStatusMessage = "\(statusVerb) \(updated.count) item(s)…"
        defer { isSyncing = false }

        do {
            try await cloudKit.batchUpsert(updated)
        } catch {
            lastError = "Changes saved locally but some failed to sync: \(error.localizedDescription)"
        }
        await refreshPendingSyncCount()
    }

    func batchMove(ids: Set<String>, toContainer container: String) async {
        await applyBatchUpdate(ids: ids, statusVerb: "Moving") { asset in
            asset.containerLocation = container
        }
        selectedAssetIDs.removeAll()
    }

    func batchToggleCheckout(ids: Set<String>) async {
        // Determine target state: if any are currently checked-in, check all out; else check all in.
        let targetState = ids.contains { id in
            !(assets.first(where: { $0.id == id })?.isCheckedOut ?? true)
        }
        await applyBatchUpdate(ids: ids, statusVerb: "Updating checkout for") { asset in
            asset.isCheckedOut = targetState
        }
    }

    func batchAddTag(ids: Set<String>, tag: String) async {
        let cleanTag = Asset.normalizeTag(tag)
        guard !cleanTag.isEmpty else { return }
        await applyBatchUpdate(ids: ids, statusVerb: "Tagging") { asset in
            if !asset.tags.contains(where: { Asset.normalizeTag($0) == cleanTag }) {
                asset.tags.append(cleanTag)
            }
        }
        selectedAssetIDs.removeAll()
    }

    // MARK: - CSV export (on-demand, manual trigger only)

    @discardableResult
    func exportCSV() throws -> URL {
        try CSVExportManager.export(assets: assets, to: exportDirectory)
    }

    // MARK: - Legacy migration

    struct LegacyImportPreview {
        var assets: [Asset]
        var updatedCount: Int
        var createdCount: Int
        var skippedRowCount: Int
        var duplicateIDsReassigned: Int
    }

    /// Parses the `.mcs` file and classifies rows as update-vs-create
    /// against currently loaded assets, without committing anything yet —
    /// mirrors `previewCSVRestore`'s preview-then-confirm flow.
    func previewLegacyImport(fileURL: URL) throws -> LegacyImportPreview {
        let result = try LegacyMigrationManager.migrate(fileURL: fileURL)
        let existingIDs = Set(assets.map(\.id))
        let updated = result.assets.filter { existingIDs.contains($0.id) }.count
        let created = result.assets.count - updated
        return LegacyImportPreview(
            assets: result.assets,
            updatedCount: updated,
            createdCount: created,
            skippedRowCount: result.skippedLineNumbers.count,
            duplicateIDsReassigned: result.duplicateIDsReassigned
        )
    }

    /// Commits a previously-previewed legacy import via the same bulk path
    /// as CSV restore.
    func commitLegacyImport(_ assets: [Asset]) async {
        await bulkSave(assets)
    }

    // MARK: - CSV backup / restore

    /// Parses `fileURL` and reports what a restore would do, without
    /// committing anything yet — the caller shows this summary and asks
    /// for confirmation before calling `commitCSVRestore`.
    func previewCSVRestore(fileURL: URL) throws -> CSVBackupManager.RestorePreview {
        try CSVBackupManager.preview(fileURL: fileURL, existingAssets: assets)
    }

    /// Commits a previously-previewed restore. Uses `bulkSave` (a single
    /// batched CloudKit write) rather than looping `save()` per item —
    /// same reasoning as `importLegacy`: many per-item existence checks in
    /// a row trigger CloudKit's error-rate throttling.
    func commitCSVRestore(_ restoredAssets: [Asset]) async {
        await bulkSave(restoredAssets)
    }

    // MARK: - Delete all

    /// Permanently deletes every asset, locally and from CloudKit. The
    /// two-step warning lives in the UI layer — this function itself does
    /// not re-confirm, since by the time it's called the user has already
    /// been asked twice.
    func deleteAllAssets() async {
        let allIDs = assets.map(\.id)

        isSyncing = true
        syncStatusMessage = "Deleting \(allIDs.count) item(s) from iCloud…"
        defer { isSyncing = false }

        assets.removeAll()
        bumpRevision()
        selectedAssetIDs.removeAll()

        do {
            try await cloudKit.batchDelete(assetIDs: allIDs)
        } catch {
            lastError = "Items deleted locally but some failed to delete from iCloud: \(error.localizedDescription)"
        }
        await refreshPendingSyncCount()
    }
}
