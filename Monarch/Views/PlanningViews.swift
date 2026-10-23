import SwiftUI
import SwiftData
import Charts
import MonarchCore

struct LoansView: View {
    @Query private var loans: [LoanRecord]
    @Query private var accounts: [AccountRecord]
    @State private var adding = false
    @State private var template = "MOHELA"
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Card {
                    Text("ONE PAYMENT CLOSER").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(Palette.secondary)
                    AmountText(amount: accounts.filter { $0.kind == .loan && !$0.isArchived }.reduce(0) { $0 + $1.balance }).font(.system(size: 36, design: .rounded)).padding(.top, 10)
                    Text("Student loans & other debt").font(.caption).foregroundStyle(Palette.secondary)
                }
                ForEach(loans) { loan in
                    if let account = accounts.first(where: { $0.id == loan.accountID && !$0.isArchived }) {
                        NavigationLink { LoanDetailView(loan: loan, account: account) } label: {
                            Card {
                                HStack { Text(loan.servicer).font(.headline); Spacer(); Image(systemName: "arrow.up.right") }
                                Text("Borrower: \(loan.borrower)").font(.caption).foregroundStyle(Palette.secondary).padding(.top, 3)
                                AmountText(amount: account.balance).font(.system(.title2, design: .rounded)).padding(.vertical, 12)
                                HStack {
                                    Text("\(NSDecimalNumber(decimal: loan.apr).stringValue)% APR")
                                    Spacer()
                                    Text("\(Money.format(loan.minimumPayment))/mo")
                                }.font(.caption).foregroundStyle(Palette.secondary)
                                if loan.source == "manual", let date = loan.lastReconciledAt, Date.now.timeIntervalSince(date) > 30 * 86400 {
                                    Label("Reconcile your balance this month", systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(Palette.orange).padding(.top, 10)
                                }
                            }
                        }.buttonStyle(.plain)
                    }
                }
                if loans.isEmpty { EmptyCard(title: "A plan for the way forward", message: "Add MOHELA or Nelnet manually, or connect a loan using Plaid’s liabilities product.", symbol: "graduationcap") }
                HStack {
                    Button("Add MOHELA") { template = "MOHELA"; adding = true }
                    Spacer()
                    Button("Add Nelnet Parent PLUS") { template = "Nelnet Parent PLUS"; adding = true }
                }.font(.caption)
            }.padding(20)
        }.background(Palette.background).navigationTitle("Loans").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $adding) { ManualAccountSheet(initialName: template, initialKind: .loan).appErrors() }
    }
}

private struct LoanDetailView: View {
    @Bindable var loan: LoanRecord
    let account: AccountRecord
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app
    @State private var extra = 0.0
    private var principal: Decimal { max(0, account.balance - loan.accruedInterest) }
    private var base: LoanProjection { LoanMath.project(principal: principal, accruedInterest: loan.accruedInterest, apr: loan.apr, monthlyPayment: loan.minimumPayment) }
    private var projection: LoanProjection { LoanMath.project(principal: principal, accruedInterest: loan.accruedInterest, apr: loan.apr, monthlyPayment: loan.minimumPayment, extra: Decimal(extra)) }
    var body: some View {
        Form {
            Section {
                AmountText(amount: account.balance).font(.system(size: 34, design: .rounded)).padding(.vertical, 12)
                NavigationLink("Account & balance reconciliation") { AccountDetailView(account: account) }
            }
            Section("Loan details") {
                TextField("Servicer", text: $loan.servicer)
                TextField("Borrower", text: $loan.borrower)
                LabeledContent("APR (%)") { TextField("0", value: $loan.apr, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                LabeledContent("Minimum per month") { TextField("0", value: $loan.minimumPayment, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                LabeledContent("Accrued interest") { TextField("0", value: $loan.accruedInterest, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                if let due = loan.nextDue { LabeledContent("Next due", value: due.formatted(date: .abbreviated, time: .omitted)) }
            }
            Section("What a little extra could do") {
                HStack { Text("Extra per month"); Spacer(); AmountText(amount: Decimal(extra)) }
                Slider(value: $extra, in: 0...1000, step: 25)
                if projection.paysOff {
                    LabeledContent("Estimated payoff", value: LedgerDate.shifting(.now, months: projection.months).formatted(.dateTime.month(.wide).year()))
                    LabeledContent("Months remaining", value: "\(projection.months)")
                    LabeledContent("Projected interest", value: Money.format(projection.totalInterest))
                    if base.paysOff { LabeledContent("Interest saved", value: Money.format(max(0, base.totalInterest - projection.totalInterest))) }
                } else { Text("This payment does not pay the loan off within 50 years. Increase the payment or enter the loan’s minimum.").font(.caption).foregroundStyle(Palette.orange) }
                Text("Estimate uses daily simple interest with actual calendar days and monthly payments. It does not model forgiveness, deferment, or changing rates.").font(.caption2).foregroundStyle(Palette.secondary)
            }
        }.navigationTitle(loan.servicer).navigationBarTitleDisplayMode(.inline)
            .toolbar { Button("Save") { app.save(context) } }
            .onDisappear { app.save(context) }
    }
}

struct InvestmentsView: View {
    @Query private var holdings: [HoldingRecord]
    @State private var adding = false
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Card {
                    SectionLabel(title: "Your portfolio", detail: "LATEST REPORTED PRICES")
                    AmountText(amount: holdings.reduce(0) { $0 + $1.marketValue }).font(.system(size: 36, design: .rounded)).padding(.vertical, 12)
                    if !holdings.isEmpty {
                        Chart(holdings) { holding in SectorMark(angle: .value("Value", Money.double(holding.marketValue)), innerRadius: .ratio(0.7)).foregroundStyle(by: .value("Asset", holding.assetClass)) }.frame(height: 180)
                    }
                }
                Card {
                    SectionLabel(title: "Holdings")
                    ForEach(holdings) { holding in
                        HStack {
                            VStack(alignment: .leading, spacing: 4) {
                                Text(holding.symbol).font(.subheadline.weight(.semibold))
                                Text(holding.name).font(.caption).foregroundStyle(Palette.secondary)
                                Text("\(NSDecimalNumber(decimal: holding.quantity).stringValue) × \(Money.format(holding.price))").font(.caption2).foregroundStyle(Palette.secondary)
                            }
                            Spacer(); AmountText(amount: holding.marketValue).font(.subheadline)
                        }.padding(.top, 14)
                    }
                    if holdings.isEmpty { EmptyCard(title: "Give your future a home", message: "Connect a Sandbox investment account to see holdings and allocation.", symbol: "chart.line.uptrend.xyaxis") }
                }
                Button("Connect an investment account") { adding = true }.buttonStyle(PrimaryButtonStyle())
            }.padding(20)
        }.background(Palette.background).navigationTitle("Investments").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $adding) { AddAccountSheet(initialProduct: .investments).appErrors() }
    }
}

struct RecurringView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app
    @Query private var transactions: [TransactionRecord]
    @Query private var decisions: [RecurringRecord]
    @State private var calendarMode = false
    @State private var selectedDate = Date.now
    private var candidates: [RecurringCandidate] { RecurringDetector.detect(transactions.map(\.value)) }
    private func status(_ candidate: RecurringCandidate) -> String { decisions.first { $0.merchantKey == candidate.id }?.status ?? "detected" }
    var body: some View {
        List {
            Section { Toggle("Calendar view", isOn: $calendarMode); if calendarMode { DatePicker("Day", selection: $selectedDate, displayedComponents: .date).datePickerStyle(.graphical) } }
            Section("Confirmed") {
                ForEach(candidates.filter { status($0) == "confirmed" && (!calendarMode || Calendar.current.isDate($0.nextDate, inSameDayAs: selectedDate)) }) { candidate in candidateRow(candidate) }
            }
            Section("Detected · confirm before counting") {
                ForEach(candidates.filter { status($0) == "detected" }) { candidate in
                    VStack(alignment: .leading, spacing: 12) {
                        candidateRow(candidate)
                        HStack { Button("Confirm") { decide(candidate, "confirmed") }; Spacer(); Button("Dismiss") { decide(candidate, "dismissed") } }.font(.caption).buttonStyle(.borderless)
                    }
                }
                if candidates.isEmpty { Text("At least three consistent occurrences are needed to detect a recurring payment.").font(.caption).foregroundStyle(Palette.secondary) }
            }
        }.navigationTitle("Recurring").navigationBarTitleDisplayMode(.inline)
    }
    private func candidateRow(_ item: RecurringCandidate) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) { Text(item.merchant).font(.subheadline.weight(.medium)); Text(item.frequency + " · " + item.nextDate.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(Palette.secondary) }
            Spacer(); AmountText(amount: item.amount).font(.subheadline)
        }
    }
    private func decide(_ item: RecurringCandidate, _ status: String) {
        if let record = decisions.first(where: { $0.merchantKey == item.id }) { record.status = status }
        else { context.insert(RecurringRecord(merchantKey: item.id, status: status)) }
        app.save(context)
    }
}

struct InsightsView: View {
    @Query private var accounts: [AccountRecord]
    @Query private var transactions: [TransactionRecord]
    @Query private var categories: [CategoryRecord]
    @Query private var receivables: [ReceivableRecord]
    private var checks: [HealthCheck] {
        let start = LedgerDate.shifting(LedgerDate.monthDate(LedgerDate.month(.now)), months: -3)
        let end = LedgerDate.monthDate(LedgerDate.month(.now))
        var average = LedgerMath.cashFlow(entries: transactions.filter { $0.date >= start && $0.date < end }.map(\.value), accounts: accounts.map(\.value), categories: categories.map(\.value), receivables: receivables.map(\.value))
        average.income /= 3; average.expenses /= 3
        return HealthEngine.checks(flow: average, accounts: accounts.map(\.value), receivables: receivables.map(\.value))
    }
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Card {
                    SectionLabel(title: "A financial check-in")
                    Text(HealthEngine.score(checks).map { "\($0) / 100" } ?? "Let’s get to know your money").font(.system(size: 32, design: .serif)).padding(.vertical, 16)
                    Text("A reproducible score from the checks below. Missing data is skipped. Spending uses the last three completed calendar months.").font(.caption).foregroundStyle(Palette.secondary)
                }
                ForEach(checks) { check in
                    Card {
                        HStack { Text(check.title).font(.headline); Spacer(); Image(systemName: check.score == 1 ? "checkmark.circle.fill" : "exclamationmark.circle").foregroundStyle(check.score == 1 ? Palette.forest : Palette.orange) }
                        Text(check.detail).font(.subheadline).foregroundStyle(Palette.secondary).padding(.top, 8)
                        if let impact = check.yearlyImpact, impact > 0 { Text("Annualized gap: \(Money.format(impact))").font(.caption).foregroundStyle(Palette.orange).padding(.top, 8) }
                    }
                }
            }.padding(20)
        }.background(Palette.background).navigationTitle("Insights").navigationBarTitleDisplayMode(.inline)
    }
}

private struct ForecastSettings: Codable {
    var years = 5
    var investmentReturn: Decimal = 6
    var inflation: Decimal = 3
    var annualRaise: Decimal = 3
    var milestones: [ForecastMilestone] = []
}

struct ForecastView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app
    @Query private var accounts: [AccountRecord]
    @Query private var transactions: [TransactionRecord]
    @Query private var categories: [CategoryRecord]
    @Query private var receivables: [ReceivableRecord]
    @Query private var saved: [PlanningRecord]
    @State private var settings = ForecastSettings()
    @State private var adding = false
    private var average: CashFlowResult {
        let end = LedgerDate.monthDate(LedgerDate.month(.now)), start = LedgerDate.shifting(end, months: -3)
        var value = LedgerMath.cashFlow(entries: transactions.filter { $0.date >= start && $0.date < end }.map(\.value), accounts: accounts.map(\.value), categories: categories.map(\.value), receivables: receivables.map(\.value))
        value.income /= 3; value.expenses /= 3; return value
    }
    private func points(scenario: Bool) -> [ForecastPoint] {
        ForecastEngine.project(startNetWorth: LedgerMath.netWorth(accounts.map(\.value)), monthlyIncome: average.income, monthlyExpenses: average.expenses, investmentBalance: accounts.filter { $0.kind == .investment && !$0.isArchived && !$0.hideFromNetWorth }.reduce(0) { $0 + $1.balance }, investmentReturn: settings.investmentReturn, inflation: settings.inflation, annualRaise: settings.annualRaise, months: settings.years * 12, milestones: scenario ? settings.milestones : [])
    }
    var body: some View {
        List {
            Section("Cash-flow projection") {
                Chart {
                    ForEach(points(scenario: false)) { point in LineMark(x: .value("Month", point.month), y: .value("Net worth", Money.double(point.netWorth)), series: .value("Plan", "Base")).foregroundStyle(Palette.forest) }
                    if !settings.milestones.isEmpty { ForEach(points(scenario: true)) { point in LineMark(x: .value("Month", point.month), y: .value("Net worth", Money.double(point.netWorth)), series: .value("Plan", "Scenario")).foregroundStyle(Palette.orange) } }
                }.frame(height: 240)
                Text("Base: \(Money.format(points(scenario: false).last?.netWorth ?? 0))").font(.subheadline)
                if !settings.milestones.isEmpty { Text("Scenario difference: \(Money.format((points(scenario: true).last?.netWorth ?? 0) - (points(scenario: false).last?.netWorth ?? 0))) after \(settings.years) years.").font(.caption).foregroundStyle(Palette.orange) }
            }
            Section("Assumptions") {
                Stepper("\(settings.years) years", value: $settings.years, in: 1...10)
                LabeledContent("Investment return (%)") { TextField("6", value: $settings.investmentReturn, format: .number).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing) }
                LabeledContent("Annual inflation (%)") { TextField("3", value: $settings.inflation, format: .number).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing) }
                LabeledContent("Annual raise (%)") { TextField("3", value: $settings.annualRaise, format: .number).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing) }
                Text("Baseline: \(Money.format(average.income)) income and \(Money.format(average.expenses)) spending per month, averaged over the last three completed months.").font(.caption).foregroundStyle(Palette.secondary)
            }
            Section("Milestones") {
                ForEach(settings.milestones) { milestone in VStack(alignment: .leading) { Text(milestone.name); Text("Month \(milestone.month) · \(Money.format(milestone.oneTimeAmount)) once").font(.caption).foregroundStyle(Palette.secondary) } }.onDelete { settings.milestones.remove(atOffsets: $0) }
                Button("Add a milestone") { adding = true }
            }
            Section { Text("This is an aggregate planning estimate, not a full account-by-account forecast. It excludes future loan interest and savings APY. Investment returns are assumptions, not predictions.").font(.caption).foregroundStyle(Palette.secondary) }
        }.navigationTitle("Forecast").navigationBarTitleDisplayMode(.inline)
            .onAppear {
                if let data = saved.first(where: { $0.id == "forecast" })?.payload { do { settings = try JSONDecoder().decode(ForecastSettings.self, from: data) } catch { app.report(error) } }
            }
            .onDisappear { persist() }
            .toolbar { Button("Save") { persist() } }
            .sheet(isPresented: $adding) { MilestoneEditor { settings.milestones.append($0); persist() } }
    }
    private func persist() {
        do {
            let data = try JSONEncoder().encode(settings)
            if let record = saved.first(where: { $0.id == "forecast" }) { record.payload = data }
            else { context.insert(PlanningRecord(id: "forecast", payload: data)) }
            try context.save()
        } catch { context.rollback(); app.report(error) }
    }
}

private struct MilestoneEditor: View {
    let onSave: (ForecastMilestone) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name = ""
    @State private var month = 1
    @State private var once: Decimal = 0
    @State private var income: Decimal = 0
    @State private var spending: Decimal = 0
    var body: some View {
        NavigationStack {
            Form {
                TextField("Raise, move, car, or another event", text: $name)
                Stepper("Starts in month \(month)", value: $month, in: 1...120)
                LabeledContent("One-time inflow (+) / cost (−)") { TextField("0", value: $once, format: .number).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing) }
                LabeledContent("Monthly income change") { TextField("0", value: $income, format: .number).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing) }
                LabeledContent("Monthly expense change") { TextField("0", value: $spending, format: .number).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing) }
            }.navigationTitle("A life milestone").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Add") { onSave(.init(name: name, month: month, oneTimeAmount: once, monthlyIncomeChange: income, monthlyExpenseChange: spending)); dismiss() }.disabled(name.isEmpty) }
            }
        }
    }
}
