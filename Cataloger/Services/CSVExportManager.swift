import Foundation

/// Implements the on-demand (manual, `•••` menu triggered) CSV export.
/// This file is a read-only convenience snapshot: editing it on disk never
/// syncs back into CloudKit.
enum CSVExportManager {

    /// Timestamped filename, e.g. "backup-202609211622.csv" — each export
    /// gets its own file rather than always overwriting the same one.
    static var fileName: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyyMMddHHmm"
        return "backup-\(formatter.string(from: Date())).csv"
    }
    private static let header = [
        "Name", "Description", "Container Location", "Tags",
        "QR UUID", "Imgur URL", "Checked Out", "System UUID", "Created At"
    ]

    /// Writes the current in-memory asset set to `backup.csv` inside the
    /// app's iCloud Documents directory, oldest item first. Restore
    /// doesn't actually depend on this row order (it re-sorts by the
    /// "Created At" column explicitly), but writing it oldest-first reads
    /// naturally and matches the original .mcs append-log feel. Returns
    /// the file URL on success.
    @discardableResult
    static func export(assets: [Asset], to directory: URL) throws -> URL {
        let sortedAssets = assets.sorted { $0.createdAt < $1.createdAt }
        var rows: [String] = [header.map(csvField).joined(separator: ",")]

        let formatter = ISO8601DateFormatter()
        for asset in sortedAssets {
            let tagsField = asset.tags.joined(separator: Asset.tagDelimiter)
            let row = [
                asset.name,
                asset.itemDescription,
                asset.containerLocation,
                tagsField,
                asset.qrcodeUUID ?? "",
                asset.imgurURLString ?? "",
                asset.isCheckedOut ? "true" : "false",
                asset.id,
                formatter.string(from: asset.createdAt)
            ].map(csvField).joined(separator: ",")
            rows.append(row)
        }

        let csvString = rows.joined(separator: "\n")
        let url = directory.appendingPathComponent(fileName)
        try csvString.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Escapes a field per standard CSV quoting rules (commas, quotes, newlines).
    private static func csvField(_ value: String) -> String {
        guard value.contains(",") || value.contains("\"") || value.contains("\n") else {
            return value
        }
        let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        return "\"\(escaped)\""
    }
}
