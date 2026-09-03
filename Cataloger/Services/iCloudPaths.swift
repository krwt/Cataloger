import Foundation

extension FileManager {
    /// The app's iCloud Drive "Documents" folder — the one that actually
    /// shows up in the Files app under iCloud Drive > Cataloger, matching
    /// v1's layout (`FileManager.default.url(forUbiquityContainerIdentifier:)`).
    ///
    /// Returns nil if iCloud Drive is unavailable (user not signed in, or
    /// iCloud Documents disabled for this app) — callers should handle that
    /// case explicitly rather than silently falling back to the local
    /// sandbox, since a silent fallback is exactly how a file "exports
    /// successfully" but never shows up anywhere the user can find it.
    static var iCloudDocumentsDirectory: URL? {
        guard let root = FileManager.default.url(forUbiquityContainerIdentifier: nil) else {
            return nil
        }
        let docs = root.appendingPathComponent("Documents", isDirectory: true)
        if !FileManager.default.fileExists(atPath: docs.path) {
            try? FileManager.default.createDirectory(at: docs, withIntermediateDirectories: true)
        }
        return docs
    }
}
