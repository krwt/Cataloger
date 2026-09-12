import Foundation

/// Minimal RFC4180-style CSV parser: handles quoted fields, embedded
/// commas inside quotes, escaped `""` for a literal quote, and both
/// `\n` and `\r\n` line endings. Matches exactly what `CSVExportManager`
/// produces, so a round-trip export -> restore doesn't corrupt data.
enum CSVParser {
    static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        var currentRow: [String] = []
        var currentField = ""
        var insideQuotes = false

        let chars = Array(text)
        var i = 0

        while i < chars.count {
            let char = chars[i]

            if insideQuotes {
                if char == "\"" {
                    if i + 1 < chars.count, chars[i + 1] == "\"" {
                        currentField.append("\"")
                        i += 2
                    } else {
                        insideQuotes = false
                        i += 1
                    }
                } else {
                    currentField.append(char)
                    i += 1
                }
                continue
            }

            switch char {
            case "\"":
                insideQuotes = true
                i += 1
            case ",":
                currentRow.append(currentField)
                currentField = ""
                i += 1
            case "\n":
                currentRow.append(currentField)
                rows.append(currentRow)
                currentRow = []
                currentField = ""
                i += 1
            case "\r":
                i += 1 // swallow; the following \n (if any) ends the row
            default:
                currentField.append(char)
                i += 1
            }
        }

        // Flush a trailing field/row that wasn't newline-terminated.
        if !currentField.isEmpty || !currentRow.isEmpty {
            currentRow.append(currentField)
            rows.append(currentRow)
        }

        return rows
    }
}
