import Foundation

public enum Money {
    public static func decimal(_ text: String) -> Decimal? {
        let cleaned = text.trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "$", with: "")
            .replacingOccurrences(of: ",", with: "")
        if cleaned.hasPrefix("("), cleaned.hasSuffix(")") {
            return Decimal(string: "-" + cleaned.dropFirst().dropLast(), locale: Locale(identifier: "en_US_POSIX"))
        }
        return Decimal(string: cleaned, locale: Locale(identifier: "en_US_POSIX"))
    }

    public static func rounded(_ value: Decimal) -> Decimal {
        var input = value
        var output = Decimal()
        NSDecimalRound(&output, &input, 2, .plain)
        return output
    }

    public static func double(_ value: Decimal) -> Double { NSDecimalNumber(decimal: value).doubleValue }

    public static func format(_ value: Decimal, currency: String = "USD") -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .currency
        formatter.currencyCode = currency
        return formatter.string(from: NSDecimalNumber(decimal: value)) ?? "\(value)"
    }
}

public enum LedgerDate {
    public static func parse(_ text: String, format: String = "yyyy-MM-dd") -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        formatter.isLenient = false
        return formatter.date(from: text)
    }

    public static func string(_ date: Date, format: String = "yyyy-MM-dd") -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.dateFormat = format
        return formatter.string(from: date)
    }

    public static func month(_ date: Date) -> String { string(date, format: "yyyy-MM") }
    public static func monthDate(_ month: String) -> Date { parse(month + "-01") ?? .distantPast }
    public static func shifting(_ date: Date, months: Int) -> Date {
        Calendar.current.date(byAdding: .month, value: months, to: date) ?? date
    }
}

public enum AccountKind: String, Codable, CaseIterable, Sendable {
    case checking, savings, credit, loan, investment, asset, other
    public var isLiability: Bool { self == .credit || self == .loan }
    public var title: String { rawValue.capitalized }
    public var symbol: String {
        switch self {
        case .checking: "building.columns"
        case .savings: "banknote"
        case .credit: "creditcard"
        case .loan: "graduationcap"
        case .investment: "chart.line.uptrend.xyaxis"
        case .asset: "house"
        case .other: "wallet.bifold"
        }
    }
}

public enum CategoryKind: String, Codable, CaseIterable, Sendable { case income, expense, transfer, reimbursement }
public enum BudgetBucket: String, Codable, CaseIterable, Sendable {
    case fixed, flex, nonMonthly
    public var title: String { self == .nonMonthly ? "Non-monthly" : rawValue.capitalized }
}

public struct CategoryValue: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var name: String
    public var emoji: String
    public var group: String
    public var kind: CategoryKind
    public var bucket: BudgetBucket
    public var order: Int
    public init(id: String, name: String, emoji: String, group: String, kind: CategoryKind = .expense, bucket: BudgetBucket = .flex, order: Int = 0) {
        self.id = id; self.name = name; self.emoji = emoji; self.group = group
        self.kind = kind; self.bucket = bucket; self.order = order
    }
    public static let defaults: [CategoryValue] = ([
        .init(id: "income", name: "Paychecks", emoji: "💵", group: "Income", kind: .income),
        .init(id: "other-income", name: "Other income", emoji: "✨", group: "Income", kind: .income),
        .init(id: "housing", name: "Housing", emoji: "🏡", group: "Home", bucket: .fixed),
        .init(id: "utilities", name: "Utilities", emoji: "💡", group: "Home", bucket: .fixed),
        .init(id: "subscriptions", name: "Subscriptions", emoji: "📺", group: "Lifestyle", bucket: .fixed),
        .init(id: "groceries", name: "Groceries", emoji: "🥑", group: "Food & dining"),
        .init(id: "dining", name: "Restaurants", emoji: "🍜", group: "Food & dining"),
        .init(id: "shopping", name: "Shopping", emoji: "🛍️", group: "Lifestyle"),
        .init(id: "transport", name: "Transport", emoji: "🚙", group: "Travel"),
        .init(id: "health", name: "Health", emoji: "🌿", group: "Wellbeing"),
        .init(id: "entertainment", name: "Entertainment", emoji: "🎟️", group: "Lifestyle"),
        .init(id: "travel", name: "Travel", emoji: "✈️", group: "Travel", bucket: .nonMonthly),
        .init(id: "insurance", name: "Insurance", emoji: "🛡️", group: "Home", bucket: .nonMonthly),
        .init(id: "uncategorized", name: "Uncategorized", emoji: "📦", group: "Other"),
        .init(id: "transfer", name: "Transfer", emoji: "↔️", group: "Transfers", kind: .transfer),
        .init(id: "loan-payment", name: "Loan payment", emoji: "🎓", group: "Transfers", kind: .transfer),
        .init(id: "reimbursement", name: "Reimbursement", emoji: "🤝", group: "Transfers", kind: .reimbursement)
    ] as [CategoryValue]).enumerated().map { index, value in var category = value; category.order = index; return category }
}

public struct AccountValue: Identifiable, Codable, Sendable {
    public var id: String
    public var name: String
    public var kind: AccountKind
    public var balance: Decimal
    public var currency: String
    public var hideFromBudget: Bool
    public var hideFromCashFlow: Bool
    public var hideFromNetWorth: Bool
    public var archived: Bool
    public init(id: String, name: String, kind: AccountKind, balance: Decimal, currency: String = "USD", hideFromBudget: Bool = false, hideFromCashFlow: Bool = false, hideFromNetWorth: Bool = false, archived: Bool = false) {
        self.id = id; self.name = name; self.kind = kind; self.balance = balance; self.currency = currency
        self.hideFromBudget = hideFromBudget; self.hideFromCashFlow = hideFromCashFlow
        self.hideFromNetWorth = hideFromNetWorth; self.archived = archived
    }
    public var netWorthBalance: Decimal { kind.isLiability ? -balance : balance }
}

public struct EntryValue: Identifiable, Codable, Sendable, Equatable {
    public var id: String
    public var accountID: String
    public var date: Date
    /// Negative is money out; positive is money in. All amounts are Decimal.
    public var amount: Decimal
    public var merchant: String
    public var originalDescription: String
    public var categoryID: String
    public var notes: String
    public var tags: [String]
    public var isPending: Bool
    public var isHidden: Bool
    public var isReviewed: Bool
    public var isSplitParent: Bool
    public var parentID: String?
    public var sourceID: String?
    public var importHash: String?
    public var lockedFields: Set<String>
    public var loanID: String?
    public var goalID: String?
    public init(id: String = UUID().uuidString, accountID: String, date: Date, amount: Decimal, merchant: String, originalDescription: String = "", categoryID: String = "uncategorized", notes: String = "", tags: [String] = [], isPending: Bool = false, isHidden: Bool = false, isReviewed: Bool = false, isSplitParent: Bool = false, parentID: String? = nil, sourceID: String? = nil, importHash: String? = nil, lockedFields: Set<String> = [], loanID: String? = nil, goalID: String? = nil) {
        self.id = id; self.accountID = accountID; self.date = date; self.amount = amount; self.merchant = merchant
        self.originalDescription = originalDescription; self.categoryID = categoryID; self.notes = notes; self.tags = tags
        self.isPending = isPending; self.isHidden = isHidden; self.isReviewed = isReviewed; self.isSplitParent = isSplitParent
        self.parentID = parentID; self.sourceID = sourceID; self.importHash = importHash; self.lockedFields = lockedFields
        self.loanID = loanID; self.goalID = goalID
    }
}

public enum ReceivableStatus: String, Codable, CaseIterable, Sendable { case open, requested, partial, paid, writtenOff }
public struct ReceivableValue: Identifiable, Codable, Sendable {
    public var id: String
    public var personID: String
    public var sourceEntryID: String?
    public var amount: Decimal
    public var amountPaid: Decimal
    public var note: String
    public var createdAt: Date
    public var requestedAt: Date?
    public var status: ReceivableStatus
    public var settlementIDs: [String]
    public init(id: String = UUID().uuidString, personID: String, sourceEntryID: String? = nil, amount: Decimal, amountPaid: Decimal = 0, note: String, createdAt: Date = .now, requestedAt: Date? = nil, status: ReceivableStatus = .open, settlementIDs: [String] = []) {
        self.id = id; self.personID = personID; self.sourceEntryID = sourceEntryID; self.amount = amount
        self.amountPaid = amountPaid; self.note = note; self.createdAt = createdAt; self.requestedAt = requestedAt
        self.status = status; self.settlementIDs = settlementIDs
    }
    public var remaining: Decimal { status == .writtenOff ? 0 : max(0, amount - amountPaid) }
}

public struct PersonValue: Identifiable, Codable, Sendable {
    public var id: String
    public var name: String
    public var aliases: [String]
    public var credit: Decimal
    public init(id: String = UUID().uuidString, name: String, aliases: [String] = [], credit: Decimal = 0) {
        self.id = id; self.name = name; self.aliases = aliases; self.credit = credit
    }
}

public struct BudgetLineValue: Identifiable, Codable, Sendable {
    public var id: String { categoryID }
    public var categoryID: String
    public var planned: Decimal
    public var rolloverEnabled: Bool
    public var startingBalance: Decimal
    public init(categoryID: String, planned: Decimal = 0, rolloverEnabled: Bool = false, startingBalance: Decimal = 0) {
        self.categoryID = categoryID; self.planned = planned; self.rolloverEnabled = rolloverEnabled; self.startingBalance = startingBalance
    }
}

public struct BudgetPlan: Codable, Sendable {
    public var month: String
    public var categoryMode: Bool
    public var flexPlanned: Decimal
    public var flexRolloverEnabled: Bool
    public var flexStartingBalance: Decimal
    public var lines: [BudgetLineValue]
    public init(month: String, categoryMode: Bool = false, flexPlanned: Decimal = 0, flexRolloverEnabled: Bool = false, flexStartingBalance: Decimal = 0, lines: [BudgetLineValue] = []) {
        self.month = month; self.categoryMode = categoryMode; self.flexPlanned = flexPlanned
        self.flexRolloverEnabled = flexRolloverEnabled; self.flexStartingBalance = flexStartingBalance; self.lines = lines
    }
}

public enum CategoryMapper {
    public static func category(primary: String?, detailed: String?, amount: Decimal) -> String {
        let detail = detailed ?? ""
        switch primary ?? "" {
        case "INCOME": return detail.contains("WAGES") ? "income" : "other-income"
        case "TRANSFER_IN", "TRANSFER_OUT": return "transfer"
        case "LOAN_PAYMENTS": return "loan-payment"
        case "FOOD_AND_DRINK": return detail.contains("GROCER") ? "groceries" : "dining"
        case "GENERAL_MERCHANDISE": return "shopping"
        case "TRANSPORTATION", "GAS_STATIONS": return "transport"
        case "RENT_AND_UTILITIES": return detail.contains("RENT") ? "housing" : "utilities"
        case "MEDICAL", "PERSONAL_CARE": return "health"
        case "ENTERTAINMENT": return "entertainment"
        case "TRAVEL": return "travel"
        default: return "uncategorized"
        }
    }
}
