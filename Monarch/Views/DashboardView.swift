import SwiftUI
import SwiftData
import Charts
import MonarchCore

struct DashboardView: View {
    @Environment(AppState.self) private var app
    @Query private var accounts: [AccountRecord]
    @Query(sort: \TransactionRecord.date, order: .reverse) private var transactions: [TransactionRecord]
    @Query(sort: \CategoryRecord.order) private var categories: [CategoryRecord]
    @Query private var receivables: [ReceivableRecord]
    @Query private var people: [PersonRecord]
    @Query private var budgets: [BudgetRecord]
    @Query(sort: \SnapshotRecord.date) private var snapshots: [SnapshotRecord]
    @State private var showAdd = false
    @State private var customize = false
    @AppStorage("dashboardWidgets") private var widgets = "netWorth,budget,collect,review,recent"
    private var visible: [String] { widgets.split(separator: ",").map(String.init) }
    private var netWorth: Decimal { LedgerMath.netWorth(accounts.map(\.value)) }
    private var toReview: [TransactionRecord] { transactions.filter { !$0.isReviewed && !$0.isSplitParent && !$0.isHidden } }
    private var categoryMap: [String: CategoryRecord] { Dictionary(uniqueKeysWithValues: categories.map { ($0.id, $0) }) }
    private var budget: BudgetResult {
        let plans = budgets.compactMap { try? $0.decoded() }
        let plan = plans.first { $0.month == LedgerDate.month(.now) } ?? BudgetPlan(month: LedgerDate.month(.now))
        return LedgerMath.budget(plan: plan, previousPlans: plans, entries: transactions.map(\.value), accounts: accounts.map(\.value), categories: categories.map(\.value), receivables: receivables.map(\.value))
    }
    private var flexProgress: CGFloat {
        let plan = budgets.compactMap { try? $0.decoded() }.first { $0.month == LedgerDate.month(.now) }
        let available = (plan?.flexPlanned ?? 0) + budget.flexRollover
        return available > 0 ? CGFloat(max(0, min(1, Money.double(budget.flexRemaining / available)))) : 0
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                VStack(alignment: .leading, spacing: 9) {
                    Text(Date.now, format: .dateTime.weekday(.wide).month(.wide).day()).textCase(.uppercase).font(.system(size: 10, weight: .semibold)).tracking(1.8).foregroundStyle(Palette.secondary)
                    Text("Your money,\na little clearer.").font(.system(size: 34, weight: .regular, design: .serif)).tracking(-0.8)
                }.padding(.vertical, 12)
                if accounts.isEmpty {
                    Card {
                        EmptyCard(title: "Make yourself at home", message: "Connect a Sandbox bank or add a manual account. Everything in your ledger stays on this device.", symbol: "leaf")
                        Button("Add your first account") { showAdd = true }.buttonStyle(PrimaryButtonStyle())
                    }
                }
                ForEach(visible, id: \.self) { widget in
                    switch widget {
                    case "netWorth": netWorthCard
                    case "budget": budgetCard
                    case "collect": collectCard
                    case "review": reviewCard
                    case "recent": recentCard
                    default: EmptyView()
                    }
                }
                Button { customize = true } label: { Label("Customize dashboard", systemImage: "slider.horizontal.3").font(.caption).frame(maxWidth: .infinity).padding() }
                Text("PRIVATE BY DESIGN · MADE FOR YOU").font(.system(size: 8, weight: .medium)).tracking(2).foregroundStyle(Palette.secondary).frame(maxWidth: .infinity).padding(.bottom, 12)
            }.padding(.horizontal, 20)
        }.background(Palette.background).foregroundStyle(Palette.ink)
            .navigationTitle("Overview").navigationBarTitleDisplayMode(.inline).appToolbar()
            .refreshable { await app.sync() }
            .sheet(isPresented: $showAdd) { AddAccountSheet().appErrors() }
            .sheet(isPresented: $customize) { DashboardCustomization(widgets: $widgets) }
    }

    private var netWorthCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack { Label("NET WORTH", systemImage: "chart.line.uptrend.xyaxis").font(.system(size: 10, weight: .medium)).tracking(1.5); Spacer(); Text("USD").font(.caption2).opacity(0.6) }
            AmountText(amount: netWorth).font(.system(size: 36, weight: .medium, design: .rounded)).minimumScaleFactor(0.6).lineLimit(1)
            if snapshots.count > 1 {
                Chart(netWorthHistory, id: \.date) { point in
                    AreaMark(x: .value("Day", point.date), y: .value("Net worth", point.amount)).foregroundStyle(LinearGradient(colors: [Palette.mint.opacity(0.4), .clear], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Day", point.date), y: .value("Net worth", point.amount)).foregroundStyle(Palette.mint).interpolationMethod(.monotone)
                }.chartXAxis(.hidden).chartYAxis(.hidden).frame(height: 70)
            } else { Text("Your daily balance history starts here.").font(.caption).foregroundStyle(.white.opacity(0.65)).padding(.vertical, 10) }
            HStack {
                VStack(alignment: .leading, spacing: 5) { Text("Assets").font(.caption2).opacity(0.7); AmountText(amount: accounts.filter { !$0.kind.isLiability && !$0.hideFromNetWorth && !$0.isArchived && $0.currency == "USD" }.reduce(0) { $0 + $1.balance }).font(.subheadline) }
                Spacer()
                VStack(alignment: .trailing, spacing: 5) { Text("Liabilities").font(.caption2).opacity(0.7); AmountText(amount: accounts.filter { $0.kind.isLiability && !$0.hideFromNetWorth && !$0.isArchived && $0.currency == "USD" }.reduce(0) { $0 + $1.balance }).font(.subheadline) }
            }
        }.padding(24).foregroundStyle(.white).background(Palette.forest, in: RoundedRectangle(cornerRadius: 26))
    }

    private var budgetCard: some View {
        Button { app.selectedTab = 3 } label: {
            Card {
                SectionLabel(title: "Room to enjoy", detail: "THIS MONTH")
                HStack(alignment: .center, spacing: 18) {
                    ZStack {
                        Circle().stroke(Palette.line, lineWidth: 7)
                        Circle().trim(from: 0, to: flexProgress).stroke(Palette.forest, style: StrokeStyle(lineWidth: 7, lineCap: .round)).rotationEffect(.degrees(-90))
                        Image(systemName: "leaf").foregroundStyle(Palette.forest)
                    }.frame(width: 55, height: 55)
                    VStack(alignment: .leading, spacing: 3) {
                        AmountText(amount: budget.flexRemaining).font(.system(.title, design: .rounded, weight: .medium))
                        Text("left in your flex budget").font(.caption).foregroundStyle(Palette.secondary)
                    }
                    Spacer(); Image(systemName: "chevron.right").font(.caption).foregroundStyle(Palette.secondary)
                }.padding(.top, 18)
            }
        }.buttonStyle(.plain)
    }

    private var collectCard: some View {
        NavigationLink { ReceivablesView() } label: {
            Card {
                SectionLabel(title: "To collect", detail: "SHARED COSTS")
                let total = receivables.reduce(Decimal.zero) { $0 + $1.value.remaining }
                HStack {
                    AmountText(amount: total).font(.system(.title2, design: .rounded, weight: .medium)); Spacer()
                    Image(systemName: "arrow.up.right").foregroundStyle(Palette.forest)
                }.padding(.top, 12)
                ForEach(people.filter { person in receivables.contains { $0.personID == person.id && $0.value.remaining > 0 } }) { person in
                    let items = receivables.filter { $0.personID == person.id && $0.value.remaining > 0 }
                    HStack {
                        Text(person.name)
                        if let oldest = items.map(\.createdAt).min() { Text("· \(max(0, Calendar.current.dateComponents([.day], from: oldest, to: .now).day ?? 0))d").foregroundStyle(Palette.secondary) }
                        Spacer(); AmountText(amount: items.reduce(0) { $0 + $1.value.remaining })
                    }.font(.caption).padding(.top, 8)
                }
                if total == 0 { Text("All settled up. A nice place to be.").font(.caption).foregroundStyle(Palette.secondary).padding(.top, 4) }
            }
        }.buttonStyle(.plain)
    }

    private var reviewCard: some View {
        NavigationLink { TransactionsView(reviewOnly: true) } label: {
            Card {
                SectionLabel(title: "A quick check-in", detail: "\(toReview.count) TO REVIEW")
                if toReview.isEmpty { Text("Your transactions are all reviewed.").font(.caption).foregroundStyle(Palette.secondary).padding(.top, 12) }
                ForEach(Array(toReview.prefix(3))) { transaction in EntryRow(transaction: transaction, category: categoryMap[transaction.categoryID]) }
            }
        }.buttonStyle(.plain)
    }

    private var recentCard: some View {
        Card {
            SectionLabel(title: "Latest activity", detail: "RECENT")
            if transactions.isEmpty { Text("Your transactions will appear after your first sync or import.").font(.caption).foregroundStyle(Palette.secondary).padding(.top, 12) }
            ForEach(Array(transactions.filter { !$0.isSplitParent }.prefix(5))) { transaction in
                NavigationLink { TransactionDetailView(transaction: transaction) } label: { EntryRow(transaction: transaction, category: categoryMap[transaction.categoryID]) }.buttonStyle(.plain)
            }
        }
    }

    private struct HistoryPoint { var date: Date; var amount: Double }
    private var netWorthHistory: [HistoryPoint] {
        let included = accounts.filter { !$0.hideFromNetWorth && !$0.isArchived && $0.currency == "USD" }
        let dates = Set(snapshots.map(\.date)).sorted()
        var latest: [String: Decimal] = [:]
        return dates.map { day in
            for snapshot in snapshots where snapshot.date == day { latest[snapshot.accountID] = snapshot.balance }
            let amount = included.reduce(Decimal.zero) { $0 + ($1.kind.isLiability ? -(latest[$1.id] ?? 0) : latest[$1.id] ?? 0) }
            return HistoryPoint(date: day, amount: Money.double(amount))
        }
    }
}

private struct DashboardCustomization: View {
    @Binding var widgets: String
    @Environment(\.dismiss) private var dismiss
    @State private var ordered: [String] = []
    private let titles = ["netWorth": "Net worth", "budget": "Flex budget", "collect": "To collect", "review": "Needs review", "recent": "Recent transactions"]
    var body: some View {
        NavigationStack {
            List {
                Section("Drag to reorder") {
                    ForEach(ordered, id: \.self) { id in Text(titles[id] ?? id) }
                        .onMove { ordered.move(fromOffsets: $0, toOffset: $1) }
                        .onDelete { ordered.remove(atOffsets: $0) }
                }
                Section("Add widget") {
                    ForEach(titles.keys.sorted().filter { !ordered.contains($0) }, id: \.self) { id in Button(titles[id] ?? id) { ordered.append(id) } }
                }
            }.environment(\.editMode, .constant(.active)).navigationTitle("Your dashboard")
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { widgets = ordered.joined(separator: ","); dismiss() } } }
                .onAppear { ordered = widgets.split(separator: ",").map(String.init) }
        }
    }
}
