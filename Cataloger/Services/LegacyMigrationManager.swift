import Foundation

/// Parses legacy v1 `.mcs` files: headerless, positional, comma-delimited.
///
/// Column map:
///   0 - Asset Name
///   1 - Description Notes
///   2 - Container Location
///   3 - Imgur URL Text
///   4 - System UUID
///   5 - QR Code UUID
enum LegacyMigrationManager {

    enum MigrationError: Error {
        case emptyFile
        case unreadable
    }

    struct MigrationResult {
        var assets: [Asset]
        var skippedLineNumbers: [Int]     // rows dropped due to missing required fields
        var duplicateIDsReassigned: Int   // rows that shared a System UUID with an earlier row and got a fresh one, so nothing is lost
    }

    /// v1's own writer (`Items.getData`) skips any line with fewer than 5
    /// comma-separated fields (name/description/location/imgUrl/uuid at
    /// minimum; the 6th, QR uuid, is optional). Matched here for parity.

    static func migrate(fileURL: URL) throws -> MigrationResult {
        guard let contents = try? String(contentsOf: fileURL, encoding: .utf8) else {
            throw MigrationError.unreadable
        }

        let lines = contents
            .components(separatedBy: .newlines)
            .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        guard !lines.isEmpty else { throw MigrationError.emptyFile }

        var assets: [Asset] = []
        var skipped: [Int] = []

        // v1's .mcs format has no timestamp field at all — line position is
        // the only signal available for chronological order. Assign each
        // row a synthetic, strictly-increasing timestamp based on its
        // position in the file, anchored far enough in the past that any
        // item added today in the new app always sorts above the entire
        // imported batch.
        let anchorDate = Date(timeIntervalSince1970: 0)

        for (index, line) in lines.enumerated() {
            let fields = line.components(separatedBy: ",")

            // Defensive check: a row with fewer than the required columns
            // (e.g. missing trailing QR/UUID fields) is padded rather than
            // dropped, so a short row never shifts subsequent indices.
            guard fields.count >= 5, !fields[0].trimmingCharacters(in: .whitespaces).isEmpty else {
                skipped.append(index + 1)
                continue
            }

            func field(_ i: Int) -> String {
                i < fields.count ? fields[i].trimmingCharacters(in: .whitespaces) : ""
            }

            let name = Asset.sanitize(field(0))
            let description = Asset.sanitize(field(1))
            let container = Asset.sanitize(field(2))
            let imgurURL = field(3)
            let systemUUID = field(4).isEmpty ? UUID().uuidString : field(4)
            let qrUUID = field(5)
            let syntheticCreatedAt = anchorDate.addingTimeInterval(TimeInterval(index))

            let asset = Asset(
                id: systemUUID,
                name: name,
                itemDescription: description,
                containerLocation: container,
                tags: [],                      // migrated assets start with no tags
                qrcodeUUID: qrUUID.isEmpty ? nil : qrUUID,
                imgurURLString: imgurURL.isEmpty ? nil : imgurURL,
                isCheckedOut: false,
                modifiedAt: syntheticCreatedAt,
                createdAt: syntheticCreatedAt
            )
            assets.append(asset)
        }

        // v1's own update() function (see Item.swift) appended a new line
        // per edit without ever removing the old one, so a long-lived .mcs
        // file can contain many rows sharing the same UUID. Rather than
        // collapsing those down to just the last one (which would discard
        // whatever the earlier rows described), every row after the first
        // occurrence of a given UUID gets a fresh, unique one instead —
        // preserving all of them as distinct items. This also happens to
        // be required for CloudKit's batch write, which hard-rejects a
        // request containing the same record ID more than once.
        var seenIDs = Set<String>()
        var finalAssets: [Asset] = []
        var reassignedCount = 0

        for var asset in assets {
            if seenIDs.contains(asset.id) {
                asset.id = UUID().uuidString
                reassignedCount += 1
            }
            seenIDs.insert(asset.id)
            finalAssets.append(asset)
        }

        return MigrationResult(assets: finalAssets, skippedLineNumbers: skipped, duplicateIDsReassigned: reassignedCount)
    }
}
