import SwiftUI
import SwiftData
import Charts
import MonarchCore

struct CashFlowView: View {
    @Query private var accounts: [AccountRecord]
    @Query private var transactions: [TransactionRecord]
    @Query private var categories: [CategoryRecord]
    @Query private var receivables: [ReceivableRecord]
    @State private var month = Date.now
    @State private var period = "Month"
    @State private var breakdown = "Category"
    private var monthCount: Int { period == "Year" ? 12 : period == "Quarter" ? 3 : 1 }
    private var periodStart: Date {
        let calendar = Calendar.current
        if period == "Year" { return calendar.dateInterval(of: .year, for: month)?.start ?? month }
        if period == "Quarter" { return calendar.dateInterval(of: .quarter, for: month)?.start ?? month }
        return LedgerDate.monthDate(LedgerDate.month(month))
    }
    private var periodEnd: Date { LedgerDate.shifting(periodStart, months: monthCount) }
    private var rows: [EntryValue] { transactions.filter { $0.date >= periodStart && $0.date < periodEnd }.map(\.value) }
    private var flow: CashFlowResult { LedgerMath.cashFlow(entries: rows, accounts: accounts.map(\.value), categories: categories.map(\.value), receivables: receivables.map(\.value)) }
    private var breakdownRows: [(String, Decimal)] {
        var totals: [String: Decimal] = [:]
        for row in rows where !row.isHidden && !row.isPending && !row.isSplitParent {
            guard accounts.first(where: { $0.id == row.accountID })?.hideFromCashFlow == false,
                  accounts.first(where: { $0.id == row.accountID })?.currency == "USD",
                  categories.first(where: { $0.id == row.categoryID })?.value.kind == .expense else { continue }
            let amount = row.amount < 0 ? LedgerMath.personalOutflow(row, receivables: receivables.map(\.value)) : -row.amount
            let keys: [String]
            switch breakdown {
            case "Merchant": keys = [row.merchant]
            case "Tag": keys = row.tags.isEmpty ? ["No tag"] : row.tags
            default: keys = [categories.first { $0.id == row.categoryID }?.name ?? "Uncategorized"]
            }
            for key in keys { totals[key, default: 0] += amount }
        }
        return totals.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }
    private var chartData: [(String, CashFlowResult)] {
        (0..<6).reversed().map { offset in
            let key = LedgerDate.month(LedgerDate.shifting(month, months: -offset))
            return (key, LedgerMath.cashFlow(entries: transactions.map(\.value), accounts: accounts.map(\.value), categories: categories.map(\.value), receivables: receivables.map(\.value), month: key))
        }
    }
    private var groupFlows: [(String, Decimal)] {
        let accountMap = Dictionary(uniqueKeysWithValues: accounts.map { ($0.id, $0) })
        let categoryMap = Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) })
        var totals: [String: Decimal] = [:]
        for row in rows where !row.isHidden && !row.isPending && !row.isSplitParent {
            guard accountMap[row.accountID]?.hideFromCashFlow == false, accountMap[row.accountID]?.currency == "USD", let category = categoryMap[row.categoryID], category.value.kind == .expense else { continue }
            totals[category.groupName, default: 0] += row.amount < 0 ? LedgerMath.personalOutflow(row, receivables: receivables.map(\.value)) : -row.amount
        }
        if flow.net > 0 { totals["Saved"] = flow.net }
        return totals.filter { $0.value > 0 }.sorted { $0.value > $1.value }.map { ($0.key, $0.value) }
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                MonthPicker(month: $month)
                Picker("Period", selection: $period) { ForEach(["Month", "Quarter", "Year"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                Card {
                    Text("MONEY IN, MONEY OUT").font(.system(size: 10, weight: .semibold)).tracking(1.5).foregroundStyle(Palette.secondary)
                    HStack { Metric(title: "Income", value: flow.income, color: Palette.forest); Metric(title: "Spending", value: flow.expenses, color: Palette.orange) }.padding(.top, 18)
                    Divider().padding(.vertical, 12)
                    HStack {
                        Metric(title: "Net cash flow", value: flow.net)
                        VStack(alignment: .leading, spacing: 7) {
                            Text("Savings rate").font(.caption).foregroundStyle(Palette.secondary)
                            Text(flow.savingsRate.map { "\(NSDecimalNumber(decimal: Money.rounded($0 * 100)).stringValue)%" } ?? "—").font(.system(.title3, design: .rounded, weight: .semibold))
                        }.frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                Card {
                    SectionLabel(title: "The rhythm of your money", detail: "6 MONTHS")
                    Chart(chartData, id: \.0) { point in
                        BarMark(x: .value("Month", String(point.0.suffix(2))), y: .value("Amount", Money.double(point.1.income))).foregroundStyle(Palette.forest).position(by: .value("Type", "Income"))
                        BarMark(x: .value("Month", String(point.0.suffix(2))), y: .value("Amount", Money.double(point.1.expenses))).foregroundStyle(Palette.mint).position(by: .value("Type", "Spending"))
                    }.frame(height: 180).padding(.top, 18).chartLegend(.hidden)
                    HStack { Label("Income", systemImage: "circle.fill").foregroundStyle(Palette.forest); Label("Spending", systemImage: "circle.fill").foregroundStyle(Palette.secondary) }.font(.caption2).padding(.top, 8)
                }
                if !groupFlows.isEmpty {
                    Card {
                        SectionLabel(title: "Where it goes")
                        SpendingFlowDiagram(income: flow.income, groups: groupFlows).frame(height: CGFloat(max(180, groupFlows.count * 44))).padding(.top, 18)
                        if flow.net < 0 { Text("Spending exceeds income by \(Money.format(-flow.net)).").font(.caption).foregroundStyle(Palette.orange) }
                    }
                }
                Card {
                    SectionLabel(title: "A closer look", detail: "SPENDING")
                    Picker("Break down by", selection: $breakdown) { ForEach(["Category", "Merchant", "Tag"], id: \.self) { Text($0) } }.pickerStyle(.segmented).padding(.vertical, 12)
                    ForEach(breakdownRows, id: \.0) { row in
                        HStack { Text(row.0); Spacer(); AmountText(amount: row.1) }.font(.subheadline).padding(.vertical, 8)
                    }
                    if breakdownRows.isEmpty { Text("Categorized spending will appear here.").font(.caption).foregroundStyle(Palette.secondary) }
                    if breakdown == "Tag" { Text("A transaction with several tags appears under each tag.").font(.caption2).foregroundStyle(Palette.secondary) }
                }
                Text("\(periodStart.formatted(date: .abbreviated, time: .omitted)) – \(Calendar.current.date(byAdding: .day, value: -1, to: periodEnd)!.formatted(date: .abbreviated, time: .omitted)) · Posted activity only. Transfers and reimbursements excluded.").font(.caption2).foregroundStyle(Palette.secondary)
            }.padding(20)
        }.background(Palette.background).navigationTitle("Cash flow").navigationBarTitleDisplayMode(.inline).appToolbar()
    }
}

private struct SpendingFlowDiagram: View {
    let income: Decimal
    let groups: [(String, Decimal)]
    var body: some View {
        GeometryReader { geometry in
            let height = geometry.size.height
            let step = height / CGFloat(max(1, groups.count))
            let total = max(1, groups.reduce(Decimal.zero) { $0 + $1.1 })
            ZStack {
                Canvas { context, size in
                    for (index, group) in groups.enumerated() {
                        var path = Path()
                        let endY = step * (CGFloat(index) + 0.5)
                        path.move(to: CGPoint(x: 75, y: size.height / 2))
                        path.addCurve(to: CGPoint(x: size.width - 105, y: endY), control1: CGPoint(x: size.width * 0.48, y: size.height / 2), control2: CGPoint(x: size.width * 0.52, y: endY))
                        context.stroke(path, with: .color(group.0 == "Saved" ? Palette.forest.opacity(0.4) : Palette.mint.opacity(0.7)), style: StrokeStyle(lineWidth: max(2, CGFloat(Money.double(group.1 / total)) * 50), lineCap: .round))
                    }
                }
                HStack {
                    VStack(alignment: .leading, spacing: 4) { Text("Income").font(.caption); AmountText(amount: income).font(.caption2.weight(.semibold)) }.frame(width: 75, alignment: .leading)
                    Spacer()
                    VStack(alignment: .trailing, spacing: 0) {
                        ForEach(groups, id: \.0) { group in
                            VStack(alignment: .trailing, spacing: 3) { Text(group.0).font(.caption); AmountText(amount: group.1).font(.system(size: 9)).foregroundStyle(Palette.secondary) }.frame(height: step)
                        }
                    }.frame(width: 105, alignment: .trailing)
                }
            }
        }
    }
}
