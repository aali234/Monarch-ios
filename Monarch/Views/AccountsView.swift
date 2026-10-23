import SwiftUI
import SwiftData
import Charts
import LinkKit
import MonarchCore

struct AccountsView: View {
    @SwiftUI.Environment(AppState.self) private var app
    @Query(sort: \AccountRecord.name) private var accounts: [AccountRecord]
    @Query private var connections: [InstitutionRecord]
    @State private var adding = false
    private var active: [AccountRecord] { accounts.filter { !$0.isArchived } }
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("THE BIG PICTURE").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(Palette.secondary)
                    AmountText(amount: LedgerMath.netWorth(active.map(\.value))).font(.system(size: 38, weight: .regular, design: .rounded))
                    Text("Net worth · USD accounts").font(.caption).foregroundStyle(Palette.secondary)
                }.padding(.vertical, 12)
                if active.isEmpty { Card { EmptyCard(title: "Everything, together", message: "Bring your balances into one quiet corner. Start with a test bank in Plaid Sandbox.", symbol: "building.columns") } }
                ForEach(AccountKind.allCases, id: \.self) { kind in
                    let rows = active.filter { $0.kind == kind }
                    if !rows.isEmpty {
                        Card {
                            SectionLabel(title: kind.title, detail: Money.format(rows.filter { $0.currency == "USD" }.reduce(0) { $0 + $1.balance }))
                            ForEach(rows) { account in
                                NavigationLink { AccountDetailView(account: account) } label: {
                                    HStack(spacing: 12) {
                                        Image(systemName: kind.symbol).frame(width: 42, height: 42).background(Palette.background, in: RoundedRectangle(cornerRadius: 13)).foregroundStyle(Palette.forest)
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(account.name).font(.subheadline.weight(.medium)).lineLimit(1)
                                            Text(subtitle(account)).font(.caption).foregroundStyle(Palette.secondary)
                                        }
                                        Spacer(minLength: 4)
                                        AmountText(amount: account.balance, currency: account.currency).font(.subheadline.weight(.medium))
                                    }.padding(.vertical, 9).foregroundStyle(Palette.ink)
                                }.buttonStyle(.plain)
                            }
                        }
                    }
                }
                Button { adding = true } label: { Label("Add an account", systemImage: "plus") }.buttonStyle(PrimaryButtonStyle())
                if !accounts.filter(\.isArchived).isEmpty {
                    DisclosureGroup("Archived accounts") {
                        ForEach(accounts.filter(\.isArchived)) { account in NavigationLink(account.name) { AccountDetailView(account: account) } }
                    }.font(.caption).padding()
                }
            }.padding(20)
        }.background(Palette.background).navigationTitle("Accounts").navigationBarTitleDisplayMode(.inline).appToolbar()
            .refreshable { await app.sync() }.sheet(isPresented: $adding) { AddAccountSheet().appErrors() }
    }
    private func subtitle(_ account: AccountRecord) -> String {
        let institution = connections.first { $0.id == account.institutionRecordID }
        return (institution?.name ?? "Manual") + (account.mask.isEmpty ? "" : " · ••" + account.mask)
    }
}

struct AddAccountSheet: View {
    @SwiftUI.Environment(AppState.self) private var app
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @State private var product: LinkProduct = .transactions
    @State private var session: PlaidLinkSession?
    @State private var busy = false
    @State private var manual = false
    @State private var duplicateID: String?
    var updatingID: String? = nil
    init(updatingID: String? = nil, initialProduct: LinkProduct = .transactions) {
        self.updatingID = updatingID; _product = State(initialValue: initialProduct)
    }
    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Image(systemName: "building.columns.circle").font(.system(size: 58, weight: .ultraLight)).foregroundStyle(Palette.forest).padding(.top, 20)
                    Text(updatingID == nil ? "A clearer view\nstarts here." : "Welcome back.").font(.system(size: 34, design: .serif))
                    Text("Connect test accounts securely through Plaid Sandbox. Bank passwords go directly to Plaid; your access token stays in this device’s Keychain.").font(.subheadline).foregroundStyle(Palette.secondary)
                    if updatingID == nil {
                        Picker("Account data", selection: $product) { ForEach(LinkProduct.allCases, id: \.self) { Text($0.title).tag($0) } }.pickerStyle(.menu)
                    }
                    Button { Task { await openLink(updating: updatingID ?? duplicateID) } } label: {
                        HStack { if busy { ProgressView().tint(.white) }; Text(updatingID != nil || duplicateID != nil ? "Reconnect existing bank" : "Connect with Plaid") }
                    }.buttonStyle(PrimaryButtonStyle()).disabled(busy || app.isSyncing)
                    if updatingID == nil && duplicateID == nil {
                        Button {
                            Task {
                                busy = true; defer { busy = false }
                                do {
                                    duplicateID = try await app.sandboxBank(product: product)
                                    if duplicateID == nil { dismiss() }
                                } catch { app.report(error) }
                            }
                        } label: { Label("Add Sandbox test bank instantly", systemImage: "testtube.2").font(.subheadline).frame(maxWidth: .infinity) }.disabled(busy || app.isSyncing)
                        Text("Uses a non-OAuth test institution with Plaid’s generated data. The normal Link button lets you test the login screens.").font(.caption).foregroundStyle(Palette.secondary)
                        Divider()
                        Button { manual = true } label: { Label("Add a manual account", systemImage: "square.and.pencil").font(.subheadline) }
                    }
                    if let notice = app.notice { Text(notice).font(.caption).foregroundStyle(Palette.forest) }
                }.padding(28)
            }.background(Palette.background).navigationTitle(updatingID == nil ? "Add account" : "Reconnect").navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) } }
                .sheet(item: $session) { current in current.sheet().ignoresSafeArea() }
                .sheet(isPresented: $manual) { ManualAccountSheet(onSaved: { dismiss() }).appErrors() }
        }
    }
    private func openLink(updating: String?) async {
        busy = true; defer { busy = false }
        do {
            let selectedProduct = try updating.map { LinkProduct(rawValue: try app.findConnection($0).product) ?? .transactions } ?? product
            let token = try await app.createLinkToken(product: selectedProduct, updating: updating)
            let config = LinkTokenConfiguration(token: token, onSuccess: { success in
                Task { @MainActor in
                    session = nil; busy = true; defer { busy = false }
                    do {
                        duplicateID = try await app.finishLink(publicToken: success.publicToken, institutionID: success.metadata.institution.id, name: success.metadata.institution.name, masks: success.metadata.accounts.compactMap(\.mask), product: selectedProduct, updating: updating)
                        if duplicateID == nil { dismiss() }
                    } catch { app.report(error) }
                }
            }, onExit: { exit in
                Task { @MainActor in
                    session = nil
                    if let error = exit.error { app.errorMessage = error.displayMessage ?? "Plaid Link closed with an error. Try opening a new connection session." }
                }
            }, onEvent: nil, onLoad: nil)
            session = try Plaid.createPlaidLinkSession(configuration: config)
        } catch { app.report(error) }
    }
}

struct ManualAccountSheet: View {
    @SwiftUI.Environment(\.modelContext) private var context
    @SwiftUI.Environment(\.dismiss) private var dismiss
    @SwiftUI.Environment(AppState.self) private var app
    @State private var name = ""
    @State private var kind: AccountKind = .checking
    @State private var balance = ""
    var onSaved: () -> Void = {}
    init(initialName: String = "", initialKind: AccountKind = .checking, onSaved: @escaping () -> Void = {}) {
        _name = State(initialValue: initialName); _kind = State(initialValue: initialKind); self.onSaved = onSaved
    }
    var body: some View {
        NavigationStack {
            Form {
                Section("Account") {
                    TextField("Name", text: $name)
                    Picker("Type", selection: $kind) { ForEach(AccountKind.allCases, id: \.self) { Text($0.title).tag($0) } }
                    TextField("Current balance", text: $balance).keyboardType(.decimalPad)
                }
                Section { Text("Enter the amount owed as a positive balance for cards and loans. Transactions do not automatically change a manual account’s balance; reconcile the balance here.").font(.caption).foregroundStyle(Palette.secondary) }
            }.navigationTitle("Manual account")
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                    ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty || Money.decimal(balance) == nil) }
                }
        }
    }
    private func save() {
        guard let amount = Money.decimal(balance) else { return }
        do {
            let account = AccountRecord(name: name.trimmingCharacters(in: .whitespaces), kind: kind, balance: amount)
            context.insert(account)
            if kind == .loan { context.insert(LoanRecord(accountID: account.id, servicer: name, borrower: name.localizedCaseInsensitiveContains("parent") ? "Dad" : "Me")) }
            try AppPersistence.snapshots(context)
            dismiss(); onSaved()
        } catch { context.rollback(); app.report(error) }
    }
}

struct AccountDetailView: View {
    @Bindable var account: AccountRecord
    @SwiftUI.Environment(\.modelContext) private var context
    @SwiftUI.Environment(AppState.self) private var app
    @Query(sort: \TransactionRecord.date, order: .reverse) private var transactions: [TransactionRecord]
    @Query private var categories: [CategoryRecord]
    @Query(sort: \SnapshotRecord.date) private var snapshots: [SnapshotRecord]
    @State private var importCSV = false
    @State private var editingBalance = false
    @State private var balanceText = ""
    @State private var range = "1M"
    private var history: [SnapshotRecord] {
        let months = range == "1M" ? 1 : range == "3M" ? 3 : 12
        let cutoff = LedgerDate.shifting(.now, months: -months)
        return snapshots.filter { $0.accountID == account.id && (range == "All" || $0.date >= cutoff) }
    }
    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 16) {
                    AmountText(amount: account.balance, currency: account.currency).font(.system(size: 36, design: .rounded))
                    Picker("History", selection: $range) { ForEach(["1M", "3M", "1Y", "All"], id: \.self) { Text($0) } }.pickerStyle(.segmented)
                    if !history.isEmpty {
                        Chart(history) { point in LineMark(x: .value("Day", point.date), y: .value("Balance", Money.double(point.balance))).foregroundStyle(Palette.forest) }.frame(height: 150)
                    }
                    Text(account.source == "plaid" ? "Latest balance reported by Plaid" : "Manually reconciled balance").font(.caption).foregroundStyle(Palette.secondary)
                }.padding(.vertical, 10)
            }
            Section("Account settings") {
                TextField("Name", text: $account.name).onSubmit { app.save(context) }
                if account.source != "plaid" { Button("Reconcile balance") { balanceText = NSDecimalNumber(decimal: account.balance).stringValue; editingBalance = true } }
                Toggle("Exclude from budget", isOn: $account.hideFromBudget)
                Toggle("Exclude from cash flow", isOn: $account.hideFromCashFlow)
                Toggle("Exclude from net worth", isOn: $account.hideFromNetWorth)
                Toggle("Archived", isOn: $account.isArchived)
                if account.source != "plaid" { Button("Import CSV") { importCSV = true } }
            }
            Section("Transactions") {
                ForEach(transactions.filter { $0.accountID == account.id && !$0.isSplitParent }) { row in
                    NavigationLink { TransactionDetailView(transaction: row) } label: { EntryRow(transaction: row, category: categories.first { $0.id == row.categoryID }) }
                }
            }
        }.navigationTitle(account.name).navigationBarTitleDisplayMode(.inline)
            .onChange(of: account.hideFromBudget) { app.save(context) }
            .onChange(of: account.hideFromCashFlow) { app.save(context) }
            .onChange(of: account.hideFromNetWorth) { app.save(context) }
            .onChange(of: account.isArchived) { app.save(context) }
            .onDisappear { app.save(context) }
            .sheet(isPresented: $importCSV) { CSVImportView(account: account).appErrors() }
            .alert("Reconcile balance", isPresented: $editingBalance) {
                TextField("Balance", text: $balanceText).keyboardType(.decimalPad)
                Button("Save") {
                    guard let amount = Money.decimal(balanceText) else { app.errorMessage = "Enter a valid balance."; return }
                    account.balance = amount
                    do {
                        if let loan = try context.fetch(FetchDescriptor<LoanRecord>()).first(where: { $0.accountID == account.id }) { loan.lastReconciledAt = .now }
                        try AppPersistence.snapshots(context)
                    } catch { context.rollback(); app.report(error) }
                }
                Button("Cancel", role: .cancel) { }
            }
    }
}
