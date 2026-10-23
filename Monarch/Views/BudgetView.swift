import SwiftUI
import SwiftData
import MonarchCore

struct BudgetView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app
    @Query private var budgets: [BudgetRecord]
    @Query(sort: \CategoryRecord.order) private var categories: [CategoryRecord]
    @Query private var accounts: [AccountRecord]
    @Query private var transactions: [TransactionRecord]
    @Query private var receivables: [ReceivableRecord]
    @State private var month = Date.now
    @State private var editing = false
    private var plans: [BudgetPlan] { budgets.compactMap { try? $0.decoded() } }
    private var plan: BudgetPlan { plans.first { $0.month == LedgerDate.month(month) } ?? BudgetPlan(month: LedgerDate.month(month), lines: categories.filter { $0.value.kind == .expense }.map { .init(categoryID: $0.id) }) }
    private var result: BudgetResult { LedgerMath.budget(plan: plan, previousPlans: plans, entries: transactions.map(\.value), accounts: accounts.map(\.value), categories: categories.map(\.value), receivables: receivables.map(\.value)) }
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                MonthPicker(month: $month)
                Picker("Budget mode", selection: Binding(get: { plan.categoryMode }, set: { new in var value = plan; value.categoryMode = new; save(value) })) {
                    Text("Flex budget").tag(false); Text("By category").tag(true)
                }.pickerStyle(.segmented)
                if !plan.categoryMode {
                    Card {
                        VStack(spacing: 14) {
                            Text("ROOM TO ENJOY").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(Palette.secondary)
                            ZStack {
                                Circle().stroke(Palette.line, lineWidth: 10)
                                Circle().trim(from: 0, to: CGFloat(max(0, min(1, Money.double(result.flexRemaining / max(1, plan.flexPlanned + result.flexRollover)))))).stroke(result.flexRemaining >= 0 ? Palette.forest : Palette.orange, style: StrokeStyle(lineWidth: 10, lineCap: .round)).rotationEffect(.degrees(-90))
                                VStack(spacing: 4) {
                                    AmountText(amount: result.flexRemaining).font(.system(size: 30, design: .rounded)).minimumScaleFactor(0.6).lineLimit(1)
                                    Text("flex remaining").font(.caption).foregroundStyle(Palette.secondary)
                                }.padding(20)
                            }.frame(width: 200, height: 200).padding(.vertical, 12)
                            HStack { Metric(title: "Planned", value: plan.flexPlanned); Metric(title: "Spent", value: result.flexActual); Metric(title: "Rolled over", value: result.flexRollover) }
                        }.frame(maxWidth: .infinity)
                    }
                }
                ForEach(BudgetBucket.allCases, id: \.self) { bucket in
                    Card {
                        SectionLabel(title: bucket.title, detail: plan.categoryMode || bucket != .flex ? "REMAINING" : "ACTUAL")
                        ForEach(categories.filter { $0.value.kind == .expense && $0.value.bucket == bucket }) { category in
                            let line = plan.lines.first { $0.categoryID == category.id }
                            let actual = result.actual[category.id] ?? 0
                            let remaining = result.remaining[category.id] ?? -actual
                            VStack(spacing: 8) {
                                HStack {
                                    Text(category.emoji)
                                    Text(category.name).font(.subheadline)
                                    Spacer()
                                    AmountText(amount: plan.categoryMode || bucket != .flex ? remaining : actual).font(.subheadline.weight(.medium)).foregroundStyle(remaining < 0 && (plan.categoryMode || bucket != .flex) ? Palette.orange : Palette.ink)
                                }
                                if let line, line.planned > 0 {
                                    ProgressView(value: max(0, min(1, Money.double(actual / max(1, line.planned + (result.rollover[category.id] ?? 0)))))).tint(remaining < 0 ? Palette.orange : Palette.forest)
                                    HStack {
                                        Text("\(Money.format(actual)) of \(Money.format(line.planned))")
                                        Spacer()
                                        if line.rolloverEnabled { Label(Money.format(result.rollover[category.id] ?? 0), systemImage: "arrow.turn.down.right") }
                                    }.font(.system(size: 10)).foregroundStyle(Palette.secondary)
                                }
                            }.padding(.top, 14)
                        }
                    }
                }
                Button("Edit this month’s plan") { editing = true }.buttonStyle(PrimaryButtonStyle())
                Text("Actuals include posted expenses and refunds, with only your share of shared charges. Transfers and reimbursements are excluded.").font(.caption).foregroundStyle(Palette.secondary)
            }.padding(20)
        }.background(Palette.background).navigationTitle("Budget").navigationBarTitleDisplayMode(.inline).appToolbar()
            .sheet(isPresented: $editing) { BudgetEditor(initial: plan, onSave: save).appErrors() }
    }
    private func save(_ value: BudgetPlan) {
        do {
            if let record = budgets.first(where: { $0.month == value.month }) { try record.apply(value) }
            else { context.insert(try BudgetRecord(value)) }
            try context.save()
        } catch { context.rollback(); app.report(error) }
    }
}

private struct BudgetEditor: View {
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \CategoryRecord.order) private var categories: [CategoryRecord]
    @State private var plan: BudgetPlan
    let onSave: (BudgetPlan) -> Void
    init(initial: BudgetPlan, onSave: @escaping (BudgetPlan) -> Void) { _plan = State(initialValue: initial); self.onSave = onSave }
    var body: some View {
        NavigationStack {
            Form {
                Section("Flex bucket") {
                    LabeledContent("Monthly plan") { TextField("0", value: $plan.flexPlanned, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                    Toggle("Roll flex remainder forward", isOn: $plan.flexRolloverEnabled)
                    if plan.flexRolloverEnabled { LabeledContent("First month’s starting balance") { TextField("0", value: $plan.flexStartingBalance, format: .number).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing) } }
                }
                ForEach(plan.lines.indices, id: \.self) { index in
                    let category = categories.first { $0.id == plan.lines[index].categoryID }
                    Section((category?.emoji ?? "") + " " + (category?.name ?? "Category")) {
                        LabeledContent("Planned") { TextField("0", value: $plan.lines[index].planned, format: .number).keyboardType(.decimalPad).multilineTextAlignment(.trailing) }
                        Toggle("Roll over remaining", isOn: $plan.lines[index].rolloverEnabled)
                        if plan.lines[index].rolloverEnabled { LabeledContent("Starting balance") { TextField("0", value: $plan.lines[index].startingBalance, format: .number).keyboardType(.numbersAndPunctuation).multilineTextAlignment(.trailing) } }
                    }
                }
            }.navigationTitle("Plan · \(plan.month)").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { onSave(plan); dismiss() }.disabled(plan.flexPlanned < 0 || plan.lines.contains { $0.planned < 0 }) }
            }.onAppear {
                for category in categories where category.value.kind == .expense && !plan.lines.contains(where: { $0.categoryID == category.id }) { plan.lines.append(.init(categoryID: category.id)) }
            }
        }
    }
}
