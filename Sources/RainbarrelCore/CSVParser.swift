import Foundation

/// A small RFC 4180 style CSV parser: quoted fields may contain commas, doubled quotes
/// and line breaks; rows end at LF, CRLF or CR; a leading UTF-8 byte order mark is ignored.
public enum CSVParser {
    /// Parse `bytes` and call `row` for each record. Completely empty lines are skipped.
    public static func parse(_ bytes: [UInt8], row: ([String]) throws -> Void) rethrows {
        let quote = UInt8(ascii: "\""), comma = UInt8(ascii: ","), lf = UInt8(10), cr = UInt8(13)
        var fields: [String] = []
        var field: [UInt8] = []
        var inQuotes = false
        var index = 0
        let count = bytes.count
        if count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { index = 3 }

        func endField() {
            fields.append(String(decoding: field, as: UTF8.self))
            field.removeAll(keepingCapacity: true)
        }

        while index < count {
            let byte = bytes[index]
            if inQuotes {
                if byte == quote {
                    if index + 1 < count, bytes[index + 1] == quote {
                        field.append(quote)
                        index += 1
                    } else {
                        inQuotes = false
                    }
                } else {
                    field.append(byte)
                }
            } else {
                switch byte {
                case quote where field.isEmpty:
                    inQuotes = true
                case comma:
                    endField()
                case lf, cr:
                    if byte == cr, index + 1 < count, bytes[index + 1] == lf { index += 1 }
                    endField()
                    if !(fields.count == 1 && fields[0].isEmpty) { try row(fields) }
                    fields.removeAll(keepingCapacity: true)
                default:
                    field.append(byte)
                }
            }
            index += 1
        }
        if !field.isEmpty || !fields.isEmpty {
            endField()
            if !(fields.count == 1 && fields[0].isEmpty) { try row(fields) }
        }
    }

    /// Convenience that collects all records.
    public static func parse(_ text: String) -> [[String]] {
        var rows: [[String]] = []
        parse(Array(text.utf8)) { rows.append($0) }
        return rows
    }
}
