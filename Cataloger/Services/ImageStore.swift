import Foundation
#if canImport(UIKit)
import UIKit
#endif

/// Manages the `/img` iCloud Drive sandbox folder. Uses the same
/// `<uuid>.heic` naming convention as v1 (via HEICHelper's
/// `UIImage.heic(compressionQuality:)`), so existing local backups from the
/// old app remain readable without a conversion pass.
enum ImageStore {

    private static var imgDirectory: URL {
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
    }

    static func localURL(for assetID: String) -> URL {
        imgDirectory.appendingPathComponent("\(assetID).heic")
    }

    /// Saves a HEIC copy locally. Requires `UIImage.heic(compressionQuality:)`
    /// from HEICHelper.swift (kept from v1).
    @discardableResult
    static func saveLocalCopy(image: UIImage, assetID: String) -> URL? {
        guard let heicData = image.heic(compressionQuality: 0.8) else { return nil }
        let url = localURL(for: assetID)
        FileManager.default.createFile(atPath: url.path, contents: heicData, attributes: nil)
        return url
    }

    static func loadLocalImage(assetID: String) -> Data? {
        try? Data(contentsOf: localURL(for: assetID))
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
