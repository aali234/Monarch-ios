import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import MonarchCore

struct CSVImportView: View {
    let account: AccountRecord
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(AppState.self) private var app
    @State private var picking = false
    @State private var document: CSVDocument?
    @State private var mapping = CSVMapping()
    @State private var preview: [EntryValue] = []
    @State private var busy = false
    @State private var validationMessage: String?
    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text(account.name).font(.headline)
                    Button("Choose a CSV file") { picking = true }
                }
                if let document {
                    Section("Map columns") {
                        columnPicker("Date", index: $mapping.dateColumn, document: document)
                        columnPicker("Description", index: $mapping.descriptionColumn, document: document)
                        columnPicker("Amount", index: $mapping.amountColumn, document: document)
                        Picker("Date format", selection: $mapping.dateFormat) {
                            Text("2026-10-22").tag("yyyy-MM-dd")
                            Text("10/22/2026").tag("MM/dd/yyyy")
                            Text("10/22/26").tag("MM/dd/yy")
                            Text("22/10/2026").tag("dd/MM/yyyy")
                        }
                        Toggle("Positive amounts are money out", isOn: $mapping.positiveIsOutflow)
                        Button("Validate & preview \(document.rows.count) rows") { Task { await validate() } }.disabled(busy)
                    }
                }
                if let validationMessage { Section { Text(validationMessage).font(.caption).foregroundStyle(Palette.orange) } }
                if !preview.isEmpty {
                    Section("Preview · \(preview.count) rows") {
                        ForEach(Array(preview.prefix(8))) { row in HStack { Text(row.merchant); Spacer(); AmountText(amount: row.amount) }.font(.caption) }
                    }
                    Section { Button("Import \(preview.count) rows") {
                        Task {
                            busy = true; defer { busy = false }
                            do {
                                let count = try await app.writer.importCSV(preview, accountID: account.id, mapping: mapping)
                                app.notice = "Imported \(count) transactions · \(preview.count - count) duplicates skipped"
                                dismiss()
                            } catch { app.report(error) }
                        }
                    }.disabled(busy) }
                }
                if busy { ProgressView() }
            }.navigationTitle("Import CSV").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(busy) } }
                .onChange(of: mapping.dateColumn) { preview = [] }
                .onChange(of: mapping.descriptionColumn) { preview = [] }
                .onChange(of: mapping.amountColumn) { preview = [] }
                .onChange(of: mapping.dateFormat) { preview = [] }
                .onChange(of: mapping.positiveIsOutflow) { preview = [] }
                .onAppear {
                    do {
                        if let saved = try context.fetch(FetchDescriptor<ImportProfileRecord>()).first(where: { $0.accountID == account.id }) { mapping = try JSONDecoder().decode(CSVMapping.self, from: saved.mappingData) }
                    } catch { app.report(error) }
                }
                .fileImporter(isPresented: $picking, allowedContentTypes: [.commaSeparatedText, .plainText]) { result in
                    do {
                        let url = try result.get()
                        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                        let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                        guard size <= 10 * 1024 * 1024 else { throw CSVError.tooLarge }
                        let data = try Data(contentsOf: url)
                        guard let text = String(data: data, encoding: .utf8) else { throw CSVError.malformed }
                        preview = []; validationMessage = nil
                        Task {
                            busy = true; defer { busy = false }
                            do { document = try await Task.detached { try CSVDocument(text: text) }.value }
                            catch { app.report(error) }
                        }
                    } catch { app.report(error) }
                }
        }
    }
    private func columnPicker(_ title: String, index: Binding<Int>, document: CSVDocument) -> some View {
        Picker(title, selection: index) { ForEach(document.headers.indices, id: \.self) { Text(document.headers[$0]).tag($0) } }
    }
    private func validate() async {
        guard let document else { return }
        busy = true; defer { busy = false }
        let accountID = account.id, selectedMapping = mapping
        do {
            preview = try await Task.detached { try document.entries(accountID: accountID, mapping: selectedMapping) }.value
            validationMessage = nil
        } catch { preview = []; validationMessage = error.localizedDescription }
    }
}
