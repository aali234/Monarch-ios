import SwiftUI
import SwiftData
import MonarchCore

struct TransactionsView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app
    @Query(sort: \TransactionRecord.date, order: .reverse) private var transactions: [TransactionRecord]
    @Query(sort: \CategoryRecord.order) private var categories: [CategoryRecord]
    @Query(sort: \AccountRecord.name) private var accounts: [AccountRecord]
    @State private var search = ""
    @State private var accountID = ""
    @State private var categoryID = ""
    @State private var tag = ""
    @State private var minimum = ""
    @State private var maximum = ""
    @State private var dateFilter = false
    @State private var fromDate = LedgerDate.shifting(.now, months: -1)
    @State private var toDate = Date.now
    @State private var reviewOnly: Bool
    @State private var filters = false
    @State private var adding = false
    init(reviewOnly: Bool = false) { _reviewOnly = State(initialValue: reviewOnly) }
    private var filtered: [TransactionRecord] {
        let query = search.trimmingCharacters(in: .whitespacesAndNewlines)
        let low = Money.decimal(minimum), high = Money.decimal(maximum)
        let end = Calendar.current.date(byAdding: .day, value: 1, to: Calendar.current.startOfDay(for: toDate)) ?? toDate
        return transactions.filter { row in
            !row.isSplitParent && (!reviewOnly || !row.isReviewed) && (accountID.isEmpty || row.accountID == accountID) &&
            (categoryID.isEmpty || row.categoryID == categoryID) && (tag.isEmpty || row.tags.contains { $0.localizedCaseInsensitiveContains(tag) }) &&
            (low == nil || abs(row.amount) >= low!) && (high == nil || abs(row.amount) <= high!) &&
            (!dateFilter || (row.date >= Calendar.current.startOfDay(for: fromDate) && row.date < end)) &&
            (query.isEmpty || row.merchant.localizedCaseInsensitiveContains(query) || row.originalDescription.localizedCaseInsensitiveContains(query) || row.notes.localizedCaseInsensitiveContains(query))
        }
    }
    var body: some View {
        let rows = filtered
        let grouped = Dictionary(grouping: rows) { Calendar.current.startOfDay(for: $0.date) }
        List {
            Section {
                HStack {
                    Button { reviewOnly.toggle() } label: { Label(reviewOnly ? "Needs review" : "All activity", systemImage: reviewOnly ? "checkmark.circle" : "line.3.horizontal.decrease").font(.caption.weight(.medium)) }.buttonStyle(.bordered)
                    Spacer()
                    Button { filters = true } label: { Label("Filters", systemImage: "slider.horizontal.3").font(.caption) }
                    Text("\(rows.count)").font(.caption).foregroundStyle(Palette.secondary)
                }.listRowBackground(Color.clear)
            }
            if rows.isEmpty { EmptyCard(title: "A fresh page", message: transactions.isEmpty ? "Sync your bank, import a CSV, or add a transaction to get started." : "No transactions match these filters.", symbol: "list.bullet.rectangle").listRowBackground(Color.clear) }
            ForEach(grouped.keys.sorted(by: >), id: \.self) { day in
                Section(day.formatted(date: .abbreviated, time: .omitted)) {
                    ForEach(grouped[day] ?? []) { transaction in
                        NavigationLink { TransactionDetailView(transaction: transaction) } label: { EntryRow(transaction: transaction, category: categories.first { $0.id == transaction.categoryID }) }
                            .swipeActions(edge: .trailing) {
                                Button { transaction.isReviewed.toggle(); transaction.lock("review"); app.save(context) } label: { Label(transaction.isReviewed ? "Unreview" : "Reviewed", systemImage: "checkmark") }.tint(Palette.forest)
                            }
                    }
                }
            }
        }.scrollContentBackground(.hidden).background(Palette.background)
            .navigationTitle(reviewOnly ? "Needs review" : "Transactions").navigationBarTitleDisplayMode(.inline).appToolbar()
            .toolbar { ToolbarItem(placement: .bottomBar) { Button { adding = true } label: { Label("Add transaction", systemImage: "plus") } } }
            .searchable(text: $search, prompt: "Merchant, description, or note")
            .refreshable { await app.sync() }
            .sheet(isPresented: $adding) { ManualTransactionSheet().appErrors() }
            .sheet(isPresented: $filters) {
                NavigationStack {
                    Form {
                        Picker("Account", selection: $accountID) { Text("All accounts").tag(""); ForEach(accounts) { Text($0.name).tag($0.id) } }
                        Picker("Category", selection: $categoryID) { Text("All categories").tag(""); ForEach(categories) { Text($0.emoji + " " + $0.name).tag($0.id) } }
                        TextField("Tag contains", text: $tag)
                        TextField("Minimum absolute amount", text: $minimum).keyboardType(.decimalPad)
                        TextField("Maximum absolute amount", text: $maximum).keyboardType(.decimalPad)
                        Toggle("Filter by date", isOn: $dateFilter)
                        if dateFilter { DatePicker("From", selection: $fromDate, displayedComponents: .date); DatePicker("Through", selection: $toDate, displayedComponents: .date) }
                        Button("Reset filters") { accountID = ""; categoryID = ""; tag = ""; minimum = ""; maximum = ""; dateFilter = false }
                    }.navigationTitle("Filter activity").toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { filters = false } } }
                }.presentationDetents([.medium, .large])
            }
    }
}

struct TransactionDetailView: View {
    let transaction: TransactionRecord
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Query(sort: \CategoryRecord.order) private var categories: [CategoryRecord]
    @Query private var transactions: [TransactionRecord]
    @Query private var receivables: [ReceivableRecord]
    @State private var merchant = ""
    @State private var categoryID = "uncategorized"
    @State private var date = Date.now
    @State private var notes = ""
    @State private var tags = ""
    @State private var reviewed = false
    @State private var hidden = false
    @State private var showSplit = false
    @State private var showShared = false
    @State private var showRule = false
    @State private var offerRule = false
    var body: some View {
        Form {
            Section {
                VStack(spacing: 10) {
                    Text(categories.first { $0.id == categoryID }?.emoji ?? "📦").font(.system(size: 42))
                    AmountText(amount: transaction.amount).font(.system(size: 36, design: .rounded))
                    if transaction.isPending { Text("Pending").font(.caption).foregroundStyle(Palette.orange) }
                    let personal = LedgerMath.personalOutflow(transaction.value, receivables: receivables.map(\.value))
                    if transaction.amount < 0 && personal != -transaction.amount { Text("Your share: \(Money.format(personal))").font(.caption).foregroundStyle(Palette.forest) }
                }.frame(maxWidth: .infinity).padding(.vertical, 18)
            }.listRowBackground(Color.clear)
            Section("Details") {
                TextField("Merchant", text: $merchant)
                Picker("Category", selection: $categoryID) { ForEach(categories) { Text($0.emoji + " " + $0.name).tag($0.id) } }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                TextField("Tags, separated by commas", text: $tags)
                TextField("A note for later", text: $notes, axis: .vertical).lineLimit(3...6)
                Toggle("Reviewed", isOn: $reviewed)
                Toggle("Hide from calculations", isOn: $hidden)
            }
            Section("Organize") {
                if !transaction.isSplitParent && transaction.parentID == nil && !receivables.contains(where: { $0.sourceEntryID == transaction.id }) {
                    Button("Split into categories") { showSplit = true }
                }
                if transaction.amount < 0 && !transaction.isSplitParent && transaction.parentID == nil { Button("Mark as a shared charge") { showShared = true } }
                Button("Create a rule for this merchant") { showRule = true }
                if let parentID = transaction.parentID, let parent = transactions.first(where: { $0.id == parentID }) {
                    NavigationLink("Original charge & splits") { TransactionDetailView(transaction: parent) }
                }
                if transaction.isSplitParent {
                    ForEach(transactions.filter { $0.parentID == transaction.id }) { child in
                        NavigationLink { TransactionDetailView(transaction: child) } label: { EntryRow(transaction: child, category: categories.first { $0.id == child.categoryID }) }
                    }
                    Button("Remove split") {
                        transactions.filter { $0.parentID == transaction.id }.forEach { context.delete($0) }
                        transaction.isSplitParent = false; transaction.lock("split"); app.save(context)
                    }
                }
            }
            TransactionReceiptsSection(transactionID: transaction.id)
            Section("Original bank description") { Text(transaction.originalDescription.isEmpty ? transaction.merchant : transaction.originalDescription).font(.caption).foregroundStyle(Palette.secondary) }
        }.scrollContentBackground(.hidden).background(Palette.background).navigationTitle("Transaction").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(merchant.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) } }
            .onAppear {
                merchant = transaction.merchant; categoryID = transaction.categoryID; date = transaction.date
                notes = transaction.notes; tags = transaction.tags.joined(separator: ", "); reviewed = transaction.isReviewed; hidden = transaction.isHidden
            }
            .sheet(isPresented: $showSplit) { SplitEditor(transaction: transaction).appErrors() }
            .sheet(isPresented: $showShared) { ReceivableEditor(source: transaction).appErrors() }
            .sheet(isPresented: $showRule) { RuleEditorView(initialMerchant: merchant, initialCategory: categoryID).appErrors() }
            .confirmationDialog("Use this category next time?", isPresented: $offerRule, titleVisibility: .visible) {
                Button("Create a merchant rule") { showRule = true }
                Button("Done", role: .cancel) { dismiss() }
            }
    }
    private func save() {
        let changedCategory = categoryID != transaction.categoryID
        if merchant != transaction.merchant { transaction.merchant = merchant; transaction.lock("merchant") }
        if changedCategory { transaction.categoryID = categoryID; transaction.lock("category") }
        if date != transaction.date { transaction.date = date; transaction.lock("date") }
        if reviewed != transaction.isReviewed { transaction.isReviewed = reviewed; transaction.lock("review") }
        if hidden != transaction.isHidden { transaction.isHidden = hidden; transaction.lock("hidden") }
        transaction.notes = notes
        let editedTags = tags.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        if editedTags != transaction.tags { transaction.tags = editedTags; transaction.lock("tags") }
        do { try context.save(); if changedCategory { offerRule = true } else { dismiss() } }
        catch { context.rollback(); app.report(error) }
    }
}

private struct SplitEditor: View {
    let transaction: TransactionRecord
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Query(sort: \CategoryRecord.order) private var categories: [CategoryRecord]
    @State private var categoryIDs = ["groceries", "dining"]
    @State private var amounts = ["", ""]
    @State private var percentage = false
    var body: some View {
        NavigationStack {
            Form {
                Section { Toggle("Split by percentage", isOn: $percentage); Text("Original: \(Money.format(transaction.amount))").font(.caption) }
                ForEach(amounts.indices, id: \.self) { index in
                    Section("Part \(index + 1)") {
                        Picker("Category", selection: $categoryIDs[index]) { ForEach(categories) { Text($0.name).tag($0.id) } }
                        TextField(percentage ? "Percentage" : "Amount", text: $amounts[index]).keyboardType(.decimalPad)
                    }
                }
                Button("Add another part") { categoryIDs.append("uncategorized"); amounts.append("") }
            }.navigationTitle("Split transaction").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    do {
                        let parts = try amounts.enumerated().map { index, text -> SplitPart in
                            guard let amount = Money.decimal(text) else { throw SplitError.doesNotBalance }
                            return .init(categoryID: categoryIDs[index], amount: amount)
                        }
                        let children = try RuleEngine.split(entry: transaction.value, parts: parts, percentage: percentage)
                        children.forEach { context.insert(TransactionRecord($0)) }
                        transaction.isSplitParent = true; transaction.lock("split")
                        try context.save(); dismiss()
                    } catch { context.rollback(); app.report(error) }
                } }
            }
        }
    }
}

private struct ManualTransactionSheet: View {
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Query(sort: \AccountRecord.name) private var accounts: [AccountRecord]
    @Query(sort: \CategoryRecord.order) private var categories: [CategoryRecord]
    @State private var merchant = ""
    @State private var amount = ""
    @State private var outflow = true
    @State private var accountID = ""
    @State private var categoryID = "uncategorized"
    @State private var date = Date.now
    var body: some View {
        NavigationStack {
            Form {
                TextField("Merchant", text: $merchant)
                TextField("Amount", text: $amount).keyboardType(.decimalPad)
                Toggle("Money out", isOn: $outflow)
                Picker("Account", selection: $accountID) { Text("Choose an account").tag(""); ForEach(accounts.filter { !$0.isArchived }) { Text($0.name).tag($0.id) } }
                Picker("Category", selection: $categoryID) { ForEach(categories) { Text($0.emoji + " " + $0.name).tag($0.id) } }
                DatePicker("Date", selection: $date, displayedComponents: .date)
                Text("This adds a ledger entry. Reconcile manual account balances separately.").font(.caption).foregroundStyle(Palette.secondary)
            }.navigationTitle("Add transaction").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    guard let value = Money.decimal(amount), value > 0 else { return }
                    do {
                        let row = EntryValue(accountID: accountID, date: Calendar.current.startOfDay(for: date), amount: outflow ? -value : value, merchant: merchant, originalDescription: merchant, categoryID: categoryID, isReviewed: true, lockedFields: ["merchant", "category", "date", "review"])
                        context.insert(TransactionRecord(row)); try context.save(); dismiss()
                    } catch { context.rollback(); app.report(error) }
                }.disabled(accountID.isEmpty || merchant.isEmpty || (Money.decimal(amount) ?? 0) <= 0) }
            }
        }
    }
}
