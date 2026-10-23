import XCTest
import SwiftData
import MonarchCore
@testable import Monarch

@MainActor final class ReceiptPersistenceTests: XCTestCase {
    private func store() throws -> ModelContainer {
        try ModelContainer(for: AppPersistence.schema, configurations: [ModelConfiguration(schema: AppPersistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)])
    }
    func testEncryptedReceiptRetainsOriginalBytesAndOpaqueFileName() async throws {
        let previousKey = try SecureStore.data(for: ReceiptVault.keyName)
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory); if previousKey == nil { try? SecureStore.delete(ReceiptVault.keyName) } }
        let vault = ReceiptVault(localURL: directory, cloudEnabled: false)
        let original = Data("Medical receipt with private details".utf8)
        let file = try await vault.store(data: original, name: "private-pharmacy.txt", type: "public.plain-text", receiptID: "receipt", date: .now)
        XCTAssertTrue(file.encrypted)
        XCTAssertFalse(file.relativePath.contains("private-pharmacy"))
        let stored = try await vault.storedData(file)
        XCTAssertTrue(stored.starts(with: Data("MRCP1".utf8)))
        XCTAssertNotEqual(stored, original)
        let restored = try await vault.read(file)
        XCTAssertEqual(restored, original)
    }
    func testReceiptAndShipmentRoundTripKeepsLinksAndEligibility() throws {
        let container = try store(), context = container.mainContext
        let receipt = ReceiptValue(id: "receipt", source: .file, merchant: "Clinic", total: 100, hsaEligible: true, hsaStatus: .unreimbursed)
        context.insert(try ReceiptRecord(receipt))
        context.insert(try ShipmentRecord(.init(trackingNumber: "1Z999AA10123456784", carrier: .ups, receiptID: receipt.id)))
        try context.save()
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<ReceiptRecord>()).first?.decoded().hsaStatus, .unreimbursed)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<ShipmentRecord>()).first?.decoded().receiptID, receipt.id)
    }
    func testOldBackupJSONStillDecodesWithoutReceiptFields() async throws {
        let container = try store(); try AppPersistence.seed(container.mainContext)
        let archive = try await BackupService.capture(container.mainContext)
        var object = try JSONSerialization.jsonObject(with: JSONEncoder().encode(archive)) as! [String: Any]
        object["version"] = 1
        for key in ["receipts", "shipments", "emailAccounts", "receiptVaultKey", "receiptBlobs"] { object.removeValue(forKey: key) }
        let old = try JSONDecoder().decode(BackupArchive.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(old.version, 1); XCTAssertNil(old.receipts); XCTAssertNil(old.receiptVaultKey)
    }
    func testRemovedBankRowsClearLinksButPreserveHSAReimbursement() throws {
        let container = try store(), context = container.mainContext
        let reimbursedOn = LedgerDate.parse("2026-10-01")!
        let receipt = ReceiptValue(id: "receipt", source: .file, merchant: "Clinic", total: 100, transactionID: "removed-purchase", candidateTransactionIDs: ["removed-candidate"], hsaEligible: true, hsaStatus: .reimbursed, hsaReimbursedOn: reimbursedOn, hsaWithdrawalID: "removed-withdrawal", suppressAutoMatch: true)
        context.insert(try ReceiptRecord(receipt))
        context.insert(try ShipmentRecord(.init(trackingNumber: "1Z999AA10123456784", carrier: .ups, receiptID: receipt.id, transactionID: "removed-purchase")))
        try context.save()
        try ReceiptInbox(container: container).rematch()
        let restored = try XCTUnwrap(context.fetch(FetchDescriptor<ReceiptRecord>()).first).decoded()
        XCTAssertNil(restored.transactionID); XCTAssertNil(restored.hsaWithdrawalID)
        XCTAssertTrue(restored.candidateTransactionIDs.isEmpty); XCTAssertTrue(restored.suppressAutoMatch)
        XCTAssertEqual(restored.hsaStatus, .reimbursed); XCTAssertEqual(restored.hsaReimbursedOn, reimbursedOn)
        XCTAssertNil(try context.fetch(FetchDescriptor<ShipmentRecord>()).first?.decoded().transactionID)
    }
    func testAddingReceiptSchemaPreservesExistingAccount() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("ledger.store")
        let oldSchema = Schema([InstitutionRecord.self, AccountRecord.self, TransactionRecord.self, CategoryRecord.self, BudgetRecord.self, RuleRecord.self, PersonRecord.self, ReceivableRecord.self, SnapshotRecord.self, LoanRecord.self, HoldingRecord.self, RecurringRecord.self, ImportProfileRecord.self, PlanningRecord.self])
        try autoreleasepool {
            let original = try ModelContainer(for: oldSchema, configurations: [ModelConfiguration(schema: oldSchema, url: url, cloudKitDatabase: .none)])
            original.mainContext.insert(AccountRecord(id: "existing", name: "Existing bank", kind: .checking, balance: 321))
            try original.mainContext.save()
        }
        let upgraded = try ModelContainer(for: AppPersistence.schema, configurations: [ModelConfiguration(schema: AppPersistence.schema, url: url, cloudKitDatabase: .none)])
        XCTAssertEqual(try upgraded.mainContext.fetch(FetchDescriptor<AccountRecord>()).first?.balance, 321)
        XCTAssertEqual(try upgraded.mainContext.fetchCount(FetchDescriptor<ReceiptRecord>()), 0)
    }
}
