#if DEBUG
import Foundation
import SwiftData
import MonarchCore

/// Invoked only with BOTH --ui-testing and --screenshot-testing in a Debug build.
/// The caller supplies an in-memory container; normal launches never add these rows.
@MainActor enum ScreenshotFixtures {
    static func install(_ context: ModelContext) throws {
        let now = Date.now, calendar = Calendar.current
        func daysAgo(_ days: Int) -> Date { calendar.date(byAdding: .day, value: -days, to: now) ?? now }
        let checking = AccountRecord(id: "preview-checking", name: "Example Checking", kind: .checking, balance: 6820.14, mask: "1234")
        let savings = AccountRecord(id: "preview-savings", name: "Example Savings", kind: .savings, balance: 18500, mask: "5678")
        let card = AccountRecord(id: "preview-card", name: "Example Rewards Card", kind: .credit, balance: 940.48, mask: "9012")
        for account in [checking, savings, card] { context.insert(account) }
        for offset in stride(from: 20, through: 0, by: -1) {
            context.insert(SnapshotRecord(accountID: checking.id, date: daysAgo(offset), balance: checking.balance - Decimal(offset * 21)))
            context.insert(SnapshotRecord(accountID: savings.id, date: daysAgo(offset), balance: savings.balance - Decimal(offset * 12)))
            context.insert(SnapshotRecord(accountID: card.id, date: daysAgo(offset), balance: card.balance + Decimal(offset * 4)))
        }
        let entries: [EntryValue] = [
            .init(id: "preview-pay", accountID: checking.id, date: daysAgo(4), amount: 3200, merchant: "Example Payroll", categoryID: "income", isReviewed: true),
            .init(id: "preview-rent", accountID: checking.id, date: daysAgo(3), amount: -1800, merchant: "Example Apartments", categoryID: "housing", isReviewed: true),
            .init(id: "preview-groceries", accountID: card.id, date: daysAgo(2), amount: -86.24, merchant: "Example Market", categoryID: "groceries"),
            .init(id: "preview-medical", accountID: card.id, date: daysAgo(1), amount: -42.50, merchant: "Example Pharmacy", categoryID: "health"),
            .init(id: "preview-shopping", accountID: card.id, date: now, amount: -89, merchant: "Example Outfitters", categoryID: "shopping"),
            .init(id: "preview-coffee", accountID: card.id, date: now, amount: -5.75, merchant: "Example Coffee", categoryID: "dining", isReviewed: true)
        ]
        for entry in entries { var value = entry; value.notes = "UI screenshot example; no actual purchase."; context.insert(TransactionRecord(value)) }
        context.insert(try BudgetRecord(BudgetPlan(month: LedgerDate.month(now), flexPlanned: 1200, lines: [.init(categoryID: "housing", planned: 1800), .init(categoryID: "utilities", planned: 135)])))
        context.insert(try ReceiptRecord(ReceiptValue(id: "preview-medical-receipt", source: .scan, merchant: "Example Pharmacy", orderNumber: "EXAMPLE-1042", date: daysAgo(1), subtotal: 39, tax: 3.50, total: 42.50, lineItems: [.init(name: "Example first aid supplies", amount: 24), .init(name: "Example medical supplies", amount: 15)], transactionID: "preview-medical", hsaEligible: true, hsaStatus: .unreimbursed, needsReview: false, extractedText: "Screenshot example only. No actual receipt or eligibility determination.")))
        context.insert(try ReceiptRecord(ReceiptValue(id: "preview-order-receipt", source: .email, merchant: "Example Outfitters", orderNumber: "EXAMPLE-2089", date: now, subtotal: 89, tax: 0, total: 89, lineItems: [.init(name: "Example daypack", amount: 89)], transactionID: "preview-shopping", needsReview: true)))
        context.insert(try ShipmentRecord(ShipmentValue(trackingNumber: "LINKSCREENSHOTEXAMPLE", carrier: .ups, receiptID: "preview-order-receipt", transactionID: "preview-shopping", status: .outForDelivery, eta: now.addingTimeInterval(4 * 3600), lastEvent: "Example: out for delivery", events: [.init(date: now.addingTimeInterval(-3600), description: "Example: out for delivery", location: "Example City"), .init(date: daysAgo(1), description: "Example: package in transit")], trackingURL: "https://example.com/tracking")))
        try context.save()
    }
}
#endif
