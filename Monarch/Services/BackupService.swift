import Foundation
import SwiftData
import CryptoKit
import CommonCrypto
import Security
import SwiftUI
import UniformTypeIdentifiers
import MonarchCore

extension UTType {
    static let monarchBackup = UTType(exportedAs: "app.monarch.encrypted-backup", conformingTo: .data)
}

struct EncryptedBackupFile: FileDocument {
    static var readableContentTypes: [UTType] { [.monarchBackup, .data] }
    var data: Data
    init(data: Data) { self.data = data }
    init(configuration: ReadConfiguration) throws {
        guard let data = configuration.file.regularFileContents, data.count <= 50 * 1024 * 1024 else { throw BackupFailure.invalidFile }
        self.data = data
    }
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper { FileWrapper(regularFileWithContents: data) }
}

enum BackupFailure: Error, LocalizedError {
    case shortPassphrase, invalidFile, wrongPassphrase, nonemptyStore, invalidReferences, keyDerivation
    var errorDescription: String? {
        switch self {
        case .shortPassphrase: "Use a passphrase of at least 12 characters. Keep it somewhere safe; it cannot be recovered."
        case .invalidFile: "This is not a supported Monarch backup."
        case .wrongPassphrase: "The passphrase is incorrect or the backup has been changed."
        case .nonemptyStore: "Restore into an empty app installation. Your current ledger has not been changed."
        case .invalidReferences: "The backup contains duplicate or incomplete records. Nothing was restored."
        case .keyDerivation: "The backup encryption key could not be created."
        }
    }
}

struct BackupArchive: Codable, Sendable {
    var version = 2
    var createdAt = Date.now
    var accounts: [AccountBackup]
    var entries: [EntryValue]
    var categories: [CategoryValue]
    var budgets: [BudgetPlan]
    var rules: [RuleValue]
    var people: [PersonValue]
    var receivables: [ReceivableValue]
    var connections: [ConnectionBackup]
    var snapshots: [SnapshotBackup]
    var loans: [LoanBackup]
    var holdings: [HoldingBackup]
    var recurring: [RecurringBackup]
    var importProfiles: [ProfileBackup]
    var planning: [PlanningBackup]
    var receipts: [ReceiptValue]? = nil
    var shipments: [ShipmentValue]? = nil
    var emailAccounts: [EmailAccountBackup]? = nil
    var receiptVaultKey: Data? = nil
    var receiptBlobs: [ReceiptBlobBackup]? = nil
}

struct ReceiptBlobBackup: Codable, Sendable { var fileID: String; var data: Data }
struct EmailAccountBackup: Codable, Sendable {
    var id: String; var provider: String; var address: String; var host: String; var username: String; var mailbox: String; var clientID: String
}

struct AccountBackup: Codable, Sendable {
    var value: AccountValue
    var mask: String
    var connectionID: String?
    var plaidAccountID: String?
    var source: String
    var creditLimit: Decimal?
}
struct ConnectionBackup: Codable, Sendable {
    var id: String; var name: String; var institutionID: String; var itemID: String; var serverID: String
    var masks: [String]; var product: String
}
struct SnapshotBackup: Codable, Sendable { var accountID: String; var date: Date; var balance: Decimal }
struct LoanBackup: Codable, Sendable {
    var id: String; var accountID: String; var servicer: String; var borrower: String; var apr: Decimal
    var accruedInterest: Decimal; var minimumPayment: Decimal; var nextDue: Date?; var reconciled: Date?; var source: String
}
struct HoldingBackup: Codable, Sendable {
    var id: String; var accountID: String; var symbol: String; var name: String; var quantity: Decimal
    var price: Decimal; var priceDate: String?; var assetClass: String
}
struct RecurringBackup: Codable, Sendable { var key: String; var status: String }
struct ProfileBackup: Codable, Sendable { var accountID: String; var mapping: Data }
struct PlanningBackup: Codable, Sendable { var id: String; var payload: Data }

enum BackupService {
    private struct Envelope: Codable {
        var version = 1
        var salt: Data
        var rounds: UInt32
        var ciphertext: Data
    }
    private static let aad = Data("MonarchBackup/v1".utf8)

    static func encrypt(_ archive: BackupArchive, passphrase: String) throws -> Data {
        guard passphrase.count >= 12 else { throw BackupFailure.shortPassphrase }
        var salt = Data(count: 32)
        let randomStatus = salt.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard randomStatus == errSecSuccess else { throw BackupFailure.keyDerivation }
        let rounds: UInt32 = 600_000
        let key = try derive(passphrase, salt: salt, rounds: rounds)
        let payload = try JSONEncoder().encode(archive)
        guard payload.count <= 36 * 1024 * 1024 else { throw ProxyError(errorCode: "BACKUP_TOO_LARGE", message: "This backup exceeds the 50 MB file limit. Export HSA receipt files separately and keep your originals in iCloud Drive.") }
        let sealed = try AES.GCM.seal(payload, using: key, authenticating: aad)
        guard let combined = sealed.combined else { throw BackupFailure.invalidFile }
        return try JSONEncoder().encode(Envelope(salt: salt, rounds: rounds, ciphertext: combined))
    }
    static func decrypt(_ data: Data, passphrase: String) throws -> BackupArchive {
        guard data.count <= 50 * 1024 * 1024 else { throw BackupFailure.invalidFile }
        let envelope = try JSONDecoder().decode(Envelope.self, from: data)
        guard envelope.version == 1, envelope.salt.count == 32, (100_000...2_000_000).contains(envelope.rounds) else { throw BackupFailure.invalidFile }
        let key = try derive(passphrase, salt: envelope.salt, rounds: envelope.rounds)
        let plaintext: Data
        do { plaintext = try AES.GCM.open(AES.GCM.SealedBox(combined: envelope.ciphertext), using: key, authenticating: aad) }
        catch { throw BackupFailure.wrongPassphrase }
        let archive = try JSONDecoder().decode(BackupArchive.self, from: plaintext)
        guard archive.version == 1 || archive.version == 2 else { throw BackupFailure.invalidFile }
        return archive
    }
    private static func derive(_ passphrase: String, salt: Data, rounds: UInt32) throws -> SymmetricKey {
        let password = Data(passphrase.utf8)
        guard !password.isEmpty else { throw BackupFailure.shortPassphrase }
        var output = Data(count: 32)
        let status = password.withUnsafeBytes { passwordBytes in
            salt.withUnsafeBytes { saltBytes in
                output.withUnsafeMutableBytes { outputBytes in
                    CCKeyDerivationPBKDF(CCPBKDFAlgorithm(kCCPBKDF2), passwordBytes.baseAddress!.assumingMemoryBound(to: Int8.self), password.count, saltBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), salt.count, CCPseudoRandomAlgorithm(kCCPRFHmacAlgSHA256), rounds, outputBytes.baseAddress!.assumingMemoryBound(to: UInt8.self), 32)
                }
            }
        }
        guard status == kCCSuccess else { throw BackupFailure.keyDerivation }
        return SymmetricKey(data: output)
    }

    @MainActor static func capture(_ context: ModelContext, includeReceiptFiles: Bool = true) async throws -> BackupArchive {
        try context.save()
        var archive = try BackupArchive(
            accounts: context.fetch(FetchDescriptor<AccountRecord>()).map { .init(value: $0.value, mask: $0.mask, connectionID: $0.institutionRecordID, plaidAccountID: $0.plaidAccountID, source: $0.source, creditLimit: $0.creditLimit) },
            entries: context.fetch(FetchDescriptor<TransactionRecord>()).map(\.value),
            categories: context.fetch(FetchDescriptor<CategoryRecord>()).map(\.value),
            budgets: context.fetch(FetchDescriptor<BudgetRecord>()).map { try $0.decoded() },
            rules: context.fetch(FetchDescriptor<RuleRecord>()).map { try $0.decoded() },
            people: context.fetch(FetchDescriptor<PersonRecord>()).map(\.value),
            receivables: context.fetch(FetchDescriptor<ReceivableRecord>()).map(\.value),
            connections: context.fetch(FetchDescriptor<InstitutionRecord>()).map { .init(id: $0.id, name: $0.name, institutionID: $0.institutionID, itemID: $0.itemID, serverID: $0.serverID, masks: $0.accountMasks, product: $0.product) },
            snapshots: context.fetch(FetchDescriptor<SnapshotRecord>()).map { .init(accountID: $0.accountID, date: $0.date, balance: $0.balance) },
            loans: context.fetch(FetchDescriptor<LoanRecord>()).map { .init(id: $0.id, accountID: $0.accountID, servicer: $0.servicer, borrower: $0.borrower, apr: $0.apr, accruedInterest: $0.accruedInterest, minimumPayment: $0.minimumPayment, nextDue: $0.nextDue, reconciled: $0.lastReconciledAt, source: $0.source) },
            holdings: context.fetch(FetchDescriptor<HoldingRecord>()).map { .init(id: $0.id, accountID: $0.accountID, symbol: $0.symbol, name: $0.name, quantity: $0.quantity, price: $0.price, priceDate: $0.priceDate, assetClass: $0.assetClass) },
            recurring: context.fetch(FetchDescriptor<RecurringRecord>()).map { .init(key: $0.merchantKey, status: $0.status) },
            importProfiles: context.fetch(FetchDescriptor<ImportProfileRecord>()).map { .init(accountID: $0.accountID, mapping: $0.mappingData) },
            planning: context.fetch(FetchDescriptor<PlanningRecord>()).map { .init(id: $0.id, payload: $0.payload) }
        )
        archive.receipts = try context.fetch(FetchDescriptor<ReceiptRecord>()).map { try $0.decoded() }
        archive.shipments = try context.fetch(FetchDescriptor<ShipmentRecord>()).map { try $0.decoded() }
        archive.emailAccounts = try context.fetch(FetchDescriptor<EmailAccountRecord>()).map { .init(id: $0.id, provider: $0.provider, address: $0.address, host: $0.host, username: $0.username, mailbox: $0.mailbox, clientID: $0.oauthClientID) }
        archive.receiptVaultKey = try SecureStore.data(for: ReceiptVault.keyName)
        let vault = ReceiptVault()
        var blobs: [ReceiptBlobBackup] = [], bytes = 0
        for file in archive.receipts?.flatMap(\.files) ?? [] {
            if !includeReceiptFiles { try await vault.verifyCloudUpload(file); continue }
            let content = try await vault.storedData(file); bytes += content.count
            guard bytes <= 25 * 1024 * 1024 else { throw ProxyError(errorCode: "BACKUP_TOO_LARGE", message: "Receipt originals exceed this backup’s 25 MB asset allowance. Export your HSA year separately; the receipt originals are retained.") }
            blobs.append(.init(fileID: file.id, data: content))
        }
        archive.receiptBlobs = includeReceiptFiles ? blobs : nil
        return archive
    }

    @MainActor static func restore(_ archive: BackupArchive, into context: ModelContext) async throws {
        guard try context.fetchCount(FetchDescriptor<AccountRecord>()) == 0,
              try context.fetchCount(FetchDescriptor<TransactionRecord>()) == 0,
              try context.fetchCount(FetchDescriptor<PersonRecord>()) == 0,
              try context.fetchCount(FetchDescriptor<InstitutionRecord>()) == 0,
              try context.fetchCount(FetchDescriptor<BudgetRecord>()) == 0,
              try context.fetchCount(FetchDescriptor<RuleRecord>()) == 0,
              try context.fetchCount(FetchDescriptor<ReceivableRecord>()) == 0,
              try context.fetchCount(FetchDescriptor<SnapshotRecord>()) == 0,
              try context.fetchCount(FetchDescriptor<LoanRecord>()) == 0,
              try context.fetchCount(FetchDescriptor<HoldingRecord>()) == 0,
              try context.fetchCount(FetchDescriptor<RecurringRecord>()) == 0,
              try context.fetchCount(FetchDescriptor<ImportProfileRecord>()) == 0,
              try context.fetchCount(FetchDescriptor<PlanningRecord>()) == 0,
              try context.fetchCount(FetchDescriptor<ReceiptRecord>()) == 0,
              try context.fetchCount(FetchDescriptor<ShipmentRecord>()) == 0,
              try context.fetchCount(FetchDescriptor<EmailAccountRecord>()) == 0 else { throw BackupFailure.nonemptyStore }
        try validate(archive)
        let previousVaultKey = try SecureStore.data(for: ReceiptVault.keyName)
        do {
            let categories = try context.fetch(FetchDescriptor<CategoryRecord>())
            // Commit only once, after every decoded row has been inserted.
            for value in archive.categories {
                if let existing = categories.first(where: { $0.id == value.id }) {
                    existing.name = value.name; existing.emoji = value.emoji; existing.groupName = value.group
                    existing.kindRaw = value.kind.rawValue; existing.bucketRaw = value.bucket.rawValue; existing.order = value.order
                } else { context.insert(CategoryRecord(value)) }
            }
            let restoredCategoryIDs = Set(archive.categories.map(\.id))
            categories.filter { !restoredCategoryIDs.contains($0.id) }.forEach { context.delete($0) }
            for item in archive.accounts {
                let value = item.value
                let record = AccountRecord(id: value.id, name: value.name, kind: value.kind, balance: value.balance, currency: value.currency, source: item.source, mask: item.mask, institutionRecordID: item.connectionID, plaidAccountID: item.plaidAccountID)
                record.hideFromBudget = value.hideFromBudget; record.hideFromCashFlow = value.hideFromCashFlow
                record.hideFromNetWorth = value.hideFromNetWorth; record.isArchived = value.archived; record.creditLimit = item.creditLimit
                context.insert(record)
            }
            archive.entries.forEach { context.insert(TransactionRecord($0)) }
            for value in archive.budgets { context.insert(try BudgetRecord(value)) }
            for value in archive.rules { context.insert(try RuleRecord(value)) }
            archive.people.forEach { context.insert(PersonRecord($0)) }
            archive.receivables.forEach { context.insert(ReceivableRecord($0)) }
            for item in archive.connections {
                let record = InstitutionRecord(id: item.id, name: item.name, institutionID: item.institutionID, itemID: item.itemID, serverID: item.serverID, accountMasks: item.masks, product: item.product)
                record.status = "Token needed on this device"; context.insert(record)
            }
            archive.snapshots.forEach { context.insert(SnapshotRecord(accountID: $0.accountID, date: $0.date, balance: $0.balance)) }
            for item in archive.loans {
                let record = LoanRecord(id: item.id, accountID: item.accountID, servicer: item.servicer, borrower: item.borrower, apr: item.apr, minimumPayment: item.minimumPayment, source: item.source)
                record.accruedInterest = item.accruedInterest; record.nextDue = item.nextDue; record.lastReconciledAt = item.reconciled
                context.insert(record)
            }
            archive.holdings.forEach { context.insert(HoldingRecord(id: $0.id, accountID: $0.accountID, symbol: $0.symbol, name: $0.name, quantity: $0.quantity, price: $0.price, priceDate: $0.priceDate, assetClass: $0.assetClass)) }
            archive.recurring.forEach { context.insert(RecurringRecord(merchantKey: $0.key, status: $0.status)) }
            for item in archive.importProfiles {
                let profile = try ImportProfileRecord(accountID: item.accountID, mapping: JSONDecoder().decode(CSVMapping.self, from: item.mapping))
                context.insert(profile)
            }
            archive.planning.forEach { context.insert(PlanningRecord(id: $0.id, payload: $0.payload)) }
            let files = Dictionary(uniqueKeysWithValues: (archive.receipts ?? []).flatMap(\.files).map { ($0.id, $0) })
            let vault = ReceiptVault()
            if let key = archive.receiptVaultKey { try SecureStore.setData(key, for: ReceiptVault.keyName) }
            for blob in archive.receiptBlobs ?? [] {
                guard let file = files[blob.fileID] else { throw BackupFailure.invalidReferences }
                try await vault.restoreStoredFile(file, data: blob.data)
            }
            for value in archive.receipts ?? [] { context.insert(try ReceiptRecord(value)) }
            for value in archive.shipments ?? [] { context.insert(try ShipmentRecord(value)) }
            for value in archive.emailAccounts ?? [] {
                let account = EmailAccountRecord(id: value.id, provider: value.provider, address: value.address, host: value.host, username: value.username, mailbox: value.mailbox, oauthClientID: value.clientID)
                account.status = "Reconnect email on this device"; context.insert(account)
            }
            try context.save()
        } catch {
            context.rollback()
            if let previousVaultKey { try? SecureStore.setData(previousVaultKey, for: ReceiptVault.keyName) }
            else { try? SecureStore.delete(ReceiptVault.keyName) }
            throw error
        }
    }

    private static func validate(_ archive: BackupArchive) throws {
        func unique(_ ids: [String]) -> Bool { ids.count == Set(ids).count }
        let accountIDs = Set(archive.accounts.map { $0.value.id }), entryIDs = Set(archive.entries.map(\.id)), personIDs = Set(archive.people.map(\.id)), categoryIDs = Set(archive.categories.map(\.id)), connectionIDs = Set(archive.connections.map(\.id))
        let receiptIDs = Set((archive.receipts ?? []).map(\.id)), receiptFiles = (archive.receipts ?? []).flatMap(\.files)
        guard unique((archive.receipts ?? []).map(\.id)), unique((archive.shipments ?? []).map(\.trackingNumber)), unique((archive.emailAccounts ?? []).map(\.id)), unique(receiptFiles.map(\.id)), unique((archive.receiptBlobs ?? []).map(\.fileID)),
              archive.receiptVaultKey == nil || archive.receiptVaultKey?.count == 32,
              !receiptFiles.contains(where: \.encrypted) || archive.receiptVaultKey != nil,
              (archive.receipts ?? []).allSatisfy({ ($0.transactionID == nil || entryIDs.contains($0.transactionID!)) && ($0.hsaWithdrawalID == nil || entryIDs.contains($0.hsaWithdrawalID!)) }),
              (archive.shipments ?? []).allSatisfy({ receiptIDs.contains($0.receiptID) && ($0.transactionID == nil || entryIDs.contains($0.transactionID!)) }),
              receiptFiles.allSatisfy({ !$0.relativePath.hasPrefix("/") && !$0.relativePath.components(separatedBy: "/").contains("..") && !$0.relativePath.contains("\\") }),
              (archive.receiptBlobs == nil ? receiptFiles.allSatisfy({ $0.location == "icloud" }) : Set((archive.receiptBlobs ?? []).map(\.fileID)) == Set(receiptFiles.map(\.id))) else { throw BackupFailure.invalidReferences }
        guard unique(archive.accounts.map { $0.value.id }), unique(archive.entries.map(\.id)), unique(archive.categories.map(\.id)),
              unique(archive.people.map(\.id)), unique(archive.receivables.map(\.id)), unique(archive.rules.map(\.id)), unique(archive.connections.map(\.id)),
              unique(archive.budgets.map(\.month)), unique(archive.loans.map(\.id)), unique(archive.holdings.map(\.id)),
              unique(archive.recurring.map(\.key)), unique(archive.importProfiles.map(\.accountID)), unique(archive.planning.map(\.id)),
              unique(archive.snapshots.map { $0.accountID + LedgerDate.string($0.date) }),
              archive.accounts.allSatisfy({ $0.connectionID == nil || connectionIDs.contains($0.connectionID!) }),
              archive.entries.allSatisfy({ accountIDs.contains($0.accountID) && categoryIDs.contains($0.categoryID) && ($0.parentID == nil || entryIDs.contains($0.parentID!)) }),
              archive.receivables.allSatisfy({ personIDs.contains($0.personID) && ($0.sourceEntryID == nil || entryIDs.contains($0.sourceEntryID!)) && $0.amount >= 0 && $0.amountPaid >= 0 && $0.amountPaid <= $0.amount }),
              archive.loans.allSatisfy({ accountIDs.contains($0.accountID) }), archive.holdings.allSatisfy({ accountIDs.contains($0.accountID) }),
              archive.snapshots.allSatisfy({ accountIDs.contains($0.accountID) }), archive.importProfiles.allSatisfy({ accountIDs.contains($0.accountID) }) else { throw BackupFailure.invalidReferences }
    }
}
