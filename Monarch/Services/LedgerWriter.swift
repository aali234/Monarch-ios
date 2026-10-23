import Foundation
import SwiftData
import MonarchCore

struct SyncOutcome: Sendable {
    var changed: Int
    var preparing: Bool
}

@ModelActor actor LedgerWriter {
    func savedCursor(connectionID: String) throws -> String? {
        try connection(connectionID).cursor
    }

    private func connection(_ id: String) throws -> InstitutionRecord {
        let records = try modelContext.fetch(FetchDescriptor<InstitutionRecord>())
        guard let record = records.first(where: { $0.id == id }) else { throw ProxyError(errorCode: "CONNECTION_MISSING") }
        return record
    }

    func markStatus(connectionID: String, status: String) throws {
        try connection(connectionID).status = status
        try modelContext.save()
    }

    func commit(connectionID: String, accounts remoteAccounts: [PlaidAccount], batch: SyncBatch?, liabilities: LiabilityResponse?, holdings: HoldingsResponse?) throws -> SyncOutcome {
        modelContext.autosaveEnabled = false
        do {
            let institution = try connection(connectionID)
            var localAccounts = try modelContext.fetch(FetchDescriptor<AccountRecord>()).filter { $0.institutionRecordID == connectionID }
            var accountIDs: [String: String] = [:]
            let remoteIDs = Set(remoteAccounts.map(\.accountId))
            for remote in remoteAccounts {
                let record: AccountRecord
                if let existing = localAccounts.first(where: { $0.plaidAccountID == remote.accountId }) { record = existing }
                else {
                    record = AccountRecord(name: remote.name, kind: remote.kind, source: "plaid", mask: remote.mask ?? "", institutionRecordID: connectionID, plaidAccountID: remote.accountId)
                    modelContext.insert(record); localAccounts.append(record)
                }
                record.balance = remote.balances.current ?? remote.balances.available ?? record.balance
                record.currency = remote.balances.isoCurrencyCode ?? remote.balances.unofficialCurrencyCode ?? "USD"
                record.creditLimit = remote.balances.limit
                record.mask = remote.mask ?? ""; record.isArchived = false
                accountIDs[remote.accountId] = record.id
            }
            for old in localAccounts where old.plaidAccountID.map({ !remoteIDs.contains($0) }) ?? false { old.isArchived = true }
            institution.accountMasks = remoteAccounts.compactMap(\.mask)
            var changed = 0
            if let batch {
                let localIDs = Set(localAccounts.map(\.id))
                let stored = try modelContext.fetch(FetchDescriptor<TransactionRecord>()).filter { localIDs.contains($0.accountID) }
                let existingMap = Dictionary(uniqueKeysWithValues: stored.map { ($0.id, $0) })
                var merged = try SyncMerger.merge(existing: stored.map(\.value), batch: batch, accountIDs: accountIDs)
                let ruleRecords = try modelContext.fetch(FetchDescriptor<RuleRecord>())
                let rules = try ruleRecords.map { try $0.decoded() }
                let touched = Set((batch.added + batch.modified).map(\.transactionId))
                var receivables = try modelContext.fetch(FetchDescriptor<ReceivableRecord>())
                var newChildren: [EntryValue] = []
                for index in merged.indices where merged[index].sourceID.map(touched.contains) ?? false {
                    let result = try RuleEngine.apply(rules, to: merged[index])
                    merged[index] = result.entry; newChildren += result.children
                    for item in result.receivables where !receivables.contains(where: { $0.id == item.id }) {
                        let record = ReceivableRecord(item); modelContext.insert(record); receivables.append(record)
                    }
                    for id in result.matchedRuleIDs {
                        if let record = ruleRecords.first(where: { $0.id == id }) { record.matchCount += 1; record.lastAppliedAt = .now }
                    }
                    let shared = receivables.filter { $0.sourceEntryID == merged[index].id }.reduce(Decimal.zero) { $0 + ($1.statusRaw == "writtenOff" ? $1.amountPaid : $1.amount) }
                    guard shared <= abs(merged[index].amount) else { throw ReceivableError.exceedsCharge }
                }
                for child in newChildren {
                    merged.removeAll { $0.id == child.id }; merged.append(child)
                }
                let people = try modelContext.fetch(FetchDescriptor<PersonRecord>()).map(\.value)
                let settled = Set(receivables.flatMap(\.settlementIDs))
                for index in merged.indices where merged[index].amount > 0 && !merged[index].isPending && !settled.contains(merged[index].id) && !merged[index].lockedFields.contains("category") {
                    if let ids = ReceivableEngine.exactMatch(entry: merged[index], people: people, receivables: receivables.map(\.value)) {
                        for id in ids {
                            if let record = receivables.first(where: { $0.id == id }) {
                                record.apply(try ReceivableEngine.payment(record.value.remaining, to: record.value, settlementID: merged[index].id))
                            }
                        }
                        merged[index].categoryID = "reimbursement"
                        merged[index].lockedFields.insert("category")
                    }
                }
                let mergedIDs = Set(merged.map(\.id))
                for old in stored where !mergedIDs.contains(old.id) {
                    for shared in receivables where shared.sourceEntryID == old.id {
                        shared.sourceEntryID = nil
                        shared.note = "Source removed · " + shared.note
                    }
                    modelContext.delete(old)
                }
                for entry in merged {
                    if let record = existingMap[entry.id] { if record.value != entry { record.apply(entry); changed += 1 } }
                    else { modelContext.insert(TransactionRecord(entry)); changed += 1 }
                }
                // The cursor and transaction changes are saved by one SwiftData commit below.
                institution.cursor = batch.nextCursor
            }
            if let liabilities {
                let loans = try modelContext.fetch(FetchDescriptor<LoanRecord>())
                for student in liabilities.student {
                    guard let accountID = accountIDs[student.accountId] else { continue }
                    let loan = loans.first(where: { $0.accountID == accountID }) ?? LoanRecord(accountID: accountID, servicer: student.loanName ?? institution.name, source: "plaid")
                    if loan.modelContext == nil { modelContext.insert(loan) }
                    loan.apr = student.interestRatePercentage ?? loan.apr
                    loan.minimumPayment = student.minimumPaymentAmount ?? loan.minimumPayment
                    loan.accruedInterest = student.outstandingInterestAmount ?? 0
                    loan.nextDue = student.nextPaymentDueDate.flatMap { LedgerDate.parse($0) }
                    loan.lastReconciledAt = .now
                }
            }
            if let holdings {
                let ids = Set(localAccounts.map(\.id))
                let old = try modelContext.fetch(FetchDescriptor<HoldingRecord>()).filter { ids.contains($0.accountID) }
                old.forEach { modelContext.delete($0) }
                for holding in holdings.holdings {
                    guard let accountID = accountIDs[holding.accountId] else { continue }
                    let security = holdings.securities.first { $0.securityId == holding.securityId }
                    modelContext.insert(HoldingRecord(id: "\(accountID)-\(holding.securityId)", accountID: accountID, symbol: security?.tickerSymbol ?? "—", name: security?.name ?? "Holding", quantity: holding.quantity, price: security?.closePrice ?? holding.institutionPrice, priceDate: security?.closePriceAsOf ?? holding.institutionPriceAsOf, assetClass: security?.type ?? "Other"))
                }
            }
            institution.lastSyncedAt = .now
            let preparing = batch?.updateStatus == "NOT_READY" || batch?.updateStatus == "INITIAL_UPDATE_IN_PROGRESS"
            institution.status = preparing ? "Preparing history" : "Connected"
            try AppPersistence.snapshots(modelContext) // saves entries + cursor + balances + snapshots atomically
            return .init(changed: changed, preparing: preparing)
        } catch {
            modelContext.rollback()
            throw error
        }
    }

    func importCSV(_ entries: [EntryValue], accountID: String, mapping: CSVMapping) throws -> Int {
        modelContext.autosaveEnabled = false
        do {
            let existing = try modelContext.fetch(FetchDescriptor<TransactionRecord>())
            let hashes = Set(existing.compactMap(\.importHash))
            let rules = try modelContext.fetch(FetchDescriptor<RuleRecord>()).map { try $0.decoded() }
            var count = 0
            for var entry in entries where entry.importHash.map({ !hashes.contains($0) }) ?? true {
                if let previous = existing.first(where: { $0.merchant.caseInsensitiveCompare(entry.merchant) == .orderedSame }) { entry.categoryID = previous.categoryID }
                let result = try RuleEngine.apply(rules, to: entry)
                modelContext.insert(TransactionRecord(result.entry))
                result.children.forEach { modelContext.insert(TransactionRecord($0)) }
                result.receivables.forEach { modelContext.insert(ReceivableRecord($0)) }
                count += 1
            }
            let profiles = try modelContext.fetch(FetchDescriptor<ImportProfileRecord>())
            if let profile = profiles.first(where: { $0.accountID == accountID }) { profile.mappingData = try JSONEncoder().encode(mapping) }
            else { modelContext.insert(try ImportProfileRecord(accountID: accountID, mapping: mapping)) }
            try modelContext.save()
            return count
        } catch { modelContext.rollback(); throw error }
    }
}
