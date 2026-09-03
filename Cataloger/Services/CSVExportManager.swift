import Foundation

/// Implements the on-demand (manual, `•••` menu triggered) CSV export.
/// This file is a read-only convenience snapshot: editing it on disk never
/// syncs back into CloudKit.
enum CSVExportManager {

    static let fileName = "backup.csv"
    private static let header = ["Name", "Description", "Container Location", "Tags", "QR UUID", "Imgur URL", "Checked Out", "System UUID"]

    /// Writes the current in-memory asset set to `backup.csv` inside the
    /// app's iCloud Documents directory. Returns the file URL on success.
    @discardableResult
    static func export(assets: [Asset], to directory: URL) throws -> URL {
        var rows: [String] = [header.map(csvField).joined(separator: ",")]

        for asset in assets {
            let tagsField = asset.tags.joined(separator: Asset.tagDelimiter)
            let row = [
                asset.name,
                asset.itemDescription,
                asset.containerLocation,
                tagsField,
                asset.qrcodeUUID ?? "",
                asset.imgurURLString ?? "",
                asset.isCheckedOut ? "true" : "false",
                asset.id
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
