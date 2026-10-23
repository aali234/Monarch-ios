import Foundation
import Testing
@testable import MonarchCore

private func date(_ value: String) -> Date { LedgerDate.parse(value)! }
private func entry(_ amount: Decimal, _ category: String = "groceries", day: String = "2026-10-15", id: String = UUID().uuidString) -> EntryValue {
    .init(id: id, accountID: "bank", date: date(day), amount: amount, merchant: "Market", categoryID: category)
}
private let bank = AccountValue(id: "bank", name: "Checking", kind: .checking, balance: 1200)

@Test func sharedChargesAndReimbursementsDoNotInflateSpendingOrIncome() throws {
    let charge = entry(-180, "utilities", id: "electric")
    let shared = ReceivableValue(personID: "dad", sourceEntryID: charge.id, amount: 180, note: "Electric")
    let rows = [charge, entry(180, "reimbursement"), entry(3000, "income"), entry(-500, "transfer")]
    let flow = LedgerMath.cashFlow(entries: rows, accounts: [bank], categories: CategoryValue.defaults, receivables: [shared], month: "2026-10")
    #expect(flow.income == 3000)
    #expect(flow.expenses == 0)
    var writtenOff = shared; writtenOff.status = .writtenOff
    #expect(LedgerMath.cashFlow(entries: rows, accounts: [bank], categories: CategoryValue.defaults, receivables: [writtenOff]).expenses == 180)
    writtenOff.amountPaid = 100
    #expect(LedgerMath.cashFlow(entries: rows, accounts: [bank], categories: CategoryValue.defaults, receivables: [writtenOff]).expenses == 80)
}

@Test func budgetCategoryCarryDoesNotDoubleCountFlexRollover() {
    let september = BudgetPlan(month: "2026-09", flexPlanned: 1000, flexRolloverEnabled: true, lines: [.init(categoryID: "groceries", planned: 300, rolloverEnabled: true, startingBalance: 50)])
    let october = BudgetPlan(month: "2026-10", flexPlanned: 1000, flexRolloverEnabled: true, lines: [.init(categoryID: "groceries", planned: 300, rolloverEnabled: true)])
    let result = LedgerMath.budget(plan: october, previousPlans: [september], entries: [entry(-200, day: "2026-09-10"), entry(-100)], accounts: [bank], categories: CategoryValue.defaults, receivables: [])
    #expect(result.rollover["groceries"] == 150)
    #expect(result.remaining["groceries"] == 350)
    #expect(result.flexRollover == 800)
    #expect(result.flexRemaining == 1700)
}

@Test func visibilityRefundsAndTransfers() {
    var hidden = bank; hidden.hideFromBudget = true
    let rows = [entry(-100), entry(20), entry(-1000, "transfer")]
    let plan = BudgetPlan(month: "2026-10", flexPlanned: 500)
    #expect(LedgerMath.cashFlow(entries: rows, accounts: [bank], categories: CategoryValue.defaults, receivables: []).expenses == 80)
    #expect(LedgerMath.budget(plan: plan, previousPlans: [], entries: rows, accounts: [hidden], categories: CategoryValue.defaults, receivables: []).flexActual == 0)
    #expect(LedgerMath.netWorth([bank, .init(id: "card", name: "Card", kind: .credit, balance: 200)]) == 1000)
    var foreign = bank; foreign.currency = "CAD"
    #expect(LedgerMath.cashFlow(entries: rows, accounts: [foreign], categories: CategoryValue.defaults, receivables: []).expenses == 0)
}

@Test func thousandCSVRowsParseWithinTheImportBudget() throws {
    let text = "Date,Merchant,Amount\n" + (0..<1000).map { "2026-10-01,Merchant \($0),-12.34" }.joined(separator: "\n")
    let start = Date.now
    let rows = try CSVDocument(text: text).entries(accountID: "bank", mapping: .init())
    #expect(rows.count == 1000)
    #expect(Date.now.timeIntervalSince(start) < 3)
}

@Test func rulesAreOrderedAndManualLocksWin() throws {
    var row = entry(-20); row.merchant = "COFFEE CO"; row.lockedFields = ["category"]
    let rules = [
        RuleValue(name: "First", order: 0, conditions: [.init(field: .merchant, value: "coffee")], actions: [.category("dining"), .merchant("Coffee"), .tag("work")]),
        RuleValue(name: "Second", order: 1, conditions: [.init(field: .merchant, operation: .equals, value: "Coffee")], actions: [.merchant("Morning coffee"), .review(true)])
    ]
    let result = try RuleEngine.apply(rules, to: row)
    #expect(result.entry.categoryID == "groceries")
    #expect(result.entry.merchant == "Morning coffee")
    #expect(result.entry.tags == ["work"])
    #expect(result.entry.isReviewed)
    #expect(result.matchedRuleIDs.count == 2)
}

@Test func splitRoundingBalancesAndRejectsInvalidSums() throws {
    let row = entry(Decimal(string: "-10.01")!)
    let split = try RuleEngine.split(entry: row, parts: [.init(categoryID: "groceries", amount: 50), .init(categoryID: "dining", amount: 50)], percentage: true)
    #expect(split.reduce(Decimal.zero) { $0 + $1.amount } == row.amount)
    #expect(split[0].sourceID == nil)
    #expect(throws: SplitError.self) { try RuleEngine.split(entry: row, parts: [.init(categoryID: "groceries", amount: 1)]) }
}

@Test func csvQuotedFieldsIdenticalChargesAndReimport() throws {
    let csv = try CSVDocument(text: "\u{FEFF}Date,Description,Amount\r\n2026-10-01,\"Market, Inc\",-12.50\r\n2026-10-01,\"Market, Inc\",-12.50\r\n2026-10-02,\"A \"\"quoted\"\"\nmerchant\",10\r\n")
    let first = try csv.entries(accountID: "bank", mapping: .init())
    let second = try csv.entries(accountID: "bank", mapping: .init())
    #expect(first.count == 3)
    #expect(first[0].merchant == "Market, Inc")
    #expect(first[2].merchant.contains("\"quoted\"\nmerchant"))
    #expect(first.map(\.importHash) == second.map(\.importHash))
    #expect(first[0].importHash != first[1].importHash)
    #expect(StableHash.sha256("abc") == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
}

@Test func badCSVRejectsEntireFile() throws {
    let csv = try CSVDocument(text: "Date,Description,Amount\n2026-10-01,Good,-10\nwrong,Bad,123")
    #expect(throws: CSVError.self) { try csv.entries(accountID: "bank", mapping: .init()) }
}

@Test func aliasMatchingIsCaseInsensitiveAndAmbiguityDoesNotSettle() throws {
    let person = PersonValue(id: "dad", name: "Dad", aliases: ["ZELLE FROM DAD"])
    let item = ReceivableValue(id: "electric", personID: person.id, amount: 180, note: "Electric")
    var incoming = entry(180); incoming.originalDescription = "zelle from dad payment"
    #expect(ReceivableEngine.exactMatch(entry: incoming, people: [person], receivables: [item]) == [item.id])
    let second = ReceivableValue(id: "other", personID: person.id, amount: 180, note: "Other")
    #expect(ReceivableEngine.exactMatch(entry: incoming, people: [person], receivables: [item, second]) == nil)
    let partial = try ReceivableEngine.payment(100, to: item)
    #expect(partial.status == .partial)
    #expect(partial.remaining == 80)
    #expect(try ReceivableEngine.payment(80, to: partial).status == .paid)
    #expect(throws: ReceivableError.self) { try ReceivableEngine.validate(amount: 190, charge: -180) }
}

@Test func duplicatesUseInstitutionAndOverlapAndHandleMissingMasks() {
    let existing = [ConnectionIdentity(id: "existing", institutionID: "ins", masks: ["1234", "5678"])]
    #expect(DuplicateGuard.existing(institutionID: "ins", masks: ["1234"], connections: existing) == "existing")
    #expect(DuplicateGuard.existing(institutionID: "ins", masks: [], connections: existing) == "existing")
    #expect(DuplicateGuard.existing(institutionID: "ins", masks: ["9999"], connections: existing) == nil)
    #expect(DuplicateGuard.existing(institutionID: "different", masks: ["1234"], connections: existing) == nil)
}

@Test func simpleDailyLoanInterestAndNonAmortizingLoan() {
    let zero = LoanMath.project(principal: 1200, apr: 0, monthlyPayment: 100)
    #expect(zero.months == 12 && zero.paysOff)
    let interestOnlyBalance = LoanMath.project(principal: 0, accruedInterest: 50, apr: 6, monthlyPayment: 50)
    #expect(interestOnlyBalance.months == 1 && interestOnlyBalance.paysOff)
    let regular = LoanMath.project(principal: 10000, apr: 6, monthlyPayment: 200, start: date("2026-10-01"))
    let faster = LoanMath.project(principal: 10000, apr: 6, monthlyPayment: 200, extra: 100, start: date("2026-10-01"))
    #expect(faster.months < regular.months)
    #expect(faster.totalInterest < regular.totalInterest)
    #expect(!LoanMath.project(principal: 10000, apr: 20, monthlyPayment: 1, maximumMonths: 12).paysOff)
}

@Test func missingDataHasNoHealthScoreAndForecastAppliesMilestoneOnce() {
    #expect(HealthEngine.score([]) == nil)
    let projection = ForecastEngine.project(startNetWorth: 1000, monthlyIncome: 100, monthlyExpenses: 50, investmentReturn: 0, inflation: 0, annualRaise: 0, months: 2, milestones: [.init(name: "Purchase", month: 1, oneTimeAmount: -200)])
    #expect(projection.last?.netWorth == 900)
}

@Test func recurringRequiresThreeConsistentOccurrences() {
    let rows = [entry(-10, day: "2026-08-01"), entry(-10, day: "2026-09-01"), entry(-10, day: "2026-10-01")]
    #expect(RecurringDetector.detect(rows, now: date("2026-10-22")).first?.frequency == "Monthly")
    #expect(RecurringDetector.detect(Array(rows.prefix(2))).isEmpty)
}
