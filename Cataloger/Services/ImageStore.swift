import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Manages the `/img` iCloud Drive sandbox folder. Uses the same
/// `<uuid>.heic` naming convention as v1 (via HEICHelper's
/// `UIImage.heic(compressionQuality:)`), so existing local backups from the
/// old app remain readable without a conversion pass.
enum ImageStore {

    /// Resolved exactly once, on first access, and reused forever after.
    ///
    /// This used to be a computed `var`, which meant every single call to
    /// `localURL(for:)` re-ran `FileManager.iCloudDocumentsDirectory` ->
    /// `url(forUbiquityContainerIdentifier:)`. That call is documented by
    /// Apple as blocking and unsafe to call on the main thread — it can
    /// take hundreds of milliseconds depending on iCloud state — and it
    /// was being hit once per thumbnail, per row, per render pass, plus a
    /// `fileExists` stat and a possible `createDirectory` each time.
    /// A `static let` with an initializer is computed lazily and exactly
    /// once, and Swift guarantees that initialization is thread-safe.
    /// Call `prepare()` during app bootstrap to pay that one-time cost off
    /// the main thread instead of on whichever view happens to render first.
    private static let imgDirectory: URL = {
        // Falls back to the local sandbox only if iCloud Drive is genuinely
        // unavailable — photos still save locally so nothing is lost, they
        // just won't sync across devices until iCloud comes back.
        let base = FileManager.iCloudDocumentsDirectory
            ?? FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        let dir = base.appendingPathComponent("img", isDirectory: true)
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }()

    /// In-memory cache of already-decoded thumbnails, keyed by asset ID.
    /// Without this, scrolling or re-rendering the list re-reads and
    /// re-decodes the same HEIC files from disk over and over. NSCache
    /// evicts automatically under memory pressure, so this can't grow
    /// unbounded on a large collection.
    private static let memoryCache: NSCache<NSString, UIImage> = {
        let cache = NSCache<NSString, UIImage>()
        cache.countLimit = 300
        return cache
    }()

    /// Warms the directory lookup off the main thread. Safe to call more
    /// than once — the underlying `static let` only initializes once.
    static func prepare() async {
        await Task.detached(priority: .utility) { _ = imgDirectory }.value
    }

    static func localURL(for assetID: String) -> URL {
        imgDirectory.appendingPathComponent("\(assetID).heic")
    }

    /// Non-blocking memory-cache lookup. Returns nil if this asset's image
    /// hasn't been loaded from disk yet — safe to call from a view body.
    static func cachedImage(assetID: String) -> UIImage? {
        memoryCache.object(forKey: assetID as NSString)
    }

    /// Reads and decodes the local HEIC copy off the main thread, then
    /// caches the result. Returns nil if there's no local copy.
    static func loadImage(assetID: String) async -> UIImage? {
        if let cached = cachedImage(assetID: assetID) { return cached }

        let image = await Task.detached(priority: .userInitiated) { () -> UIImage? in
            guard let data = try? Data(contentsOf: localURL(for: assetID)) else { return nil }
            return UIImage(data: data)
        }.value

        if let image {
            memoryCache.setObject(image, forKey: assetID as NSString)
        }
        return image
    }

    /// Drops a stale cache entry — call after replacing an asset's photo so
    /// the list doesn't keep showing the previous image.
    static func invalidateCache(assetID: String) {
        memoryCache.removeObject(forKey: assetID as NSString)
    }

    /// Saves a HEIC copy locally. Requires `UIImage.heic(compressionQuality:)`
    /// from HEICHelper.swift (kept from v1).
    @discardableResult
    static func saveLocalCopy(image: UIImage, assetID: String) -> URL? {
        guard let heicData = image.heic(compressionQuality: 0.8) else { return nil }
        let url = localURL(for: assetID)
        FileManager.default.createFile(atPath: url.path, contents: heicData, attributes: nil)
        // Seed the cache with the image we already have in hand, so the
        // list shows the new photo immediately without a disk round-trip.
        memoryCache.setObject(image, forKey: assetID as NSString)
        return url
    }

    /// Dual-write: local HEIC sandbox copy first (durable, offline-safe
    /// source of truth), then attempt the Imgur OAuth+album upload.
    /// Returns the Imgur URL string if that leg succeeds, else nil — in
    /// which case the UI falls back to the local HEIC copy for display.
    static func dualUpload(image: UIImage, assetID: String, title: String, description: String) async -> String? {
        saveLocalCopy(image: image, assetID: assetID)
        guard let jpegData = image.jpegData(compressionQuality: 0.8) else { return nil }
        return try? await ImgurUploadManager.upload(imageData: jpegData, title: title, description: description)
    }
}
