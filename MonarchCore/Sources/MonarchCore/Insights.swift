import Foundation

public struct RecurringCandidate: Identifiable, Sendable {
    public var id: String { merchant.lowercased() }
    public var merchant: String
    public var amount: Decimal
    public var frequency: String
    public var nextDate: Date
}

public enum RecurringDetector {
    public static func detect(_ entries: [EntryValue], now: Date = .now) -> [RecurringCandidate] {
        let cutoff = Calendar.current.date(byAdding: .day, value: -400, to: now) ?? now
        let groups = Dictionary(grouping: entries.filter { !$0.isPending && !$0.isSplitParent && !$0.isHidden && $0.date >= cutoff }, by: { $0.merchant.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) })
        let bands: [(String, ClosedRange<Int>, Int)] = [("Weekly",6...8,7),("Biweekly",13...16,14),("Monthly",27...33,30),("Quarterly",85...95,91),("Yearly",355...375,365)]
        return groups.values.compactMap { group in
            let rows = group.sorted { $0.date < $1.date }
            guard rows.count >= 3, let last = rows.last else { return nil }
            let gaps = zip(rows, rows.dropFirst()).map { Calendar.current.dateComponents([.day], from: $0.date, to: $1.date).day ?? 0 }
            let amounts = rows.map(\.amount).sorted()
            let median = amounts[amounts.count / 2]
            guard median != 0, rows.allSatisfy({ abs($0.amount - median) <= abs(median) / 10 }) else { return nil }
            guard let band = bands.first(where: { band in Double(gaps.filter(band.1.contains).count) / Double(gaps.count) >= 0.7 }) else { return nil }
            let next: Date
            if band.0 == "Monthly" { next = LedgerDate.shifting(last.date, months: 1) }
            else if band.0 == "Quarterly" { next = LedgerDate.shifting(last.date, months: 3) }
            else if band.0 == "Yearly" { next = LedgerDate.shifting(last.date, months: 12) }
            else { next = Calendar.current.date(byAdding: .day, value: band.2, to: last.date) ?? last.date }
            return RecurringCandidate(merchant: last.merchant, amount: median, frequency: band.0, nextDate: next)
        }.sorted { $0.nextDate < $1.nextDate }
    }
}

public struct HealthCheck: Identifiable, Sendable {
    public var id: String
    public var title: String
    public var detail: String
    /// pass = 1, warn = 0.5, fail = 0. Missing data creates no check.
    public var score: Decimal
    public var yearlyImpact: Decimal?
    public init(id: String, title: String, detail: String, score: Decimal, yearlyImpact: Decimal? = nil) {
        self.id = id; self.title = title; self.detail = detail; self.score = score; self.yearlyImpact = yearlyImpact
    }
}

public enum HealthEngine {
    public static func checks(flow: CashFlowResult, accounts: [AccountValue], receivables: [ReceivableValue], now: Date = .now) -> [HealthCheck] {
        var checks: [HealthCheck] = []
        if let rate = flow.savingsRate {
            checks.append(.init(id: "savings", title: "Save at least 10%", detail: "Your measured savings rate is \(NSDecimalNumber(decimal: Money.rounded(rate * 100)).stringValue)%.", score: rate >= Decimal(string: "0.1")! ? 1 : (rate > 0 ? Decimal(string: "0.5")! : 0), yearlyImpact: max(0, flow.income / 10 - flow.net) * 12))
        }
        if flow.income > 0 || flow.expenses > 0 {
            checks.append(.init(id: "cashflow", title: "Spend less than you earn", detail: "Monthly cash flow: \(Money.format(flow.net)).", score: flow.net >= 0 ? 1 : 0, yearlyImpact: max(0, -flow.net) * 12))
        }
        if flow.expenses > 0 {
            let savings = accounts.filter { $0.kind == .savings && !$0.archived }.reduce(Decimal.zero) { $0 + $1.balance }
            let months = savings / flow.expenses
            checks.append(.init(id: "emergency", title: "Build a cash cushion", detail: "Savings cover \(NSDecimalNumber(decimal: Money.rounded(months)).stringValue) months at your measured spending.", score: months >= 3 ? 1 : (months >= 1 ? Decimal(string: "0.5")! : 0)))
        }
        if !receivables.isEmpty {
            let cutoff = Calendar.current.date(byAdding: .day, value: -30, to: now) ?? now
            let overdue = receivables.filter { $0.remaining > 0 && ($0.requestedAt.map { $0 < cutoff } ?? false) }.reduce(Decimal.zero) { $0 + $1.remaining }
            checks.append(.init(id: "collect", title: "Follow up on shared costs", detail: overdue > 0 ? "\(Money.format(overdue)) was requested more than 30 days ago." : "No requests are more than 30 days overdue.", score: overdue > 0 ? 0 : 1))
        }
        return checks
    }
    public static func score(_ checks: [HealthCheck]) -> Int? {
        guard !checks.isEmpty else { return nil }
        return NSDecimalNumber(decimal: checks.reduce(0) { $0 + $1.score } / Decimal(checks.count) * 100).intValue
    }
}

public struct ForecastMilestone: Identifiable, Codable, Sendable {
    public var id: String
    public var name: String
    public var month: Int
    public var oneTimeAmount: Decimal
    public var monthlyIncomeChange: Decimal
    public var monthlyExpenseChange: Decimal
    public init(id: String = UUID().uuidString, name: String, month: Int, oneTimeAmount: Decimal = 0, monthlyIncomeChange: Decimal = 0, monthlyExpenseChange: Decimal = 0) {
        self.id = id; self.name = name; self.month = month; self.oneTimeAmount = oneTimeAmount
        self.monthlyIncomeChange = monthlyIncomeChange; self.monthlyExpenseChange = monthlyExpenseChange
    }
}
public struct ForecastPoint: Identifiable, Sendable {
    public var id: Int { month }
    public var month: Int
    public var netWorth: Decimal
    public var cashFlow: Decimal
}
public enum ForecastEngine {
    /// An aggregate planning estimate. Loan interest is supplied separately; principal payments are transfers.
    public static func project(startNetWorth: Decimal, monthlyIncome: Decimal, monthlyExpenses: Decimal, investmentBalance: Decimal = 0, investmentReturn: Decimal = 6, inflation: Decimal = 3, annualRaise: Decimal = 3, months: Int = 60, milestones: [ForecastMilestone] = []) -> [ForecastPoint] {
        var netWorth = startNetWorth, income = monthlyIncome, expenses = monthlyExpenses, investments = investmentBalance
        var result = [ForecastPoint(month: 0, netWorth: netWorth, cashFlow: income - expenses)]
        for month in 1...max(1, min(120, months)) {
            if month > 1, (month - 1) % 12 == 0 { income *= 1 + annualRaise / 100; expenses *= 1 + inflation / 100 }
            for event in milestones where event.month == month {
                netWorth += event.oneTimeAmount; income += event.monthlyIncomeChange; expenses += event.monthlyExpenseChange
            }
            let growth = investments * investmentReturn / 100 / 12
            investments += growth; netWorth += income - expenses + growth
            result.append(.init(month: month, netWorth: Money.rounded(netWorth), cashFlow: Money.rounded(income - expenses)))
        }
        return result
    }
}
