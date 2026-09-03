import Foundation
import Observation

/// The single source of truth for all active views, per the architecture
/// blueprint. All filtering, search, and tag auto-complete happen entirely
/// in-memory against `assets`.
@Observable
final class AppStore {

    // MARK: - Core state
    private(set) var assets: [Asset] = []
    var searchText: String = ""
    var selectedAssetIDs: Set<String> = []
    var isLoading = false
    var lastError: String?

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

    /// Search + sidebar filtering, entirely in-memory.
    var visibleAssets: [Asset] {
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
        guard !trimmed.isEmpty else { return result }

        let needle = trimmed.lowercased()
        return result.filter {
            $0.name.lowercased().contains(needle)
                || $0.qrLabelDisplayText.lowercased().contains(needle)
                || $0.tags.contains { $0.lowercased().contains(needle) }
        }
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

    func bootstrap() async {
        isLoading = true
        defer { isLoading = false }
        do {
            try await cloudKit.bootstrap()
            assets = try await cloudKit.fetchAllAssets()
        } catch {
            lastError = "Could not connect to iCloud: \(error.localizedDescription)"
        }
    }

    func refresh() async {
        do {
            assets = try await cloudKit.fetchAllAssets()
        } catch {
            lastError = "Refresh failed: \(error.localizedDescription)"
        }
    }

    // MARK: - Mutations

    @discardableResult
    func save(_ asset: Asset) async -> Asset {
        var toSave = asset
        toSave.name = Asset.sanitize(toSave.name)
        toSave.itemDescription = Asset.sanitize(toSave.itemDescription)
        toSave.containerLocation = Asset.sanitize(toSave.containerLocation)
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .capitalized
        var seenTags = Set<String>()
        toSave.tags = toSave.tags
            .map(Asset.normalizeTag)
            .filter { !$0.isEmpty && seenTags.insert($0).inserted }
        toSave.modifiedAt = Date()

        if let index = assets.firstIndex(where: { $0.id == toSave.id }) {
            assets[index] = toSave
        } else {
            assets.append(toSave)
        }

        do {
            let resolved = try await cloudKit.upsert(toSave)
            if let index = assets.firstIndex(where: { $0.id == resolved.id }) {
                assets[index] = resolved // may reflect remote last-write-wins result
            }
            return resolved
        } catch {
            lastError = "Saved locally; will sync when online."
            return toSave
        }
    }

    func delete(assetID: String) async {
        assets.removeAll { $0.id == assetID }
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

    func batchMove(ids: Set<String>, toContainer container: String) async {
        for id in ids {
            guard var asset = assets.first(where: { $0.id == id }) else { continue }
            asset.containerLocation = container
            await save(asset)
        }
        selectedAssetIDs.removeAll()
    }

    func batchToggleCheckout(ids: Set<String>) async {
        // Determine target state: if any are currently checked-in, check all out; else check all in.
        let targetState = ids.contains { id in
            !(assets.first(where: { $0.id == id })?.isCheckedOut ?? true)
        }
        for id in ids {
            guard var asset = assets.first(where: { $0.id == id }) else { continue }
            asset.isCheckedOut = targetState
            await save(asset)
        }
    }

    func batchAddTag(ids: Set<String>, tag: String) async {
        let cleanTag = Asset.normalizeTag(tag)
        guard !cleanTag.isEmpty else { return }
        for id in ids {
            guard var asset = assets.first(where: { $0.id == id }) else { continue }
            if !asset.tags.contains(where: { Asset.normalizeTag($0) == cleanTag }) {
                asset.tags.append(cleanTag)
            }
            await save(asset)
        }
        selectedAssetIDs.removeAll()
    }

    // MARK: - CSV export (on-demand, manual trigger only)

    @discardableResult
    func exportCSV() throws -> URL {
        try CSVExportManager.export(assets: assets, to: exportDirectory)
    }

    // MARK: - Legacy migration

    func importLegacy(fileURL: URL) async throws -> LegacyMigrationManager.MigrationResult {
        let result = try LegacyMigrationManager.migrate(fileURL: fileURL)
        assets.append(contentsOf: result.assets)
        try await cloudKit.batchUpsert(result.assets)
        return result
    }
}
