import SwiftUI
import SwiftData
import MonarchCore

struct RulesView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app
    @Query(sort: \RuleRecord.order) private var rules: [RuleRecord]
    @State private var adding = false
    var body: some View {
        List {
            Section { Text("Rules run from top to bottom on imported transactions. Fields you edit yourself stay protected.").font(.caption).foregroundStyle(Palette.secondary) }
            ForEach(rules) { rule in
                HStack {
                    VStack(alignment: .leading, spacing: 5) { Text(rule.name).font(.subheadline.weight(.medium)); Text("\(rule.matchCount) ingest matches").font(.caption2).foregroundStyle(Palette.secondary) }
                    Spacer()
                    Toggle("Enabled", isOn: Binding(get: { rule.enabled }, set: { rule.enabled = $0; app.save(context) })).labelsHidden()
                }
            }.onMove { source, destination in
                var ordered = rules; ordered.move(fromOffsets: source, toOffset: destination)
                for (index, rule) in ordered.enumerated() { rule.order = index }
                app.save(context)
            }.onDelete { indexes in indexes.forEach { context.delete(rules[$0]) }; app.save(context) }
            if rules.isEmpty { EmptyCard(title: "Let the small things run themselves", message: "Start with a merchant name, choose what should happen, and preview every match.", symbol: "arrow.triangle.branch") }
        }.navigationTitle("Rules").toolbar { ToolbarItemGroup(placement: .topBarTrailing) { EditButton(); Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add rule") } }
            .sheet(isPresented: $adding) { RuleEditorView().appErrors() }
    }
}

struct RuleEditorView: View {
    var initialMerchant = ""
    var initialCategory = "uncategorized"
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Query private var transactions: [TransactionRecord]
    @Query(sort: \CategoryRecord.order) private var categories: [CategoryRecord]
    @Query(sort: \AccountRecord.name) private var accounts: [AccountRecord]
    @Query private var people: [PersonRecord]
    @Query private var loans: [LoanRecord]
    @Query private var rules: [RuleRecord]
    @Query private var receivables: [ReceivableRecord]
    @State private var name = ""
    @State private var merchant = ""
    @State private var operation: RuleOperator = .contains
    @State private var originalContains = ""
    @State private var minimum = ""
    @State private var maximum = ""
    @State private var accountID = ""
    @State private var direction = ""
    @State private var categoryID = "uncategorized"
    @State private var rename = ""
    @State private var tag = ""
    @State private var hide = false
    @State private var reviewed = false
    @State private var personID = ""
    @State private var sharedPercentage = "100"
    @State private var loanID = ""
    @State private var applyExisting = false
    private var proposed: RuleValue {
        var conditions: [RuleCondition] = [.init(field: .merchant, operation: operation, value: merchant)]
        if !originalContains.isEmpty { conditions.append(.init(field: .description, value: originalContains)) }
        if !minimum.isEmpty { conditions.append(.init(field: .amount, operation: maximum.isEmpty ? .greaterThan : .between, value: minimum, secondValue: maximum)) }
        if !accountID.isEmpty { conditions.append(.init(field: .account, operation: .equals, value: accountID)) }
        if !direction.isEmpty { conditions.append(.init(field: .direction, operation: .equals, value: direction)) }
        var actions: [RuleAction] = [.category(categoryID)]
        if !rename.isEmpty { actions.append(.merchant(rename)) }
        if !tag.isEmpty { actions.append(.tag(tag)) }
        if hide { actions.append(.hide(true)) }
        if reviewed { actions.append(.review(true)) }
        if !personID.isEmpty { actions.append(.shared(personID: personID, percentage: Money.decimal(sharedPercentage) ?? 0)) }
        if !loanID.isEmpty { actions.append(.loan(loanID)) }
        return .init(name: name.isEmpty ? merchant + " → " + (categories.first { $0.id == categoryID }?.name ?? "Category") : name, order: (rules.map(\.order).max() ?? -1) + 1, conditions: conditions, actions: actions)
    }
    private var matches: [TransactionRecord] { transactions.filter { !$0.isSplitParent && $0.parentID == nil && RuleEngine.matches(proposed, entry: $0.value) } }
    var body: some View {
        NavigationStack {
            Form {
                Section("When all conditions match") {
                    TextField("Rule name (optional)", text: $name)
                    TextField("Merchant", text: $merchant)
                    Picker("Match", selection: $operation) { Text("Contains").tag(RuleOperator.contains); Text("Equals").tag(RuleOperator.equals); Text("Regular expression").tag(RuleOperator.regex) }
                    TextField("Original description contains (optional)", text: $originalContains)
                    TextField("Amount greater than / minimum", text: $minimum).keyboardType(.decimalPad)
                    TextField("Maximum amount (optional)", text: $maximum).keyboardType(.decimalPad)
                    Picker("Account", selection: $accountID) { Text("Any").tag(""); ForEach(accounts) { Text($0.name).tag($0.id) } }
                    Picker("Direction", selection: $direction) { Text("Any").tag(""); Text("Money out").tag("out"); Text("Money in").tag("in") }
                }
                Section("Then") {
                    Picker("Category", selection: $categoryID) { ForEach(categories) { Text($0.emoji + " " + $0.name).tag($0.id) } }
                    TextField("Rename merchant (optional)", text: $rename)
                    TextField("Add tag (optional)", text: $tag)
                    Toggle("Mark reviewed", isOn: $reviewed)
                    Toggle("Hide from calculations", isOn: $hide)
                    Picker("Link to loan", selection: $loanID) { Text("None").tag(""); ForEach(loans) { Text($0.servicer).tag($0.id) } }
                    Picker("Create a shared cost", selection: $personID) { Text("No shared cost").tag(""); ForEach(people) { Text($0.name).tag($0.id) } }
                    if !personID.isEmpty { TextField("Percentage owed", text: $sharedPercentage).keyboardType(.decimalPad) }
                }
                Section("Preview · \(matches.count) matches") {
                    ForEach(Array(matches.prefix(8))) { row in HStack { Text(row.merchant); Spacer(); AmountText(amount: row.amount) }.font(.caption) }
                    Toggle("Apply to these existing transactions", isOn: $applyExisting)
                    Text("Saving always enables this rule for future imports. Existing manual field edits remain protected.").font(.caption2).foregroundStyle(Palette.secondary)
                }
            }.navigationTitle("New rule").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(merchant.trimmingCharacters(in: .whitespaces).isEmpty) }
            }.onAppear { merchant = initialMerchant; categoryID = initialCategory }
        }
    }
    private func save() {
        do {
            if operation == .regex { _ = try NSRegularExpression(pattern: merchant) }
            if !minimum.isEmpty && Money.decimal(minimum) == nil { throw ProxyError(errorCode: "INVALID_AMOUNT", message: "Enter a valid minimum amount.") }
            if !maximum.isEmpty && (Money.decimal(maximum) == nil || (Money.decimal(maximum) ?? 0) < (Money.decimal(minimum) ?? 0)) { throw ProxyError(errorCode: "INVALID_AMOUNT", message: "The maximum must be at least the minimum.") }
            if !personID.isEmpty && ((Money.decimal(sharedPercentage) ?? 0) <= 0 || (Money.decimal(sharedPercentage) ?? 0) > 100) { throw ReceivableError.invalidAmount }
            let value = proposed
            context.insert(try RuleRecord(value))
            if applyExisting {
                for record in matches {
                    let result = try RuleEngine.apply([value], to: record.value)
                    for item in result.receivables where !receivables.contains(where: { $0.id == item.id }) {
                        let existing = receivables.filter { $0.sourceEntryID == record.id }.reduce(Decimal.zero) { $0 + ($1.statusRaw == "writtenOff" ? $1.amountPaid : $1.amount) }
                        try ReceivableEngine.validate(amount: item.amount, charge: record.amount, existing: existing)
                        context.insert(ReceivableRecord(item))
                    }
                    record.apply(result.entry)
                }
            }
            try context.save(); dismiss()
        } catch { context.rollback(); app.report(error) }
    }
}

struct CategoriesView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app
    @Query(sort: \CategoryRecord.order) private var categories: [CategoryRecord]
    @State private var adding = false
    @State private var selected: CategoryRecord?
    var body: some View {
        List {
            ForEach(categories) { category in
                Button { selected = category } label: {
                    HStack {
                        Text(category.emoji)
                        VStack(alignment: .leading, spacing: 3) { Text(category.name).font(.subheadline); Text(category.groupName + " · " + category.value.kind.rawValue + " · " + category.value.bucket.title).font(.caption2).foregroundStyle(Palette.secondary) }
                    }.foregroundStyle(Palette.ink)
                }
            }.onMove { source, destination in
                var ordered = categories; ordered.move(fromOffsets: source, toOffset: destination)
                for (index, category) in ordered.enumerated() { category.order = index }
                app.save(context)
            }
        }.navigationTitle("Categories").toolbar { ToolbarItemGroup(placement: .topBarTrailing) { EditButton(); Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Add category") } }
            .sheet(isPresented: $adding) { CategoryEditor().appErrors() }
            .sheet(item: $selected) { CategoryEditor(category: $0).appErrors() }
    }
}

private struct CategoryEditor: View {
    var category: CategoryRecord? = nil
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @State private var name = ""
    @State private var emoji = "📦"
    @State private var group = "Other"
    @State private var kind = CategoryKind.expense
    @State private var bucket = BudgetBucket.flex
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name); TextField("Emoji", text: $emoji); TextField("Group", text: $group)
                Picker("Type", selection: $kind) { ForEach(CategoryKind.allCases, id: \.self) { Text($0.rawValue.capitalized).tag($0) } }
                Picker("Budget bucket", selection: $bucket) { ForEach(BudgetBucket.allCases, id: \.self) { Text($0.title).tag($0) } }
            }.navigationTitle(category == nil ? "Add category" : "Edit category").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    if let category {
                        category.name = name; category.emoji = emoji; category.groupName = group; category.kindRaw = kind.rawValue; category.bucketRaw = bucket.rawValue
                    } else { context.insert(CategoryRecord(.init(id: UUID().uuidString, name: name, emoji: emoji, group: group, kind: kind, bucket: bucket, order: 999))) }
                    do { try context.save(); dismiss() } catch { context.rollback(); app.report(error) }
                }.disabled(name.isEmpty || group.isEmpty) }
            }.onAppear { if let category { name = category.name; emoji = category.emoji; group = category.groupName; kind = category.value.kind; bucket = category.value.bucket } }
        }
    }
}
