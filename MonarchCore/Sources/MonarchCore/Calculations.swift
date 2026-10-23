import Foundation

public struct CashFlowResult: Sendable {
    public var income: Decimal = 0
    public var expenses: Decimal = 0
    public var net: Decimal { income - expenses }
    public var savingsRate: Decimal? { income > 0 ? net / income : nil }
}

public struct BudgetResult: Sendable {
    public var actual: [String: Decimal] = [:]
    public var rollover: [String: Decimal] = [:]
    public var remaining: [String: Decimal] = [:]
    public var flexActual: Decimal = 0
    public var flexRollover: Decimal = 0
    public var flexRemaining: Decimal = 0
}

public enum LedgerMath {
    public static func personalOutflow(_ entry: EntryValue, receivables: [ReceivableValue]) -> Decimal {
        guard entry.amount < 0 else { return 0 }
        let shared = receivables.filter { $0.sourceEntryID == entry.id }.reduce(Decimal.zero) { $0 + ($1.status == .writtenOff ? $1.amountPaid : $1.amount) }
        return max(0, -entry.amount - shared)
    }

    public static func cashFlow(entries: [EntryValue], accounts: [AccountValue], categories: [CategoryValue], receivables: [ReceivableValue], month: String? = nil, currency: String = "USD") -> CashFlowResult {
        let accountMap = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let categoryMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        var result = CashFlowResult()
        for entry in entries where !entry.isHidden && !entry.isPending && !entry.isSplitParent {
            guard let account = accountMap[entry.accountID], !account.hideFromCashFlow, account.currency == currency,
                  month == nil || LedgerDate.month(entry.date) == month else { continue }
            switch categoryMap[entry.categoryID]?.kind {
            case .income: result.income += entry.amount
            case .expense:
                // Refunds reduce spending; reimbursements have their own excluded kind.
                result.expenses += entry.amount < 0 ? personalOutflow(entry, receivables: receivables) : -entry.amount
            default: break
            }
        }
        return result
    }

    public static func budget(plan: BudgetPlan, previousPlans: [BudgetPlan], entries: [EntryValue], accounts: [AccountValue], categories: [CategoryValue], receivables: [ReceivableValue], currency: String = "USD") -> BudgetResult {
        let accountMap = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let categoryMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        var monthlyActuals: [String: [String: Decimal]] = [:]
        for entry in entries where !entry.isHidden && !entry.isPending && !entry.isSplitParent {
            guard let account = accountMap[entry.accountID], !account.hideFromBudget, account.currency == currency,
                  categoryMap[entry.categoryID]?.kind == .expense else { continue }
            monthlyActuals[LedgerDate.month(entry.date), default: [:]][entry.categoryID, default: 0] += entry.amount < 0 ? personalOutflow(entry, receivables: receivables) : -entry.amount
        }
        let plans = previousPlans.filter { $0.month < plan.month }.sorted { $0.month < $1.month } + [plan]
        var previous: BudgetResult?
        var previousMonth: String?
        var seenCategories = Set<String>()
        var result = BudgetResult()
        for current in plans {
            result = BudgetResult()
            result.actual = monthlyActuals[current.month] ?? [:]
            let expectedPrevious = LedgerDate.month(LedgerDate.shifting(LedgerDate.monthDate(current.month), months: -1))
            for line in current.lines {
                let carry: Decimal
                if !line.rolloverEnabled { carry = 0 }
                else if previousMonth == expectedPrevious, let value = previous?.remaining[line.categoryID] { carry = value }
                else { carry = seenCategories.contains(line.categoryID) ? 0 : line.startingBalance }
                result.rollover[line.categoryID] = carry
                result.remaining[line.categoryID] = carry + line.planned - (result.actual[line.categoryID] ?? 0)
                seenCategories.insert(line.categoryID)
            }
            result.flexActual = categories.filter { $0.kind == .expense && $0.bucket == .flex }.reduce(0) { $0 + (result.actual[$1.id] ?? 0) }
            result.flexRollover = current.flexRolloverEnabled ? (previousMonth == expectedPrevious ? previous?.flexRemaining ?? current.flexStartingBalance : (previous == nil ? current.flexStartingBalance : 0)) : 0
            result.flexRemaining = current.flexPlanned + result.flexRollover - result.flexActual
            previous = result; previousMonth = current.month
        }
        return result
    }

    public static func netWorth(_ accounts: [AccountValue], currency: String = "USD") -> Decimal {
        accounts.filter { !$0.hideFromNetWorth && !$0.archived && $0.currency == currency }.reduce(0) { $0 + $1.netWorthBalance }
    }
}

public enum ReceivableError: Error, LocalizedError {
    case invalidAmount, exceedsCharge, invalidPayment
    public var errorDescription: String? {
        switch self {
        case .invalidAmount: "Enter an amount greater than zero."
        case .exceedsCharge: "The total owed cannot exceed the original charge."
        case .invalidPayment: "The payment must be positive and no more than the remaining balance."
        }
    }
}

public enum ReceivableEngine {
    public static func validate(amount: Decimal, charge: Decimal?, existing: Decimal = 0) throws {
        guard amount > 0 else { throw ReceivableError.invalidAmount }
        if let charge, amount + existing > abs(charge) { throw ReceivableError.exceedsCharge }
    }

    public static func payment(_ amount: Decimal, to receivable: ReceivableValue, settlementID: String? = nil) throws -> ReceivableValue {
        guard amount > 0, amount <= receivable.remaining else { throw ReceivableError.invalidPayment }
        var result = receivable
        result.amountPaid += amount
        result.status = result.remaining == 0 ? .paid : .partial
        if let settlementID { result.settlementIDs.append(settlementID) }
        return result
    }

    /// Only exact, unambiguous matches auto-settle; partial or ambiguous deposits need review.
    public static func exactMatch(entry: EntryValue, people: [PersonValue], receivables: [ReceivableValue]) -> [String]? {
        guard entry.amount > 0 else { return nil }
        let matches = people.filter { person in
            person.aliases.contains { !$0.isEmpty && entry.originalDescription.localizedCaseInsensitiveContains($0) }
        }
        guard matches.count == 1, let person = matches.first else { return nil }
        let open = receivables.filter { $0.personID == person.id && $0.remaining > 0 }.sorted { $0.createdAt < $1.createdAt }
        let single = open.filter { $0.remaining == entry.amount }
        if single.count == 1 { return [single[0].id] }
        if single.count > 1 { return nil }
        var sum: Decimal = 0
        var ids: [String] = []
        for item in open {
            sum += item.remaining; ids.append(item.id)
            if sum == entry.amount { return ids }
            if sum > entry.amount { break }
        }
        return nil
    }

    public static func requestMessage(person: String, items: [ReceivableValue]) -> String {
        let total = items.reduce(Decimal.zero) { $0 + $1.remaining }
        return "Hi \(person)! Could you send \(Money.format(total)) when you get a chance?\n" + items.filter { $0.remaining > 0 }.map { "• \($0.note): \(Money.format($0.remaining))" }.joined(separator: "\n") + "\nThank you!"
    }
}

public struct LoanProjection: Sendable {
    public var months: Int
    public var totalInterest: Decimal
    public var remainingPrincipal: Decimal
    public var paysOff: Bool { remainingPrincipal <= 0 }
}

public enum LoanMath {
    /// Daily simple interest, paid before principal. Uses actual calendar days per payment interval.
    public static func project(principal: Decimal, accruedInterest: Decimal = 0, apr: Decimal, monthlyPayment: Decimal, extra: Decimal = 0, start: Date = .now, maximumMonths: Int = 600) -> LoanProjection {
        var balance = principal
        var unpaidInterest = accruedInterest
        var interestTotal = accruedInterest
        var last = start
        guard principal >= 0, accruedInterest >= 0, principal + accruedInterest > 0, monthlyPayment + extra > 0, apr >= 0 else {
            return .init(months: 0, totalInterest: accruedInterest, remainingPrincipal: max(0, principal + accruedInterest))
        }
        var count = 0
        while balance + unpaidInterest > 0, count < maximumMonths {
            let next = LedgerDate.shifting(start, months: count + 1)
            let days = max(1, Calendar.current.dateComponents([.day], from: last, to: next).day ?? 30)
            let interest = balance * apr / 100 / 365 * Decimal(days)
            interestTotal += interest; unpaidInterest += interest
            let payment = min(balance + unpaidInterest, monthlyPayment + extra)
            let interestPayment = min(unpaidInterest, payment)
            unpaidInterest -= interestPayment
            balance = max(0, balance - (payment - interestPayment))
            count += 1; last = next
        }
        return .init(months: count, totalInterest: Money.rounded(interestTotal), remainingPrincipal: balance + unpaidInterest)
    }
}
