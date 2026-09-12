import Foundation
import CloudKit

/// The core domain object tracked by the app.
struct Asset: Identifiable, Hashable, Codable {
    var id: String                     // System UUID (also used as CKRecord.recordID.recordName)
    var name: String
    var itemDescription: String
    var containerLocation: String
    var tags: [String]
    var qrcodeUUID: String?            // nil / "" -> "No Label"
    var imgurURLString: String?
    var isCheckedOut: Bool
    var modifiedAt: Date               // used for last-write-wins conflict resolution
    /// Set once, at the moment the item is first ever saved, and never
    /// touched again by any subsequent edit. This is what the list sorts
    /// by ("latest addition on top") — sorting by `modifiedAt` instead
    /// would reorder the whole list every time someone just edits a
    /// description, which isn't what "chronological by addition" means.
    var createdAt: Date

    static let tagDelimiter = "│"
    /// Characters that are blocked from Name / Description / Container / Tag fields
    /// because they collide with the CSV/tag serialization delimiter.
    static let forbiddenCharacters = CharacterSet(charactersIn: "|│")

    init(
        id: String = UUID().uuidString,
        name: String,
        itemDescription: String = "",
        containerLocation: String = "",
        tags: [String] = [],
        qrcodeUUID: String? = nil,
        imgurURLString: String? = nil,
        isCheckedOut: Bool = false,
        modifiedAt: Date = Date(),
        createdAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.itemDescription = itemDescription
        self.containerLocation = containerLocation
        self.tags = tags
        self.qrcodeUUID = qrcodeUUID
        self.imgurURLString = imgurURLString
        self.isCheckedOut = isCheckedOut
        self.modifiedAt = modifiedAt
        self.createdAt = createdAt
    }

    var qrLabelDisplayText: String {
        (qrcodeUUID?.isEmpty ?? true) ? "No Label" : qrcodeUUID!
    }

    /// Strips any forbidden delimiter characters from free-text input.
    static func sanitize(_ text: String) -> String {
        text.unicodeScalars
            .filter { !forbiddenCharacters.contains($0) }
            .reduce(into: "") { $0.unicodeScalars.append($1) }
    }

    /// Case-insensitive, whitespace-trimmed comparison key for container
    /// names — so "A1", "a1", and " A1 " are treated as the same container
    /// for filtering, grouping, and batch-move destination matching.
    static func normalizedContainerKey(_ container: String) -> String {
        container.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    /// Canonical form for a tag: sanitized, trimmed, and lowercased, so
    /// "Vintage", "vintage", and " vintage " all collapse to one tag rather
    /// than coexisting as separate near-duplicates.
    static func normalizeTag(_ tag: String) -> String {
        sanitize(tag).trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}

// MARK: - CloudKit bridging

extension Asset {
    static let recordType = "Asset"

    init?(record: CKRecord) {
        guard let name = record["name"] as? String else { return nil }
        self.id = record.recordID.recordName
        self.name = name
        self.itemDescription = record["itemDescription"] as? String ?? ""
        self.containerLocation = record["containerLocation"] as? String ?? ""
        self.tags = (record["tags"] as? String)?
            .components(separatedBy: Asset.tagDelimiter)
            .filter { !$0.isEmpty } ?? []
        self.qrcodeUUID = record["qrcodeUUID"] as? String
        self.imgurURLString = record["imgurURLString"] as? String
        self.isCheckedOut = (record["isCheckedOut"] as? Int64 ?? 0) == 1
        self.modifiedAt = record["modifiedAt"] as? Date ?? record.modificationDate ?? Date()
        // Records saved before this field existed fall back to CloudKit's
        // own system creationDate (stamped once, automatically, at first
        // save) rather than "now" — gives a real historical value instead
        // of clustering every pre-existing item at the moment of update.
        self.createdAt = record["createdAt"] as? Date ?? record.creationDate ?? Date()
    }

    /// Builds (or updates) a CKRecord for this asset inside a given custom zone.
    func toRecord(zoneID: CKRecordZone.ID, existing: CKRecord? = nil) -> CKRecord {
        let recordID = CKRecord.ID(recordName: id, zoneID: zoneID)
        let record = existing ?? CKRecord(recordType: Asset.recordType, recordID: recordID)
        record["name"] = name as CKRecordValue
        record["itemDescription"] = itemDescription as CKRecordValue
        record["containerLocation"] = containerLocation as CKRecordValue
        record["tags"] = tags.joined(separator: Asset.tagDelimiter) as CKRecordValue
        record["qrcodeUUID"] = (qrcodeUUID ?? "") as CKRecordValue
        record["imgurURLString"] = (imgurURLString ?? "") as CKRecordValue
        record["isCheckedOut"] = (isCheckedOut ? 1 : 0) as CKRecordValue
        record["modifiedAt"] = modifiedAt as CKRecordValue
        record["createdAt"] = createdAt as CKRecordValue
        return record
    }
}
