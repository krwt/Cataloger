import Foundation

/// Reads the app's own `backup.csv` export back in — a real backup/restore
/// path, distinct from `LegacyMigrationManager` (which reads v1's headerless
/// `.mcs` format with a completely different column layout). These two
/// formats are NOT interchangeable: renaming a `.csv` export to `.mcs` and
/// running it through the legacy importer will misparse the header row,
/// drop tags/checkout state, and produce duplicates instead of updates.
enum CSVBackupManager {
    enum RestoreError: LocalizedError {
        case unreadable
        case emptyFile

        var errorDescription: String? {
            switch self {
            case .unreadable: return "Couldn't read that file."
            case .emptyFile: return "That backup file is empty."
            }
        }
    }

    struct RestorePreview {
        var assets: [Asset]
        var updatedCount: Int   // matches an existing System UUID
        var createdCount: Int   // no matching System UUID -> new item
        var skippedRowCount: Int
    }

    private static let expectedHeader = [
        "Name", "Description", "Container Location", "Tags",
        "QR UUID", "Imgur URL", "Checked Out", "System UUID", "Created At"
    ]

    /// Parses the file and classifies each row as update-vs-create against
    /// the currently loaded assets, WITHOUT committing anything — lets the
    /// caller show a confirmation summary before actually restoring.
    static func preview(fileURL: URL, existingAssets: [Asset]) throws -> RestorePreview {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw RestoreError.unreadable
        }

        var rows = CSVParser.parse(contents)
        guard !rows.isEmpty else { throw RestoreError.emptyFile }

        // Detect the header by its first cell rather than requiring an
        // exact full-row match against `expectedHeader` — tolerates older
        // exports (from before the "Created At" column existed) without
        // treating the header itself as a malformed data row.
        if let first = rows.first, first.first?.trimmingCharacters(in: .whitespaces) == "Name" {
            rows.removeFirst()
        }

        let existingIDs = Set(existingAssets.map(\.id))
        var restored: [Asset] = []
        var skipped = 0
        let dateFormatter = ISO8601DateFormatter()

        for row in rows {
            guard row.count >= 8 else { skipped += 1; continue }

            let name = row[0].trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { skipped += 1; continue }

            let description = row[1]
            let container = row[2]
            let tags = row[3]
                .components(separatedBy: Asset.tagDelimiter)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            let qrUUID = row[4].trimmingCharacters(in: .whitespaces)
            let imgurURL = row[5].trimmingCharacters(in: .whitespaces)
            let isCheckedOut = row[6].trimmingCharacters(in: .whitespaces).lowercased() == "true"
            let systemUUID = row[7].trimmingCharacters(in: .whitespaces)
            // "Created At" is column 9 — absent in exports from before this
            // field existed, so fall back to "now" rather than failing the
            // whole row on an older backup file.
            let createdAt: Date = {
                guard row.count > 8 else { return Date() }
                return dateFormatter.date(from: row[8].trimmingCharacters(in: .whitespaces)) ?? Date()
            }()

            let asset = Asset(
                id: systemUUID.isEmpty ? UUID().uuidString : systemUUID,
                name: name,
                itemDescription: description,
                containerLocation: container,
                tags: tags,
                qrcodeUUID: qrUUID.isEmpty ? nil : qrUUID,
                imgurURLString: imgurURL.isEmpty ? nil : imgurURL,
                isCheckedOut: isCheckedOut,
                createdAt: createdAt
            )
            restored.append(asset)
        }

        let updated = restored.filter { existingIDs.contains($0.id) }.count
        let created = restored.count - updated

        return RestorePreview(assets: restored, updatedCount: updated, createdCount: created, skippedRowCount: skipped)
    }
}
