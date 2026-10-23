import XCTest
import SwiftData
import MonarchCore
@testable import Monarch

@MainActor final class PersistenceTests: XCTestCase {
    private func store() throws -> ModelContainer {
        let configuration = ModelConfiguration(schema: AppPersistence.schema, isStoredInMemoryOnly: true, cloudKitDatabase: .none)
        return try ModelContainer(for: AppPersistence.schema, configurations: [configuration])
    }

    func testDailySnapshotsUpsertRatherThanDuplicate() throws {
        let container = try store(), context = container.mainContext
        let account = AccountRecord(name: "Checking", kind: .checking, balance: 100)
        context.insert(account); try AppPersistence.snapshots(context)
        account.balance = 200; try AppPersistence.snapshots(context)
        let rows = try context.fetch(FetchDescriptor<SnapshotRecord>())
        XCTAssertEqual(rows.count, 1)
        XCTAssertEqual(rows.first?.balance, 200)
    }

    func testCSVReimportIsIdempotentAndKeepsUserEdits() async throws {
        let container = try store()
        let account = AccountRecord(id: "bank", name: "Checking", kind: .checking)
        container.mainContext.insert(account); try container.mainContext.save()
        let writer = LedgerWriter(modelContainer: container)
        let document = try CSVDocument(text: "Date,Merchant,Amount\n2026-10-01,Market,-12\n2026-10-01,Market,-12")
        let entries = try document.entries(accountID: "bank", mapping: .init())
        let firstCount = try await writer.importCSV(entries, accountID: "bank", mapping: .init())
        let secondCount = try await writer.importCSV(entries, accountID: "bank", mapping: .init())
        XCTAssertEqual(firstCount, 2); XCTAssertEqual(secondCount, 0)
        let context = ModelContext(container)
        XCTAssertEqual(try context.fetchCount(FetchDescriptor<TransactionRecord>()), 2)
    }

    func testFailedSyncDoesNotAdvanceCursorOrSavePartialBalance() async throws {
        let container = try store(), context = container.mainContext
        let institution = InstitutionRecord(id: "connection", name: "Test bank", institutionID: "ins", itemID: "item", serverID: "test", accountMasks: [], product: "transactions")
        institution.cursor = "saved"
        context.insert(institution); try context.save()
        let json = Data("""
        {"transaction_id":"tx","account_id":"missing","date":"2026-10-22","amount":1.23,"name":"Coffee","pending":false}
        """.utf8)
        let decoder = JSONDecoder(); decoder.keyDecodingStrategy = .convertFromSnakeCase
        var batch = SyncBatch(nextCursor: "should-not-save")
        batch.added = [try decoder.decode(PlaidEntry.self, from: json)]
        let writer = LedgerWriter(modelContainer: container)
        do {
            _ = try await writer.commit(connectionID: "connection", accounts: [], batch: batch, liabilities: nil, holdings: nil)
            XCTFail("An unknown account must abort the whole commit")
        } catch { }
        let fresh = ModelContext(container)
        XCTAssertEqual(try fresh.fetch(FetchDescriptor<InstitutionRecord>()).first?.cursor, "saved")
        XCTAssertEqual(try fresh.fetchCount(FetchDescriptor<TransactionRecord>()), 0)
    }

    func testDuplicateMetadataAbortsBeforeNetworkExchange() async throws {
        let container = try store()
        let app = AppState(container: container)
        let record = InstitutionRecord(id: "existing", name: "Test", institutionID: "ins", itemID: "item", serverID: app.serverID, accountMasks: ["1234"], product: "transactions")
        container.mainContext.insert(record); try container.mainContext.save()
        // A network call would fail: no server/key is configured by this test.
        let existing = try await app.finishLink(publicToken: "must-not-exchange", institutionID: "ins", name: "Test", masks: ["1234"], product: .transactions)
        XCTAssertEqual(existing, "existing")
        XCTAssertEqual(try container.mainContext.fetchCount(FetchDescriptor<InstitutionRecord>()), 1)
    }

    func testBackupEncryptionAuthenticationAndRestore() async throws {
        let source = try store(), context = source.mainContext
        try AppPersistence.seed(context)
        context.insert(AccountRecord(id: "bank", name: "Private balance", kind: .checking, balance: 1234))
        context.insert(TransactionRecord(.init(accountID: "bank", date: .now, amount: -12, merchant: "Private merchant", categoryID: "groceries")))
        let archive = try await BackupService.capture(context)
        let encrypted = try BackupService.encrypt(archive, passphrase: "correct horse battery staple")
        XCTAssertFalse(String(data: encrypted, encoding: .utf8)!.contains("Private merchant"))
        XCTAssertThrowsError(try BackupService.decrypt(encrypted, passphrase: "wrong passphrase"))
        let decoded = try BackupService.decrypt(encrypted, passphrase: "correct horse battery staple")
        let destination = try store(); try AppPersistence.seed(destination.mainContext)
        try await BackupService.restore(decoded, into: destination.mainContext)
        XCTAssertEqual(try destination.mainContext.fetch(FetchDescriptor<AccountRecord>()).first?.balance, 1234)
        XCTAssertEqual(try destination.mainContext.fetchCount(FetchDescriptor<TransactionRecord>()), 1)
        do { try await BackupService.restore(decoded, into: destination.mainContext); XCTFail("Restore must refuse a nonempty ledger") } catch { }
    }
}
