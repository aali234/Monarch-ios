import Foundation
import Testing
@testable import MonarchCore

@Test func receiptFallbackParsesEditableFactsAndDoesNotInventEligibility() throws {
    let parsed = ReceiptParser.parse("Merchant: Green Pharmacy\nOrder number: RX-12345\n2026-10-20\nBandages  12.00\nSubtotal: $12.00\nTax: $0.96\nTotal: $12.96")
    #expect(parsed.merchant == "Green Pharmacy")
    #expect(parsed.orderNumber == "RX-12345")
    #expect(parsed.total == Decimal(string: "12.96"))
    #expect(parsed.subtotal == 12 && parsed.tax == Decimal(string: "0.96"))
    #expect(parsed.lineItems.count == 1)
    #expect(ReceiptParser.suggestsHSA(parsed.merchant))
    #expect(!ReceiptValue(source: .scan, merchant: parsed.merchant).hsaEligible)
    #expect(ReceiptParser.parse("An unreadable photo").total == nil)
}

@Test func receiptMatchingAutoLinksOnlyUniqueExactPostedCharges() {
    let day = LedgerDate.parse("2026-10-20")!
    let receipt = ReceiptValue(source: .file, merchant: "Green Pharmacy", date: day, total: 100)
    let account = AccountValue(id: "card", name: "Card", kind: .credit, balance: 100)
    let exact = EntryValue(id: "one", accountID: "card", date: day, amount: -100, merchant: "GREEN PHARMACY")
    #expect(ReceiptMatcher.match(receipt: receipt, entries: [exact], accounts: [account]) == .exact("one"))
    var undated = receipt; undated.dateIsEstimated = true
    #expect(ReceiptMatcher.match(receipt: undated, entries: [exact], accounts: [account]) == .suggestions(["one"]))
    var duplicate = exact; duplicate.id = "two"
    #expect(ReceiptMatcher.match(receipt: receipt, entries: [exact, duplicate], accounts: [account]) == .suggestions(["one", "two"]))
    var pending = exact; pending.isPending = true
    #expect(ReceiptMatcher.match(receipt: receipt, entries: [pending], accounts: [account]) == .none)
    var near = exact; near.amount = -101
    #expect(ReceiptMatcher.match(receipt: receipt, entries: [near], accounts: [account]) == .suggestions(["one"]))
    near.date = Calendar.current.date(byAdding: .day, value: 4, to: day)!
    #expect(ReceiptMatcher.match(receipt: receipt, entries: [near], accounts: [account]) == .none)
    var foreign = account; foreign.currency = "CAD"
    #expect(ReceiptMatcher.match(receipt: receipt, entries: [exact], accounts: [foreign]) == .none)
}

@Test func hsaYearTotalsAndCSVExcludeIneligibleAndReimbursed() {
    let day = LedgerDate.parse("2026-10-20")!
    let eligible = ReceiptValue(source: .scan, merchant: "=HYPERLINK(\"unsafe\")", date: day, total: 30, hsaEligible: true, hsaStatus: .unreimbursed)
    var paid = eligible; paid.id = "paid"; paid.hsaStatus = .reimbursed
    var other = eligible; other.id = "other"; other.hsaEligible = false
    var older = eligible; older.id = "older"; older.date = LedgerDate.parse("2025-10-20")!
    #expect(HSAExport.unreimbursed([eligible, paid, other, older], year: 2026) == 30)
    #expect(HSAExport.unreimbursed([eligible, paid, other, older]) == 60)
    let csv = HSAExport.csv([eligible, paid, other, older], year: 2026)
    #expect(csv.contains("'=HYPERLINK"))
    #expect(!csv.contains("2025-10-20"))
    #expect(csv.components(separatedBy: "\r\n").count == 4)
}

@Test func trackingDetectionAndRefreshBoundaries() {
    let detected = TrackingDetector.detect("Shipped via UPS 1Z999AA10123456784. USPS 9400111899223856928499. FedEx tracking: 123456789012")
    #expect(detected.map(\.carrier) == [.ups, .usps, .fedex])
    #expect(TrackingDetector.safeURL("javascript:alert(1)") == nil)
    #expect(TrackingDetector.safeURL("https://user:pass@example.com") == nil)
    let now = Date.now
    var shipment = ShipmentValue(trackingNumber: "1Z999AA10123456784", carrier: .ups, receiptID: "receipt", lastCheckedAt: now)
    #expect(!shipment.canRefresh(now: now.addingTimeInterval(7199)))
    #expect(shipment.canRefresh(now: now.addingTimeInterval(7200)))
    shipment.status = .delivered; shipment.deliveredAt = now
    #expect(!shipment.isArchived(now: now.addingTimeInterval(7 * 86400 - 1)))
    #expect(shipment.isArchived(now: now.addingTimeInterval(7 * 86400)))
    #expect(TrackingDetector.status(from: "Not delivered, delivery failed") == .exception)
    #expect(TrackingDetector.status(from: "Your order shipped and will be delivered tomorrow") == .inTransit)
    #expect(TrackingDetector.status(from: "It is not out for delivery yet") == nil)
    #expect(TrackingDetector.detect("Order number: 123456789012").isEmpty)
    let amazon = TrackingDetector.detect("Your order shipped. https://www.amazon.com/progress-tracker/package?itemId=ABCD")
    #expect(amazon.count == 1 && amazon[0].carrier == .amazon)
    #expect(!ShipmentValue(trackingNumber: amazon[0].number, carrier: .amazon, receiptID: "receipt").canRefresh())
}

@Test func receiptModelInputIsBoundedByUTF8Bytes() {
    let bounded = ReceiptParser.boundedOrderText("Order receipt\n" + String(repeating: "🧾", count: 3000))
    #expect(bounded.utf8.count <= 2000)
    #expect(bounded.hasPrefix("Order receipt"))
}

@Test func htmlMIMEQuotedPrintableAndAttachmentsStayOnDevice() throws {
    let raw = """
    Subject: =?UTF-8?B?WW91ciByZWNlaXB0?=
    From: orders@example.com
    Message-ID: <one@example.com>
    Content-Type: multipart/mixed; boundary="receipt-boundary"

    --receipt-boundary
    Content-Type: text/html; charset=UTF-8
    Content-Transfer-Encoding: quoted-printable

    <script>ignore this</script><p>Merchant: Pharmacy</p><p>Total: $12.00</p><a href="https://www.ups.com/track?tracknum=3D1Z999AA10123456784">Track</a>
    --receipt-boundary
    Content-Type: application/pdf; name="receipt.pdf"
    Content-Disposition: attachment; filename="receipt.pdf"
    Content-Transfer-Encoding: base64

    JVBERi0xLjQ=
    --receipt-boundary--
    """
    let mail = try MIMEReader.parse(Data(raw.utf8))
    #expect(mail.subject == "Your receipt")
    #expect(!mail.plainText.contains("ignore this"))
    #expect(mail.plainText.contains("Total: $12.00"))
    #expect(mail.plainText.contains("tracknum=1Z999AA10123456784"))
    #expect(mail.attachments.count == 1)
    #expect(String(data: mail.attachments[0].data, encoding: .utf8) == "%PDF-1.4")
    #expect(MailText.matchesReceipt(subject: mail.subject, sender: mail.sender))
}

@Test func imapSyntaxProtectsCommandsAndPreservesLiteralLengths() throws {
    #expect(try IMAPSyntax.quote("a\"b\\c") == "\"a\\\"b\\\\c\"")
    #expect(throws: MailFailure.self) { try IMAPSyntax.quote("user\r\nLOGOUT") }
    #expect(IMAPSyntax.searchUIDs(["* SEARCH 12 9 101", "A1 OK done"]) == [9, 12, 101])
    #expect(IMAPSyntax.literalLength("* 1 FETCH (BODY[] {12345}") == 12345)
    #expect(IMAPSyntax.uidValidity(["* OK [UIDVALIDITY 123] UIDs valid"]) == "123")
    #expect(MailText.base64URL("aGVsbG8") == Data("hello".utf8))
}

@Test func zipExportHasValidCRCAndRejectsTraversal() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let source = directory.appendingPathComponent("source.txt"), archive = directory.appendingPathComponent("receipts.zip")
    try Data("123456789".utf8).write(to: source)
    try ZIPArchive.write([.init(name: "Receipts/summary.csv", url: source)], to: archive)
    let bytes = [UInt8](try Data(contentsOf: archive))
    #expect(Array(bytes[0..<4]) == [0x50, 0x4B, 0x03, 0x04])
    #expect(Array(bytes[14..<18]) == [0x26, 0x39, 0xF4, 0xCB])
    #expect(Array(bytes[(bytes.count - 22)..<(bytes.count - 18)]) == [0x50, 0x4B, 0x05, 0x06])
    #expect(throws: ZIPFailure.self) { try ZIPArchive.write([.init(name: "../escape", url: source)], to: archive) }
    if let path = ProcessInfo.processInfo.environment["MONARCH_ZIP_FIXTURE"] { try Data(contentsOf: archive).write(to: URL(fileURLWithPath: path)) }
}
