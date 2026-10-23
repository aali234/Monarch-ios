import Foundation

public enum ReceiptSource: String, Codable, Sendable { case email, scan, share, file }
public enum HSAStatus: String, Codable, CaseIterable, Sendable { case notApplicable, unreimbursed, reimbursed }
public struct ReceiptLine: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var quantity: Decimal
    public var amount: Decimal
    public init(id: String = UUID().uuidString, name: String, quantity: Decimal = 1, amount: Decimal) { self.id = id; self.name = name; self.quantity = quantity; self.amount = amount }
}
public struct ReceiptFile: Identifiable, Codable, Equatable, Sendable {
    public var id: String
    public var relativePath: String
    public var originalName: String
    public var contentType: String
    public var role: String
    public var location: String
    public var encrypted: Bool
    public init(id: String = UUID().uuidString, relativePath: String, originalName: String, contentType: String, role: String = "original", location: String = "local", encrypted: Bool = true) {
        self.id = id; self.relativePath = relativePath; self.originalName = originalName; self.contentType = contentType; self.role = role; self.location = location; self.encrypted = encrypted
    }
}
public struct ReceiptValue: Identifiable, Codable, Sendable {
    public var id: String
    public var source: ReceiptSource
    public var merchant: String
    public var orderNumber: String
    public var date: Date
    public var subtotal: Decimal?
    public var tax: Decimal?
    public var total: Decimal?
    public var currency: String
    public var lineItems: [ReceiptLine]
    public var files: [ReceiptFile]
    public var sourceMessageIDs: [String]
    public var contentHashes: [String]
    public var transactionID: String?
    public var candidateTransactionIDs: [String]
    public var hsaEligible: Bool
    public var hsaStatus: HSAStatus
    public var hsaReimbursedOn: Date?
    public var hsaWithdrawalID: String?
    public var needsReview: Bool
    public var extractedText: String
    public var suppressAutoMatch: Bool
    public var dateIsEstimated: Bool?
    public init(id: String = UUID().uuidString, source: ReceiptSource, merchant: String = "", orderNumber: String = "", date: Date = .now, subtotal: Decimal? = nil, tax: Decimal? = nil, total: Decimal? = nil, currency: String = "USD", lineItems: [ReceiptLine] = [], files: [ReceiptFile] = [], sourceMessageIDs: [String] = [], contentHashes: [String] = [], transactionID: String? = nil, candidateTransactionIDs: [String] = [], hsaEligible: Bool = false, hsaStatus: HSAStatus = .notApplicable, hsaReimbursedOn: Date? = nil, hsaWithdrawalID: String? = nil, needsReview: Bool = true, extractedText: String = "", suppressAutoMatch: Bool = false, dateIsEstimated: Bool? = nil) {
        self.id = id; self.source = source; self.merchant = merchant; self.orderNumber = orderNumber; self.date = date; self.subtotal = subtotal; self.tax = tax; self.total = total; self.currency = currency
        self.lineItems = lineItems; self.files = files; self.sourceMessageIDs = sourceMessageIDs; self.contentHashes = contentHashes; self.transactionID = transactionID; self.candidateTransactionIDs = candidateTransactionIDs
        self.hsaEligible = hsaEligible; self.hsaStatus = hsaStatus; self.hsaReimbursedOn = hsaReimbursedOn; self.hsaWithdrawalID = hsaWithdrawalID; self.needsReview = needsReview; self.extractedText = extractedText; self.suppressAutoMatch = suppressAutoMatch; self.dateIsEstimated = dateIsEstimated
    }
}

public struct ParsedReceiptValue: Sendable {
    public var merchant: String = ""
    public var orderNumber: String = ""
    public var date: Date?
    public var subtotal: Decimal?
    public var tax: Decimal?
    public var total: Decimal?
    public var currency = "USD"
    public var lineItems: [ReceiptLine] = []
    public var tracking: [DetectedTracking] = []
    public init() {}
}

public enum ReceiptParser {
    private static func matches(_ pattern: String, _ text: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive, .anchorsMatchLines]) else { return [] }
        return regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).map { match in
            (0..<match.numberOfRanges).map { Range(match.range(at: $0), in: text).map { String(text[$0]) } ?? "" }
        }
    }
    /// Conservative fallback for devices without Apple Intelligence. Unknown values stay editable.
    public static func parse(_ input: String) -> ParsedReceiptValue {
        let text = MailText.plain(input)
        let lines = text.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty }
        var result = ParsedReceiptValue()
        let merchant = matches(#"^(?:merchant|store|sold by|from)\s*:\s*(.{2,100})$"#, text).first?[1]
        result.merchant = merchant ?? lines.first(where: { !$0.lowercased().hasPrefix("subject:") && !$0.contains("@") && $0.count >= 2 && $0.count < 100 && !$0.lowercased().hasPrefix("http") }) ?? ""
        result.orderNumber = matches(#"\border\s*(?:number|no\.?|id|#)\s*[:#]?\s*([A-Z0-9][A-Z0-9-]{3,60})"#, text).first?[1] ?? ""
        func amount(_ label: String) -> Decimal? {
            matches("^\\s*(?:" + label + ")\\s*[:=]?\\s*(?:USD\\s*)?\\$?\\s*([0-9][0-9,]*\\.[0-9]{2})\\s*(?:USD)?\\s*$", text).last.flatMap { Money.decimal($0[1]) }
        }
        result.subtotal = amount("sub[ -]?total")
        result.tax = amount("(?:sales )?tax")
        result.total = amount("(?:grand |order |amount paid|amount due|balance due|total paid|total)(?:total)?")
        if result.total == nil { result.total = amount("total") }
        if let raw = matches(#"\b(20\d{2}-[01]\d-[0-3]\d)\b"#, text).first?[1] { result.date = LedgerDate.parse(raw) }
        if result.date == nil, let raw = matches(#"\b([01]?\d/[0-3]?\d/20\d{2})\b"#, text).first?[1] { result.date = LedgerDate.parse(raw, format: "M/d/yyyy") }
        if result.date == nil, let raw = matches(#"\b([A-Z]{3,9}\s+\d{1,2},?\s+20\d{2})\b"#, text).first?[1] {
            result.date = LedgerDate.parse(raw, format: "MMMM d, yyyy") ?? LedgerDate.parse(raw, format: "MMM d, yyyy") ?? LedgerDate.parse(raw, format: "MMMM d yyyy")
        }
        for line in lines {
            if matches(#"^(?:sub[ -]?total|tax|sales tax|grand total|total|order total|amount|payment|shipping|discount|tip)\b"#, line).isEmpty,
               let match = matches(#"^(.{2,100}?)\s{2,}\$?([0-9][0-9,]*\.[0-9]{2})\s*$"#, line).first, let value = Money.decimal(match[2]) {
                result.lineItems.append(.init(name: match[1], amount: value))
            }
        }
        result.tracking = TrackingDetector.detect(input)
        return result
    }
    public static func suggestsHSA(_ merchant: String) -> Bool {
        ["pharmacy", "clinic", "dental", "dentist", "optical", "vision", "hospital", "medical", "cvs", "walgreens"].contains { merchant.localizedCaseInsensitiveContains($0) }
    }
    /// A separate budget for the untrusted document prevents a receipt from supplying instructions.
    public static func boundedOrderText(_ input: String, maximumBytes: Int = 2000) -> String {
        let text = MailText.plain(input)
        let lines = text.components(separatedBy: .newlines)
        let start = max(0, (lines.firstIndex { line in ["order", "receipt", "subtotal", "invoice"].contains { line.localizedCaseInsensitiveContains($0) } } ?? 0) - 2)
        let selected = lines.dropFirst(start).joined(separator: "\n")
        var result = ""
        for character in selected { if result.utf8.count + String(character).utf8.count > maximumBytes { break }; result.append(character) }
        return result
    }
}

public enum ReceiptMatch: Equatable, Sendable { case exact(String), suggestions([String]), none }
public enum ReceiptMatcher {
    public static func normalizeMerchant(_ text: String) -> String {
        text.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .components(separatedBy: CharacterSet.alphanumerics.inverted).filter { !$0.isEmpty }.joined(separator: " ")
    }
    public static func match(receipt: ReceiptValue, entries: [EntryValue], accounts: [AccountValue]) -> ReceiptMatch {
        guard let total = receipt.total, total > 0 else { return .none }
        let currencies = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0.currency) })
        let merchant = normalizeMerchant(receipt.merchant)
        let candidates = entries.filter { entry in
            let days = abs(Calendar.current.dateComponents([.day], from: Calendar.current.startOfDay(for: receipt.date), to: Calendar.current.startOfDay(for: entry.date)).day ?? 999)
            return entry.amount < 0 && !entry.isSplitParent && entry.parentID == nil && !entry.isPending && currencies[entry.accountID] == receipt.currency && days <= 3 && abs(-entry.amount - total) <= max(1, total / 50)
        }
        func merchantMatches(_ entry: EntryValue) -> Bool {
            let other = normalizeMerchant(entry.merchant)
            return merchant.count >= 3 && other.count >= 3 && (merchant == other || merchant.hasPrefix(other + " ") || other.hasPrefix(merchant + " "))
        }
        let exact = candidates.filter { -$0.amount == total && merchantMatches($0) }
        if exact.count == 1 && receipt.dateIsEstimated != true { return .exact(exact[0].id) }
        let ordered = candidates.sorted {
            let left = merchantMatches($0), right = merchantMatches($1)
            if left != right { return left }
            return abs($0.date.timeIntervalSince(receipt.date)) < abs($1.date.timeIntervalSince(receipt.date))
        }
        return ordered.isEmpty ? .none : .suggestions(Array(ordered.prefix(5).map(\.id)))
    }
}

public enum HSAExport {
    public static func receipts(_ receipts: [ReceiptValue], year: Int) -> [ReceiptValue] { receipts.filter { $0.hsaEligible && Calendar.current.component(.year, from: $0.date) == year }.sorted { $0.date < $1.date } }
    public static func unreimbursed(_ receipts: [ReceiptValue], year: Int? = nil, currency: String = "USD") -> Decimal {
        receipts.filter { $0.hsaEligible && $0.hsaStatus == .unreimbursed && $0.currency == currency && (year == nil || Calendar.current.component(.year, from: $0.date) == year) }.reduce(0) { $0 + ($1.total ?? 0) }
    }
    public static func csv(_ receipts: [ReceiptValue], year: Int) -> String {
        func cell(_ text: String) -> String {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let safe = trimmed.first.map { "=+-@".contains($0) } == true ? "'" + text : text
            return "\"" + safe.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        var rows = [["Receipt ID", "Date", "Merchant", "Order number", "Total", "Currency", "HSA status", "Reimbursed on", "Purchase transaction", "HSA withdrawal", "File count"]]
        rows += self.receipts(receipts, year: year).map { receipt in
            [receipt.id, LedgerDate.string(receipt.date), receipt.merchant, receipt.orderNumber, receipt.total.map { NSDecimalNumber(decimal: $0).stringValue } ?? "", receipt.currency, receipt.hsaStatus.rawValue, receipt.hsaReimbursedOn.map { LedgerDate.string($0) } ?? "", receipt.transactionID ?? "", receipt.hsaWithdrawalID ?? "", "\(receipt.files.count)"]
        }
        return rows.map { $0.map(cell).joined(separator: ",") }.joined(separator: "\r\n") + "\r\n"
    }
}
