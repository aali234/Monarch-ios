import Foundation

public enum CSVError: Error, LocalizedError {
    case malformed, empty, missingColumns, invalidRow(Int), tooLarge
    public var errorDescription: String? {
        switch self {
        case .malformed: "The CSV has an unclosed quoted field."
        case .empty: "The file has no data rows."
        case .missingColumns: "Map the date, description, and amount columns."
        case .invalidRow(let row): "Check the date and amount on CSV row \(row). Nothing was imported."
        case .tooLarge: "Choose a CSV smaller than 10 MB."
        }
    }
}

public struct CSVMapping: Codable, Sendable {
    public var dateColumn: Int
    public var descriptionColumn: Int
    public var amountColumn: Int
    public var dateFormat: String
    public var positiveIsOutflow: Bool
    public init(dateColumn: Int = 0, descriptionColumn: Int = 1, amountColumn: Int = 2, dateFormat: String = "yyyy-MM-dd", positiveIsOutflow: Bool = false) {
        self.dateColumn = dateColumn; self.descriptionColumn = descriptionColumn; self.amountColumn = amountColumn
        self.dateFormat = dateFormat; self.positiveIsOutflow = positiveIsOutflow
    }
}

public struct CSVDocument: Sendable {
    public var headers: [String]
    public var rows: [[String]]
    public init(text: String) throws {
        guard text.utf8.count <= 10 * 1024 * 1024 else { throw CSVError.tooLarge }
        var rows: [[String]] = []
        var row: [String] = []
        var field = ""
        var quoted = false
        let characters = Array(text.replacingOccurrences(of: "\u{FEFF}", with: ""))
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "\"" {
                if quoted, index + 1 < characters.count, characters[index + 1] == "\"" { field.append("\""); index += 1 }
                else { quoted.toggle() }
            } else if character == ",", !quoted {
                row.append(field); field = ""
            } else if (character == "\n" || character == "\r" || character == "\r\n"), !quoted {
                row.append(field); field = ""
                if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
                row = []
                if character == "\r", index + 1 < characters.count, characters[index + 1] == "\n" { index += 1 }
            } else { field.append(character) }
            index += 1
        }
        guard !quoted else { throw CSVError.malformed }
        row.append(field)
        if !row.allSatisfy({ $0.isEmpty }) { rows.append(row) }
        guard rows.count > 1 else { throw CSVError.empty }
        headers = rows.removeFirst(); self.rows = rows
    }

    public func entries(accountID: String, mapping: CSVMapping) throws -> [EntryValue] {
        let columns = [mapping.dateColumn, mapping.descriptionColumn, mapping.amountColumn]
        guard Set(columns).count == 3, columns.allSatisfy({ headers.indices.contains($0) }) else { throw CSVError.missingColumns }
        var occurrences: [String: Int] = [:]
        return try rows.enumerated().map { index, row in
            guard columns.allSatisfy({ row.indices.contains($0) }),
                  let date = LedgerDate.parse(row[mapping.dateColumn].trimmingCharacters(in: .whitespacesAndNewlines), format: mapping.dateFormat),
                  let rawAmount = Money.decimal(row[mapping.amountColumn]) else { throw CSVError.invalidRow(index + 2) }
            let amount = mapping.positiveIsOutflow ? -rawAmount : rawAmount
            let description = row[mapping.descriptionColumn].trimmingCharacters(in: .whitespacesAndNewlines)
            let normalized = description.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
            // JSON gives unambiguous separators even when a merchant contains punctuation.
            let components = [accountID, LedgerDate.string(date), NSDecimalNumber(decimal: amount).stringValue, normalized]
            let base = String(data: try JSONEncoder().encode(components), encoding: .utf8)!
            let occurrence = occurrences[base, default: 0]
            occurrences[base] = occurrence + 1
            let hash = StableHash.sha256(base + "#\(occurrence)")
            return EntryValue(id: "csv-\(hash)", accountID: accountID, date: date, amount: amount, merchant: description, originalDescription: description, importHash: hash)
        }
    }
}

/// Small dependency-free SHA-256 for stable CSV identities on iOS and Linux.
public enum StableHash {
    private static let constants: [UInt32] = [
        0x428a2f98,0x71374491,0xb5c0fbcf,0xe9b5dba5,0x3956c25b,0x59f111f1,0x923f82a4,0xab1c5ed5,
        0xd807aa98,0x12835b01,0x243185be,0x550c7dc3,0x72be5d74,0x80deb1fe,0x9bdc06a7,0xc19bf174,
        0xe49b69c1,0xefbe4786,0x0fc19dc6,0x240ca1cc,0x2de92c6f,0x4a7484aa,0x5cb0a9dc,0x76f988da,
        0x983e5152,0xa831c66d,0xb00327c8,0xbf597fc7,0xc6e00bf3,0xd5a79147,0x06ca6351,0x14292967,
        0x27b70a85,0x2e1b2138,0x4d2c6dfc,0x53380d13,0x650a7354,0x766a0abb,0x81c2c92e,0x92722c85,
        0xa2bfe8a1,0xa81a664b,0xc24b8b70,0xc76c51a3,0xd192e819,0xd6990624,0xf40e3585,0x106aa070,
        0x19a4c116,0x1e376c08,0x2748774c,0x34b0bcb5,0x391c0cb3,0x4ed8aa4a,0x5b9cca4f,0x682e6ff3,
        0x748f82ee,0x78a5636f,0x84c87814,0x8cc70208,0x90befffa,0xa4506ceb,0xbef9a3f7,0xc67178f2
    ]
    private static func rotate(_ value: UInt32, _ count: UInt32) -> UInt32 { (value >> count) | (value << (32 - count)) }
    public static func sha256(_ text: String) -> String {
        var bytes = Array(text.utf8)
        let bitCount = UInt64(bytes.count) * 8
        bytes.append(0x80)
        while bytes.count % 64 != 56 { bytes.append(0) }
        bytes += (0..<8).reversed().map { UInt8(truncatingIfNeeded: bitCount >> ($0 * 8)) }
        var hash: [UInt32] = [0x6a09e667,0xbb67ae85,0x3c6ef372,0xa54ff53a,0x510e527f,0x9b05688c,0x1f83d9ab,0x5be0cd19]
        for start in stride(from: 0, to: bytes.count, by: 64) {
            var words = [UInt32](repeating: 0, count: 64)
            for index in 0..<16 {
                let offset = start + index * 4
                words[index] = UInt32(bytes[offset]) << 24 | UInt32(bytes[offset + 1]) << 16 | UInt32(bytes[offset + 2]) << 8 | UInt32(bytes[offset + 3])
            }
            for index in 16..<64 {
                let a = words[index - 15], b = words[index - 2]
                let s0 = rotate(a, 7) ^ rotate(a, 18) ^ (a >> 3)
                let s1 = rotate(b, 17) ^ rotate(b, 19) ^ (b >> 10)
                words[index] = words[index - 16] &+ s0 &+ words[index - 7] &+ s1
            }
            var a = hash[0], b = hash[1], c = hash[2], d = hash[3], e = hash[4], f = hash[5], g = hash[6], h = hash[7]
            for index in 0..<64 {
                let s1 = rotate(e, 6) ^ rotate(e, 11) ^ rotate(e, 25)
                let choice = (e & f) ^ (~e & g)
                let temp1 = h &+ s1 &+ choice &+ constants[index] &+ words[index]
                let s0 = rotate(a, 2) ^ rotate(a, 13) ^ rotate(a, 22)
                let majority = (a & b) ^ (a & c) ^ (b & c)
                let temp2 = s0 &+ majority
                h = g; g = f; f = e; e = d &+ temp1; d = c; c = b; b = a; a = temp1 &+ temp2
            }
            hash[0] &+= a; hash[1] &+= b; hash[2] &+= c; hash[3] &+= d
            hash[4] &+= e; hash[5] &+= f; hash[6] &+= g; hash[7] &+= h
        }
        return hash.map { String(format: "%08x", $0) }.joined()
    }
}
