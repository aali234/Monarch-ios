import Foundation

public enum RuleField: String, Codable, CaseIterable, Sendable { case merchant, description, amount, direction, account, category }
public enum RuleOperator: String, Codable, CaseIterable, Sendable { case contains, equals, regex, between, greaterThan }
public struct RuleCondition: Codable, Sendable {
    public var field: RuleField
    public var operation: RuleOperator
    public var value: String
    public var secondValue: String?
    public init(field: RuleField, operation: RuleOperator = .contains, value: String, secondValue: String? = nil) {
        self.field = field; self.operation = operation; self.value = value; self.secondValue = secondValue
    }
}
public struct SplitPart: Codable, Sendable {
    public var categoryID: String
    public var amount: Decimal
    public init(categoryID: String, amount: Decimal) { self.categoryID = categoryID; self.amount = amount }
}
public enum RuleAction: Codable, Sendable {
    case category(String), merchant(String), tag(String), hide(Bool), review(Bool)
    case split([SplitPart], percentage: Bool)
    case loan(String), goal(String), shared(personID: String, percentage: Decimal)
}
public struct RuleValue: Identifiable, Codable, Sendable {
    public var id: String
    public var name: String
    public var order: Int
    public var enabled: Bool
    public var conditions: [RuleCondition]
    public var actions: [RuleAction]
    public init(id: String = UUID().uuidString, name: String, order: Int = 0, enabled: Bool = true, conditions: [RuleCondition], actions: [RuleAction]) {
        self.id = id; self.name = name; self.order = order; self.enabled = enabled; self.conditions = conditions; self.actions = actions
    }
}
public enum SplitError: Error, LocalizedError {
    case doesNotBalance
    public var errorDescription: String? { "Split amounts must be positive and add up to the original amount (or 100%)." }
}
public struct RuleResult: Sendable {
    public var entry: EntryValue
    public var children: [EntryValue] = []
    public var receivables: [ReceivableValue] = []
    public var matchedRuleIDs: [String] = []
}

public enum RuleEngine {
    public static func matches(_ rule: RuleValue, entry: EntryValue) -> Bool {
        guard rule.enabled, !rule.conditions.isEmpty else { return false }
        return rule.conditions.allSatisfy { condition in
            if condition.field == .amount {
                guard let value = Money.decimal(condition.value) else { return false }
                let amount = abs(entry.amount)
                switch condition.operation {
                case .equals: return amount == value
                case .greaterThan: return amount > value
                case .between: return amount >= value && amount <= (Money.decimal(condition.secondValue ?? "") ?? value)
                default: return false
                }
            }
            let text: String
            switch condition.field {
            case .merchant: text = entry.merchant
            case .description: text = entry.originalDescription
            case .direction: text = entry.amount < 0 ? "out" : "in"
            case .account: text = entry.accountID
            case .category: text = entry.categoryID
            case .amount: return false
            }
            switch condition.operation {
            case .contains: return text.localizedCaseInsensitiveContains(condition.value)
            case .equals: return text.caseInsensitiveCompare(condition.value) == .orderedSame
            case .regex:
                guard let regex = try? NSRegularExpression(pattern: condition.value, options: .caseInsensitive) else { return false }
                return regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
            default: return false
            }
        }
    }

    public static func split(entry: EntryValue, parts: [SplitPart], percentage: Bool = false) throws -> [EntryValue] {
        guard parts.count >= 2, parts.allSatisfy({ $0.amount > 0 }),
              parts.reduce(Decimal.zero, { $0 + $1.amount }) == (percentage ? 100 : abs(entry.amount)) else { throw SplitError.doesNotBalance }
        var allocated: Decimal = 0
        return parts.enumerated().map { index, part in
            let magnitude: Decimal = index == parts.count - 1 ? abs(entry.amount) - allocated : Money.rounded(percentage ? abs(entry.amount) * part.amount / 100 : part.amount)
            allocated += magnitude
            var child = entry
            child.id = "\(entry.id)-split-\(index)"; child.parentID = entry.id; child.sourceID = nil; child.importHash = nil
            child.categoryID = part.categoryID; child.amount = entry.amount < 0 ? -magnitude : magnitude
            child.isSplitParent = false
            return child
        }
    }

    public static func apply(_ rules: [RuleValue], to entry: EntryValue) throws -> RuleResult {
        var result = RuleResult(entry: entry)
        for rule in rules.sorted(by: { $0.order < $1.order }) where matches(rule, entry: result.entry) {
            result.matchedRuleIDs.append(rule.id)
            for action in rule.actions {
                switch action {
                case .category(let id): if !entry.lockedFields.contains("category") { result.entry.categoryID = id }
                case .merchant(let name): if !entry.lockedFields.contains("merchant") { result.entry.merchant = name }
                case .tag(let tag): if !entry.lockedFields.contains("tags"), !result.entry.tags.contains(tag) { result.entry.tags.append(tag) }
                case .hide(let hidden): if !entry.lockedFields.contains("hidden") { result.entry.isHidden = hidden }
                case .review(let reviewed): if !entry.lockedFields.contains("review") { result.entry.isReviewed = reviewed }
                case .loan(let id): if !entry.lockedFields.contains("loan") { result.entry.loanID = id }
                case .goal(let id): if !entry.lockedFields.contains("goal") { result.entry.goalID = id }
                case .split(let parts, let percentage):
                    if !entry.lockedFields.contains("split") && !entry.isSplitParent {
                        result.children = try split(entry: result.entry, parts: parts, percentage: percentage)
                        result.entry.isSplitParent = true
                    }
                case .shared(let personID, let percentage):
                    if !entry.lockedFields.contains("shared"), entry.amount < 0, percentage > 0, percentage <= 100 {
                        let amount = Money.rounded(-entry.amount * percentage / 100)
                        guard amount > 0 else { continue }
                        // Stable ID makes re-applying a rule idempotent.
                        result.receivables.removeAll { $0.personID == personID }
                        result.receivables.append(.init(id: "\(entry.id)-\(personID)", personID: personID, sourceEntryID: entry.id, amount: amount, note: result.entry.merchant, createdAt: entry.date))
                    }
                }
            }
        }
        guard result.receivables.reduce(Decimal.zero, { $0 + $1.amount }) <= abs(entry.amount) else { throw ReceivableError.exceedsCharge }
        if !result.children.isEmpty && !result.receivables.isEmpty {
            throw ProxyError(errorCode: "SHARED_SPLIT_CONFLICT", message: "Use either a shared charge or a category split for one transaction.")
        }
        return result
    }
}
