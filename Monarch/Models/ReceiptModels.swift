import Foundation
import SwiftData
import MonarchCore

@Model final class ReceiptRecord {
    @Attribute(.unique) var id: String
    var merchant: String
    var date: Date
    var total: Decimal?
    var orderNumber: String
    var transactionID: String?
    var hsaEligible: Bool
    var hsaStatus: String
    var needsReview: Bool
    var payload: Data
    init(_ value: ReceiptValue) throws {
        id = value.id; merchant = value.merchant; date = value.date; total = value.total; orderNumber = value.orderNumber
        transactionID = value.transactionID; hsaEligible = value.hsaEligible; hsaStatus = value.hsaStatus.rawValue; needsReview = value.needsReview
        payload = try JSONEncoder().encode(value)
    }
    func decoded() throws -> ReceiptValue { try JSONDecoder().decode(ReceiptValue.self, from: payload) }
    var value: ReceiptValue { (try? decoded()) ?? ReceiptValue(id: id, source: .file, merchant: merchant, date: date, total: total, needsReview: true) }
    func apply(_ value: ReceiptValue) throws {
        payload = try JSONEncoder().encode(value)
        merchant = value.merchant; date = value.date; total = value.total; orderNumber = value.orderNumber
        transactionID = value.transactionID; hsaEligible = value.hsaEligible; hsaStatus = value.hsaStatus.rawValue; needsReview = value.needsReview
    }
}

@Model final class ShipmentRecord {
    @Attribute(.unique) var trackingNumber: String
    var receiptID: String
    var statusRaw: String
    var lastCheckedAt: Date?
    var deliveredAt: Date?
    var payload: Data
    init(_ value: ShipmentValue) throws {
        trackingNumber = value.trackingNumber; receiptID = value.receiptID; statusRaw = value.status.rawValue
        lastCheckedAt = value.lastCheckedAt; deliveredAt = value.deliveredAt; payload = try JSONEncoder().encode(value)
    }
    func decoded() throws -> ShipmentValue { try JSONDecoder().decode(ShipmentValue.self, from: payload) }
    var value: ShipmentValue { (try? decoded()) ?? ShipmentValue(trackingNumber: trackingNumber, carrier: .unknown, receiptID: receiptID) }
    func apply(_ value: ShipmentValue) throws {
        payload = try JSONEncoder().encode(value); receiptID = value.receiptID; statusRaw = value.status.rawValue
        lastCheckedAt = value.lastCheckedAt; deliveredAt = value.deliveredAt
    }
}

@Model final class EmailAccountRecord {
    @Attribute(.unique) var id: String
    var provider: String
    var address: String
    var host: String
    var username: String
    var mailbox: String
    var oauthClientID: String
    var historyID: String?
    var uidValidity: String?
    var lastUID: String?
    var lastScannedAt: Date?
    var status: String
    init(id: String = UUID().uuidString, provider: String, address: String, host: String = "", username: String = "", mailbox: String = "INBOX", oauthClientID: String = "") {
        self.id = id; self.provider = provider; self.address = address; self.host = host; self.username = username
        self.mailbox = mailbox; self.oauthClientID = oauthClientID; status = "Connected"
    }
}

/// Message IDs are retained even if an unrelated matching email has no receipt.
/// Checkpoints are committed only after every message in that batch is handled.
@Model final class ImportedMessageRecord {
    @Attribute(.unique) var id: String
    var accountID: String
    var messageID: String
    var receivedAt: Date
    init(accountID: String, messageID: String) { id = accountID + ":" + messageID; self.accountID = accountID; self.messageID = messageID; receivedAt = .now }
}
