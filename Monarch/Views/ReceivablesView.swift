import SwiftUI
import SwiftData
import UIKit
import MonarchCore

struct ReceivablesView: View {
    @Query(sort: \PersonRecord.name) private var people: [PersonRecord]
    @Query private var receivables: [ReceivableRecord]
    @State private var addingPerson = false
    @State private var addingIOU = false
    var body: some View {
        ScrollView {
            VStack(spacing: 20) {
                Card {
                    Text("MONEY OWED TO YOU").font(.system(size: 10, weight: .semibold)).tracking(2).foregroundStyle(Palette.secondary)
                    AmountText(amount: receivables.reduce(0) { $0 + $1.value.remaining }).font(.system(size: 38, design: .rounded)).padding(.top, 10)
                    Text("Shared costs, with a little less chasing.").font(.caption).foregroundStyle(Palette.secondary)
                }
                ForEach(people) { person in
                    NavigationLink { PersonDetailView(person: person) } label: {
                        Card {
                            HStack(spacing: 14) {
                                Text(String(person.name.prefix(1))).font(.title2).frame(width: 45, height: 45).background(Palette.mint, in: Circle())
                                VStack(alignment: .leading, spacing: 4) {
                                    Text(person.name).font(.headline)
                                    let count = receivables.filter { $0.personID == person.id && $0.value.remaining > 0 }.count
                                    Text("\(count) open item\(count == 1 ? "" : "s")").font(.caption).foregroundStyle(Palette.secondary)
                                }
                                Spacer()
                                AmountText(amount: receivables.filter { $0.personID == person.id }.reduce(0) { $0 + $1.value.remaining }).font(.headline)
                            }
                        }
                    }.buttonStyle(.plain)
                }
                if people.isEmpty { EmptyCard(title: "Keep track, keep it simple", message: "Add a person, then mark a transaction as shared or record a manual IOU.", symbol: "person.2") }
                Button("Add a manual IOU") { addingIOU = true }.buttonStyle(PrimaryButtonStyle())
                Button("Add a person") { addingPerson = true }.font(.subheadline)
            }.padding(20)
        }.background(Palette.background).navigationTitle("To collect").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $addingPerson) { PersonEditor().appErrors() }
            .sheet(isPresented: $addingIOU) { ReceivableEditor().appErrors() }
    }
}

private struct PersonDetailView: View {
    @Bindable var person: PersonRecord
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app
    @Query(sort: \ReceivableRecord.createdAt) private var receivables: [ReceivableRecord]
    @Query(sort: \TransactionRecord.date, order: .reverse) private var transactions: [TransactionRecord]
    @State private var editing = false
    @State private var selected: ReceivableRecord?
    @State private var paymentText = ""
    @State private var showingPayment = false
    private var items: [ReceivableRecord] { receivables.filter { $0.personID == person.id } }
    private var open: [ReceivableRecord] { items.filter { $0.value.remaining > 0 } }
    private var message: String { ReceivableEngine.requestMessage(person: person.name, items: open.map(\.value)) }
    private var suggestions: [TransactionRecord] {
        let settled = Set(receivables.flatMap(\.settlementIDs))
        return transactions.filter { transaction in
            transaction.amount > 0 && !transaction.isPending && !transaction.isSplitParent && !settled.contains(transaction.id) &&
            person.aliases.contains { !$0.isEmpty && transaction.originalDescription.localizedCaseInsensitiveContains($0) }
        }
    }
    var body: some View {
        List {
            Section {
                AmountText(amount: open.reduce(0) { $0 + $1.value.remaining }).font(.system(size: 36, design: .rounded)).padding(.vertical, 10)
                if person.credit > 0 { Text("Credit for future items: \(Money.format(person.credit))").font(.caption).foregroundStyle(Palette.forest) }
                if !open.isEmpty {
                    Button("Copy request message") { UIPasteboard.general.string = message; markRequested() }
                    ShareLink(item: message) { Label("Share request", systemImage: "square.and.arrow.up") }.simultaneousGesture(TapGesture().onEnded { markRequested() })
                }
            }
            if !suggestions.isEmpty && !open.isEmpty {
                Section("Possible repayments · confirm before applying") {
                    ForEach(suggestions) { transaction in
                        Button {
                            settle(transaction)
                        } label: {
                            VStack(alignment: .leading, spacing: 6) {
                                HStack { Text(transaction.merchant); Spacer(); AmountText(amount: transaction.amount) }
                                Text("Apply oldest first; excess becomes a credit").font(.caption).foregroundStyle(Palette.secondary)
                            }
                        }
                    }
                }
            }
            Section("Open items") {
                ForEach(open) { item in
                    VStack(alignment: .leading, spacing: 8) {
                        HStack { Text(item.note).font(.subheadline.weight(.medium)); Spacer(); AmountText(amount: item.value.remaining).font(.subheadline) }
                        HStack {
                            Text(item.statusRaw.capitalized)
                            Text("· " + item.createdAt.formatted(date: .abbreviated, time: .omitted))
                            if item.amountPaid > 0 { Text("· \(Money.format(item.amountPaid)) paid") }
                        }.font(.caption2).foregroundStyle(Palette.secondary)
                        HStack {
                            Button("Record payment") { selected = item; paymentText = NSDecimalNumber(decimal: item.value.remaining).stringValue; showingPayment = true }
                            Spacer()
                            Button("Write off", role: .destructive) { item.statusRaw = "writtenOff"; app.save(context) }
                        }.font(.caption).buttonStyle(.borderless)
                    }.padding(.vertical, 8)
                }
                if open.isEmpty { Text("All settled up.").foregroundStyle(Palette.secondary) }
            }
            Section("Settled & written off") {
                ForEach(items.filter { $0.value.remaining == 0 }) { item in HStack { Text(item.note); Spacer(); Text(item.statusRaw == "writtenOff" ? "Written off" : "Paid").foregroundStyle(Palette.secondary) }.font(.caption) }
            }
        }.navigationTitle(person.name).toolbar { Button("Edit") { editing = true } }
            .sheet(isPresented: $editing) { PersonEditor(person: person).appErrors() }
            .alert("Record a payment", isPresented: $showingPayment) {
                TextField("Amount", text: $paymentText).keyboardType(.decimalPad)
                Button("Save") {
                    guard let selected, let amount = Money.decimal(paymentText) else { return }
                    do { selected.apply(try ReceivableEngine.payment(amount, to: selected.value)); try context.save() }
                    catch { context.rollback(); app.report(error) }
                }
                Button("Cancel", role: .cancel) { }
            } message: { Text("Use this for a repayment that has not been imported as a transaction.") }
    }
    private func markRequested() {
        for item in open {
            item.requestedAt = .now
            if item.amountPaid == 0 { item.statusRaw = "requested" }
        }
        app.save(context); app.notice = "Request recorded. You can send the copied message with your preferred app."
    }
    private func settle(_ transaction: TransactionRecord) {
        do {
            var amount = transaction.amount
            for item in open where amount > 0 {
                let paid = min(amount, item.value.remaining)
                item.apply(try ReceivableEngine.payment(paid, to: item.value, settlementID: transaction.id))
                amount -= paid
            }
            person.credit += amount
            transaction.categoryID = "reimbursement"; transaction.lock("category"); transaction.isReviewed = true
            try context.save()
        } catch { context.rollback(); app.report(error) }
    }
}

struct ReceivableEditor: View {
    var source: TransactionRecord? = nil
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @Query(sort: \PersonRecord.name) private var people: [PersonRecord]
    @Query private var receivables: [ReceivableRecord]
    @State private var personID = ""
    @State private var amountText = ""
    @State private var note = ""
    @State private var date = Date.now
    @State private var percentage = false
    @State private var addingPerson = false
    var body: some View {
        NavigationStack {
            Form {
                if let source { Section { Text(source.merchant); AmountText(amount: source.amount) } }
                Section("Who owes you?") {
                    Picker("Person", selection: $personID) { Text("Choose someone").tag(""); ForEach(people) { Text($0.name).tag($0.id) } }
                    Button("Add a person") { addingPerson = true }
                    if source != nil { Toggle("Enter a percentage", isOn: $percentage) }
                    TextField(percentage ? "Percentage owed (100 = all)" : "Amount owed", text: $amountText).keyboardType(.decimalPad)
                    TextField("What was it for?", text: $note)
                    if source == nil { DatePicker("Date", selection: $date, displayedComponents: .date) }
                }
                Text("Only your share of this charge counts as spending. Incoming reimbursements are excluded from income.").font(.caption).foregroundStyle(Palette.secondary)
            }.navigationTitle(source == nil ? "Add an IOU" : "Shared charge").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() }.disabled(personID.isEmpty || note.isEmpty || (Money.decimal(amountText) ?? 0) <= 0) }
            }.onAppear { if let source { note = source.merchant; date = source.date } }
                .sheet(isPresented: $addingPerson) { PersonEditor().appErrors() }
        }
    }
    private func save() {
        do {
            guard let input = Money.decimal(amountText), let person = people.first(where: { $0.id == personID }) else { throw ReceivableError.invalidAmount }
            let amount = percentage ? Money.rounded(abs(source?.amount ?? 0) * input / 100) : input
            let existing = source.map { source in receivables.filter { $0.sourceEntryID == source.id }.reduce(Decimal.zero) { $0 + ($1.statusRaw == "writtenOff" ? $1.amountPaid : $1.amount) } } ?? 0
            try ReceivableEngine.validate(amount: amount, charge: source?.amount, existing: existing)
            var value = ReceivableValue(personID: personID, sourceEntryID: source?.id, amount: amount, note: note, createdAt: date)
            let credit = min(person.credit, amount)
            if credit > 0 { value = try ReceivableEngine.payment(credit, to: value); person.credit -= credit }
            context.insert(ReceivableRecord(value)); source?.lock("shared")
            try context.save(); dismiss()
        } catch { context.rollback(); app.report(error) }
    }
}

private struct PersonEditor: View {
    var person: PersonRecord? = nil
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @State private var name = ""
    @State private var aliases = ""
    var body: some View {
        NavigationStack {
            Form {
                TextField("Name", text: $name)
                Section("Deposit aliases · one per line") { TextField("ZELLE FROM DAD", text: $aliases, axis: .vertical).lineLimit(3...8) }
                Text("Aliases are matched without regard to capitalization. Exact, unambiguous amounts settle automatically; other matches need your confirmation.").font(.caption).foregroundStyle(Palette.secondary)
            }.navigationTitle(person == nil ? "Add a person" : "Edit person").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") {
                    let parsed = aliases.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    if let person { person.name = name; person.aliases = parsed }
                    else { context.insert(PersonRecord(.init(name: name, aliases: parsed))) }
                    do { try context.save(); dismiss() } catch { context.rollback(); app.report(error) }
                }.disabled(name.trimmingCharacters(in: .whitespaces).isEmpty) }
            }.onAppear { if let person { name = person.name; aliases = person.aliases.joined(separator: "\n") } }
        }
    }
}
