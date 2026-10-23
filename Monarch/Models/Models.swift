import Foundation
import SwiftData
import MonarchCore

@Model final class InstitutionRecord {
    @Attribute(.unique) var id: String
    var name: String
    var institutionID: String
    var itemID: String
    var serverID: String
    var accountMasks: [String]
    var product: String
    var cursor: String?
    var status: String
    var lastSyncedAt: Date?
    init(id: String = UUID().uuidString, name: String, institutionID: String, itemID: String, serverID: String, accountMasks: [String], product: String) {
        self.id = id; self.name = name; self.institutionID = institutionID; self.itemID = itemID; self.serverID = serverID
        self.accountMasks = accountMasks; self.product = product; self.status = "Connected"
    }
}

@Model final class AccountRecord {
    @Attribute(.unique) var id: String
    var name: String
    var kindRaw: String
    var balance: Decimal
    var currency: String
    var mask: String
    var institutionRecordID: String?
    var plaidAccountID: String?
    var source: String
    var hideFromBudget: Bool
    var hideFromCashFlow: Bool
    var hideFromNetWorth: Bool
    var isArchived: Bool
    var creditLimit: Decimal?
    init(id: String = UUID().uuidString, name: String, kind: AccountKind, balance: Decimal = 0, currency: String = "USD", source: String = "manual", mask: String = "", institutionRecordID: String? = nil, plaidAccountID: String? = nil) {
        self.id = id; self.name = name; self.kindRaw = kind.rawValue; self.balance = balance; self.currency = currency
        self.source = source; self.mask = mask; self.institutionRecordID = institutionRecordID; self.plaidAccountID = plaidAccountID
        self.hideFromBudget = false; self.hideFromCashFlow = false; self.hideFromNetWorth = false; self.isArchived = false
    }
    var kind: AccountKind { AccountKind(rawValue: kindRaw) ?? .other }
    var value: AccountValue { .init(id: id, name: name, kind: kind, balance: balance, currency: currency, hideFromBudget: hideFromBudget, hideFromCashFlow: hideFromCashFlow, hideFromNetWorth: hideFromNetWorth, archived: isArchived) }
}

@Model final class TransactionRecord {
    @Attribute(.unique) var id: String
    var accountID: String
    var date: Date
    var amount: Decimal
    var merchant: String
    var originalDescription: String
    var categoryID: String
    var notes: String
    var tags: [String]
    var isPending: Bool
    var isHidden: Bool
    var isReviewed: Bool
    var isSplitParent: Bool
    var parentID: String?
    var sourceID: String?
    var importHash: String?
    var lockedFields: [String]
    var loanID: String?
    var goalID: String?
    init(_ value: EntryValue) {
        id = value.id; accountID = value.accountID; date = value.date; amount = value.amount
        merchant = value.merchant; originalDescription = value.originalDescription; categoryID = value.categoryID
        notes = value.notes; tags = value.tags; isPending = value.isPending; isHidden = value.isHidden
        isReviewed = value.isReviewed; isSplitParent = value.isSplitParent; parentID = value.parentID
        sourceID = value.sourceID; importHash = value.importHash; lockedFields = Array(value.lockedFields)
        loanID = value.loanID; goalID = value.goalID
    }
    var value: EntryValue {
        .init(id: id, accountID: accountID, date: date, amount: amount, merchant: merchant, originalDescription: originalDescription, categoryID: categoryID, notes: notes, tags: tags, isPending: isPending, isHidden: isHidden, isReviewed: isReviewed, isSplitParent: isSplitParent, parentID: parentID, sourceID: sourceID, importHash: importHash, lockedFields: Set(lockedFields), loanID: loanID, goalID: goalID)
    }
    func apply(_ value: EntryValue) {
        accountID = value.accountID; date = value.date; amount = value.amount; merchant = value.merchant
        originalDescription = value.originalDescription; categoryID = value.categoryID; notes = value.notes; tags = value.tags
        isPending = value.isPending; isHidden = value.isHidden; isReviewed = value.isReviewed; isSplitParent = value.isSplitParent
        parentID = value.parentID; sourceID = value.sourceID; importHash = value.importHash
        lockedFields = Array(value.lockedFields); loanID = value.loanID; goalID = value.goalID
    }
    func lock(_ field: String) { if !lockedFields.contains(field) { lockedFields.append(field) } }
}

@Model final class CategoryRecord {
    @Attribute(.unique) var id: String
    var name: String
    var emoji: String
    var groupName: String
    var kindRaw: String
    var bucketRaw: String
    var order: Int
    init(_ value: CategoryValue) {
        id = value.id; name = value.name; emoji = value.emoji; groupName = value.group
        kindRaw = value.kind.rawValue; bucketRaw = value.bucket.rawValue; order = value.order
    }
    var value: CategoryValue { .init(id: id, name: name, emoji: emoji, group: groupName, kind: CategoryKind(rawValue: kindRaw) ?? .expense, bucket: BudgetBucket(rawValue: bucketRaw) ?? .flex, order: order) }
}

@Model final class BudgetRecord {
    @Attribute(.unique) var month: String
    var payload: Data
    init(_ value: BudgetPlan) throws { month = value.month; payload = try JSONEncoder().encode(value) }
    func decoded() throws -> BudgetPlan { try JSONDecoder().decode(BudgetPlan.self, from: payload) }
    func apply(_ value: BudgetPlan) throws { payload = try JSONEncoder().encode(value) }
}

@Model final class RuleRecord {
    @Attribute(.unique) var id: String
    var name: String
    var order: Int
    var enabled: Bool
    var payload: Data
    var matchCount: Int
    var lastAppliedAt: Date?
    init(_ value: RuleValue) throws {
        id = value.id; name = value.name; order = value.order; enabled = value.enabled
        payload = try JSONEncoder().encode(value); matchCount = 0
    }
    func decoded() throws -> RuleValue {
        var value = try JSONDecoder().decode(RuleValue.self, from: payload)
        value.order = order; value.enabled = enabled; value.name = name
        return value
    }
}

@Model final class PersonRecord {
    @Attribute(.unique) var id: String
    var name: String
    var aliases: [String]
    var credit: Decimal
    init(_ value: PersonValue) { id = value.id; name = value.name; aliases = value.aliases; credit = value.credit }
    var value: PersonValue { .init(id: id, name: name, aliases: aliases, credit: credit) }
}

@Model final class ReceivableRecord {
    @Attribute(.unique) var id: String
    var personID: String
    var sourceEntryID: String?
    var amount: Decimal
    var amountPaid: Decimal
    var note: String
    var createdAt: Date
    var requestedAt: Date?
    var statusRaw: String
    var settlementIDs: [String]
    init(_ value: ReceivableValue) {
        id = value.id; personID = value.personID; sourceEntryID = value.sourceEntryID; amount = value.amount
        amountPaid = value.amountPaid; note = value.note; createdAt = value.createdAt; requestedAt = value.requestedAt
        statusRaw = value.status.rawValue; settlementIDs = value.settlementIDs
    }
    var value: ReceivableValue { .init(id: id, personID: personID, sourceEntryID: sourceEntryID, amount: amount, amountPaid: amountPaid, note: note, createdAt: createdAt, requestedAt: requestedAt, status: ReceivableStatus(rawValue: statusRaw) ?? .open, settlementIDs: settlementIDs) }
    func apply(_ value: ReceivableValue) {
        amount = value.amount; amountPaid = value.amountPaid; note = value.note; requestedAt = value.requestedAt
        statusRaw = value.status.rawValue; settlementIDs = value.settlementIDs
    }
}

@Model final class SnapshotRecord {
    @Attribute(.unique) var id: String
    var accountID: String
    var date: Date
    var balance: Decimal
    init(accountID: String, date: Date, balance: Decimal) {
        self.id = "\(accountID)-\(LedgerDate.string(date))"; self.accountID = accountID
        self.date = Calendar.current.startOfDay(for: date); self.balance = balance
    }
}

@Model final class LoanRecord {
    @Attribute(.unique) var id: String
    var accountID: String
    var servicer: String
    var borrower: String
    var apr: Decimal
    var accruedInterest: Decimal
    var minimumPayment: Decimal
    var nextDue: Date?
    var lastReconciledAt: Date?
    var source: String
    init(id: String = UUID().uuidString, accountID: String, servicer: String, borrower: String = "Me", apr: Decimal = 0, minimumPayment: Decimal = 0, source: String = "manual") {
        self.id = id; self.accountID = accountID; self.servicer = servicer; self.borrower = borrower
        self.apr = apr; self.accruedInterest = 0; self.minimumPayment = minimumPayment; self.source = source
        self.lastReconciledAt = .now
    }
}

@Model final class HoldingRecord {
    @Attribute(.unique) var id: String
    var accountID: String
    var symbol: String
    var name: String
    var quantity: Decimal
    var price: Decimal
    var priceDate: String?
    var assetClass: String
    init(id: String, accountID: String, symbol: String, name: String, quantity: Decimal, price: Decimal, priceDate: String?, assetClass: String) {
        self.id = id; self.accountID = accountID; self.symbol = symbol; self.name = name
        self.quantity = quantity; self.price = price; self.priceDate = priceDate; self.assetClass = assetClass
    }
    var marketValue: Decimal { quantity * price }
}

@Model final class RecurringRecord {
    @Attribute(.unique) var merchantKey: String
    var status: String
    init(merchantKey: String, status: String) { self.merchantKey = merchantKey; self.status = status }
}

@Model final class ImportProfileRecord {
    @Attribute(.unique) var accountID: String
    var mappingData: Data
    init(accountID: String, mapping: CSVMapping) throws { self.accountID = accountID; mappingData = try JSONEncoder().encode(mapping) }
}

@Model final class PlanningRecord {
    @Attribute(.unique) var id: String
    var payload: Data
    init(id: String, payload: Data) { self.id = id; self.payload = payload }
}

enum AppPersistence {
    static let schema = Schema([
        InstitutionRecord.self, AccountRecord.self, TransactionRecord.self, CategoryRecord.self,
        BudgetRecord.self, RuleRecord.self, PersonRecord.self, ReceivableRecord.self,
        SnapshotRecord.self, LoanRecord.self, HoldingRecord.self, RecurringRecord.self, ImportProfileRecord.self, PlanningRecord.self,
        ReceiptRecord.self, ShipmentRecord.self, EmailAccountRecord.self, ImportedMessageRecord.self
    ])

    static func makeContainer() throws -> ModelContainer {
        let directory = URL.applicationSupportDirectory.appendingPathComponent("Monarch", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.protectionKey: FileProtectionType.complete])
        var protectedDirectory = directory
        var directoryValues = URLResourceValues(); directoryValues.isExcludedFromBackup = true
        try protectedDirectory.setResourceValues(directoryValues)
        // The ledger is local-only; CloudKit is explicitly disabled. The App Group
        // is used by the Share Extension inbox, not for cloud ledger sync.
        let config = ModelConfiguration("Monarch", schema: schema, url: directory.appendingPathComponent("ledger.store"), cloudKitDatabase: .none)
        let container = try ModelContainer(for: schema, configurations: [config])
        try protectStore(directory)
        return container
    }

    static func protectStore(_ directory: URL) throws {
        for file in try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil) {
            try FileManager.default.setAttributes([.protectionKey: FileProtectionType.complete], ofItemAtPath: file.path)
            var resource = file
            var values = URLResourceValues(); values.isExcludedFromBackup = true
            try resource.setResourceValues(values)
        }
    }

    @MainActor static func seed(_ context: ModelContext) throws {
        context.autosaveEnabled = false
        if try context.fetchCount(FetchDescriptor<CategoryRecord>()) == 0 {
            CategoryValue.defaults.forEach { context.insert(CategoryRecord($0)) }
        }
        try context.save()
        try snapshots(context)
    }

    static func snapshots(_ context: ModelContext) throws {
        let accounts = try context.fetch(FetchDescriptor<AccountRecord>())
        let existing = try context.fetch(FetchDescriptor<SnapshotRecord>())
        let day = LedgerDate.string(.now)
        let byID = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        for account in accounts where !account.isArchived {
            let id = "\(account.id)-\(day)"
            if let record = byID[id] { record.balance = account.balance }
            else { context.insert(SnapshotRecord(accountID: account.id, date: .now, balance: account.balance)) }
        }
        try context.save()
    }
}
