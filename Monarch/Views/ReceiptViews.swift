import SwiftUI
import SwiftData
import VisionKit
import QuickLook
import UniformTypeIdentifiers
import MonarchCore

struct ReceiptsView: View {
    @Environment(AppState.self) private var app
    @Query(sort: \ReceiptRecord.date, order: .reverse) private var receipts: [ReceiptRecord]
    @State private var search = ""
    @State private var adding = false
    @State private var reviewOnly = false
    var body: some View {
        List {
            Section {
                Toggle("Needs review only", isOn: $reviewOnly)
                if app.receipts.isProcessing || app.receipts.isScanning { HStack { ProgressView(); Text(app.receipts.message).font(.caption) } }
                if let error = app.receipts.lastError { Text(error).font(.caption).foregroundStyle(Palette.orange) }
            }
            ForEach(receipts.filter { (!reviewOnly || $0.needsReview) && (search.isEmpty || $0.merchant.localizedCaseInsensitiveContains(search) || $0.orderNumber.localizedCaseInsensitiveContains(search)) }) { receipt in
                NavigationLink { ReceiptDetailView(record: receipt) } label: { ReceiptRow(receipt: receipt.value) }
            }
            if receipts.isEmpty { EmptyCard(title: "A home for every receipt", message: "Scan a paper receipt, import a file, or share from another app. Email connections are optional.", symbol: "doc.text.viewfinder") }
        }.navigationTitle("Receipts").navigationBarTitleDisplayMode(.inline).searchable(text: $search, prompt: "Merchant or order number")
            .toolbar { Button { adding = true } label: { Image(systemName: "plus") }.accessibilityLabel("Import receipt") }
            .sheet(isPresented: $adding) { ReceiptImportSheet().appErrors() }
            .refreshable { await app.receipts.foreground() }
    }
}

private struct ReceiptRow: View {
    let receipt: ReceiptValue
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: receipt.hsaEligible ? "cross.case" : "doc.text").foregroundStyle(Palette.forest).frame(width: 34)
            VStack(alignment: .leading, spacing: 4) {
                Text(receipt.merchant.isEmpty ? "Receipt to review" : receipt.merchant).font(.subheadline.weight(.medium))
                Text(receipt.date.formatted(date: .abbreviated, time: .omitted) + (receipt.needsReview ? " · Needs review" : "")).font(.caption).foregroundStyle(Palette.secondary)
                if receipt.transactionID != nil { Label("Transaction linked", systemImage: "link").font(.caption2).foregroundStyle(Palette.forest) }
            }
            Spacer()
            if let total = receipt.total { AmountText(amount: total, currency: receipt.currency).font(.subheadline) }
            else { Text("—").foregroundStyle(Palette.secondary) }
        }.padding(.vertical, 6)
    }
}

struct ReceiptImportSheet: View {
    var transactionID: String? = nil
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var filePicker = false
    @State private var scanner = false
    var body: some View {
        NavigationStack {
            List {
                Section {
                    EmptyCard(title: "Keep the proof, lose the paper", message: "Originals are preserved. Text extraction and receipt parsing happen on this device; you can edit every field before marking it reviewed.", symbol: "doc.text.viewfinder")
                }.listRowBackground(Color.clear)
                Section {
                    Button { scanner = true } label: { Label("Scan a paper receipt", systemImage: "camera.viewfinder") }.disabled(!VNDocumentCameraViewController.isSupported)
                    Button { filePicker = true } label: { Label("Import PDF, image, email, or text", systemImage: "folder") }
                    if !VNDocumentCameraViewController.isSupported { Text("The document camera needs a physical iPhone. Import a receipt image or PDF to test in Simulator.").font(.caption).foregroundStyle(Palette.secondary) }
                }.disabled(app.receipts.isProcessing || app.receipts.isScanning)
                if app.receipts.isProcessing { HStack { ProgressView(); Text(app.receipts.message).font(.caption) } }
            }.navigationTitle("Add a receipt").toolbar { ToolbarItem(placement: .cancellationAction) { Button("Close") { dismiss() }.disabled(app.receipts.isProcessing) } }
                .fileImporter(isPresented: $filePicker, allowedContentTypes: [.pdf, .image, .plainText, .html, UTType(filenameExtension: "eml") ?? .data]) { result in
                    Task { do { _ = try await app.receipts.importFile(result.get(), transactionID: transactionID); app.notice = "Receipt added. Open it to check the details."; dismiss() } catch { app.report(error) } }
                }
                .sheet(isPresented: $scanner) { ReceiptScanner { result in
                    scanner = false
                    Task {
                        do {
                            let files = try result.get().enumerated().map { index, data in ReceiptInputFile(data: data, name: "receipt-page-\(index + 1).jpg", type: UTType.jpeg.identifier) }
                            _ = try await app.receipts.ingest(files, source: .scan, transactionID: transactionID)
                            app.notice = "Scanned receipt added to review."; dismiss()
                        } catch { app.report(error) }
                    }
                } }
        }
    }
}

private struct ReceiptScanner: UIViewControllerRepresentable {
    var completion: (Result<[Data], Error>) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(completion: completion) }
    func makeUIViewController(context: Context) -> VNDocumentCameraViewController { let camera = VNDocumentCameraViewController(); camera.delegate = context.coordinator; return camera }
    func updateUIViewController(_ uiViewController: VNDocumentCameraViewController, context: Context) {}
    final class Coordinator: NSObject, VNDocumentCameraViewControllerDelegate {
        let completion: (Result<[Data], Error>) -> Void
        init(completion: @escaping (Result<[Data], Error>) -> Void) { self.completion = completion }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFinishWith scan: VNDocumentCameraScan) {
            guard scan.pageCount <= 20 else { completion(.failure(MailFailure.tooLarge)); return }
            completion(.success((0..<scan.pageCount).compactMap { scan.imageOfPage(at: $0).jpegData(compressionQuality: 0.92) }))
        }
        func documentCameraViewControllerDidCancel(_ controller: VNDocumentCameraViewController) { controller.dismiss(animated: true) }
        func documentCameraViewController(_ controller: VNDocumentCameraViewController, didFailWithError error: Error) { completion(.failure(error)) }
    }
}

struct ReceiptDetailView: View {
    let record: ReceiptRecord
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app
    @Query(sort: \TransactionRecord.date, order: .reverse) private var transactions: [TransactionRecord]
    @Query private var shipments: [ShipmentRecord]
    @State private var value: ReceiptValue
    @State private var total = ""
    @State private var subtotal = ""
    @State private var tax = ""
    @State private var preview: URL?
    @State private var saving = false
    @State private var trackingNumber = ""
    @State private var trackingURL = ""
    init(record: ReceiptRecord) { self.record = record; _value = State(initialValue: record.value) }
    var body: some View {
        Form {
            Section("Receipt details") {
                TextField("Merchant", text: $value.merchant)
                TextField("Order number", text: $value.orderNumber)
                DatePicker("Receipt date", selection: $value.date, displayedComponents: .date)
                if value.dateIsEstimated == true { Text("No receipt date was found. Check the purchase date before saving.").font(.caption).foregroundStyle(Palette.orange) }
                moneyField("Subtotal", text: $subtotal); moneyField("Tax", text: $tax); moneyField("Total", text: $total)
                Picker("Currency", selection: $value.currency) { ForEach(["USD", "CAD", "EUR", "GBP"], id: \.self) { Text($0) } }
            }
            Section("Line items") {
                ForEach($value.lineItems) { $line in
                    VStack(alignment: .leading) {
                        TextField("Item", text: $line.name)
                        HStack {
                            Text("Quantity").font(.caption); TextField("1", value: $line.quantity, format: .number).keyboardType(.decimalPad)
                            Text("Line total").font(.caption); TextField("0", value: $line.amount, format: .number).keyboardType(.decimalPad)
                        }
                    }
                }.onDelete { value.lineItems.remove(atOffsets: $0) }
                Button("Add line item") { value.lineItems.append(.init(name: "", amount: 0)) }
            }
            Section("Transaction") {
                Picker("Linked purchase", selection: Binding(get: { value.transactionID ?? "" }, set: { value.transactionID = $0.isEmpty ? nil : $0; value.suppressAutoMatch = $0.isEmpty })) {
                    Text("Not linked").tag("")
                    ForEach(transactions.filter { $0.amount < 0 && !$0.isPending && !$0.isSplitParent && $0.parentID == nil }) { row in Text(row.merchant + " · " + Money.format(row.amount) + " · " + LedgerDate.string(row.date)).tag(row.id) }
                }
                if let row = transactions.first(where: { $0.id == value.transactionID }) { NavigationLink("Open transaction") { TransactionDetailView(transaction: row) } }
                if value.transactionID == nil {
                    ForEach(transactions.filter { value.candidateTransactionIDs.contains($0.id) }) { row in Button("Match \(row.merchant) · \(Money.format(row.amount))") { value.transactionID = row.id; value.candidateTransactionIDs = [] } }
                }
            }
            Section("Originals & copies") {
                ForEach(value.files) { file in
                    Button { Task { do { preview = try await app.receipts.vault.preview(file) } catch { app.report(error) } } } label: {
                        VStack(alignment: .leading, spacing: 4) {
                            Label(file.originalName, systemImage: file.role == "pdf" ? "doc.richtext" : "doc")
                            Text((file.location == "icloud" ? "iCloud Drive" : "Saved on this iPhone") + (file.encrypted ? " · Encrypted" : "")).font(.caption2).foregroundStyle(Palette.secondary)
                        }
                    }
                }
                if value.files.contains(where: { $0.location != "icloud" }) { Button("File originals in iCloud Drive") { Task { await fileInCloud() } } }
            }
            Section("Shipments") {
                ForEach(shipments.filter { $0.receiptID == record.id }) { shipment in Text(shipment.value.carrier.title + " · " + shipment.value.status.title + " · " + shipment.trackingNumber).font(.caption) }
                TextField("Add tracking number", text: $trackingNumber).textInputAutocapitalization(.characters).autocorrectionDisabled()
                TextField("Tracking link (optional, HTTPS)", text: $trackingURL).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
            }
            Section("HSA records") {
                if ReceiptParser.suggestsHSA(value.merchant) && !value.hsaEligible { Text("This may be a medical receipt. Confirm eligibility before adding it to your HSA records.").font(.caption).foregroundStyle(Palette.secondary) }
                Toggle("I confirm this receipt is HSA-eligible", isOn: $value.hsaEligible)
                    .onChange(of: value.hsaEligible) { _, enabled in value.hsaStatus = enabled ? .unreimbursed : .notApplicable; if !enabled { value.hsaReimbursedOn = nil; value.hsaWithdrawalID = nil } }
                if value.hsaEligible {
                    Picker("Status", selection: $value.hsaStatus) { Text("Unreimbursed").tag(HSAStatus.unreimbursed); Text("Reimbursed").tag(HSAStatus.reimbursed) }
                        .onChange(of: value.hsaStatus) { _, status in value.hsaReimbursedOn = status == .reimbursed ? value.hsaReimbursedOn ?? .now : nil; if status != .reimbursed { value.hsaWithdrawalID = nil } }
                    if value.hsaStatus == .reimbursed {
                        DatePicker("Reimbursed on", selection: Binding(get: { value.hsaReimbursedOn ?? .now }, set: { value.hsaReimbursedOn = $0 }), displayedComponents: .date)
                        Picker("HSA withdrawal (optional)", selection: Binding(get: { value.hsaWithdrawalID ?? "" }, set: { value.hsaWithdrawalID = $0.isEmpty ? nil : $0 })) {
                            Text("Not linked").tag("")
                            ForEach(transactions.filter { $0.amount < 0 && !$0.isPending && !$0.isSplitParent && $0.id != value.transactionID }) { row in Text(row.merchant + " · " + Money.format(row.amount)).tag(row.id) }
                        }
                    }
                    Text("Retain this receipt for your records. Eligibility is your decision; the app does not certify tax eligibility.").font(.caption).foregroundStyle(Palette.secondary)
                }
            }
            if !value.extractedText.isEmpty { Section("Extracted text") { DisclosureGroup("Read original text") { Text(value.extractedText).font(.caption).textSelection(.enabled) } } }
        }.navigationTitle("Receipt").navigationBarTitleDisplayMode(.inline)
            .toolbar { Button(saving ? "Saving…" : "Save & review") { Task { await save() } }.disabled(saving || value.merchant.trimmingCharacters(in: .whitespaces).isEmpty) }
            .onAppear { total = value.total.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""; subtotal = value.subtotal.map { NSDecimalNumber(decimal: $0).stringValue } ?? ""; tax = value.tax.map { NSDecimalNumber(decimal: $0).stringValue } ?? "" }
            .quickLookPreview($preview)
            .onChange(of: preview) { old, current in if current == nil, let old { try? FileManager.default.removeItem(at: old.deletingLastPathComponent()) } }
    }
    private func moneyField(_ title: String, text: Binding<String>) -> some View { LabeledContent(title) { TextField("Unknown", text: text).keyboardType(.decimalPad).multilineTextAlignment(.trailing) } }
    private func save() async {
        saving = true; defer { saving = false }
        do {
            for text in [total, subtotal, tax] where !text.isEmpty { guard let amount = Money.decimal(text), amount >= 0 else { throw ReceivableError.invalidAmount } }
            value.total = Money.decimal(total); value.subtotal = Money.decimal(subtotal); value.tax = Money.decimal(tax)
            if value.hsaEligible && (value.total ?? 0) <= 0 { throw ProxyError(errorCode: "HSA_AMOUNT_REQUIRED", message: "Enter the receipt total before adding it to HSA records.") }
            if !value.lineItems.allSatisfy({ $0.quantity > 0 && $0.amount >= 0 }) { throw ReceivableError.invalidAmount }
            if LedgerDate.string(record.date, format: "yyyy/MM") != LedgerDate.string(value.date, format: "yyyy/MM") {
                var moved: [ReceiptFile] = []
                for file in value.files {
                    let data = try await app.receipts.vault.read(file)
                    moved.append(try await app.receipts.vault.store(data: data, name: file.originalName, type: file.contentType, receiptID: value.id, date: value.date, role: file.role, encrypted: file.encrypted))
                }
                value.files = moved
            }
            if !trackingURL.isEmpty && TrackingDetector.safeURL(trackingURL) == nil { throw ProxyError(errorCode: "INVALID_TRACKING_URL", message: "Enter an HTTPS tracking link.") }
            if !trackingNumber.isEmpty || !trackingURL.isEmpty {
                let number = trackingNumber.isEmpty ? "LINK" + String(StableHash.sha256(trackingURL).prefix(24)) : TrackingDetector.normalize(trackingNumber)
                guard number.count >= 8 else { throw ProxyError(errorCode: "INVALID_TRACKING_NUMBER", message: "Check the tracking number and try again.") }
                if !shipments.contains(where: { $0.trackingNumber == number }) {
                    let carrier = TrackingDetector.carrier(number)
                    context.insert(try ShipmentRecord(ShipmentValue(trackingNumber: number, carrier: carrier, receiptID: value.id, transactionID: value.transactionID, trackingURL: trackingURL.isEmpty ? TrackingDetector.carrierURL(number: number, carrier: carrier)?.absoluteString : trackingURL)))
                }
            }
            value.needsReview = false; value.dateIsEstimated = false; try record.apply(value)
            for shipment in try context.fetch(FetchDescriptor<ShipmentRecord>()) where shipment.receiptID == record.id { var state = shipment.value; state.transactionID = value.transactionID; try shipment.apply(state) }
            try context.save(); trackingNumber = ""; trackingURL = ""; app.notice = "Receipt reviewed and saved."
        } catch { context.rollback(); app.report(error) }
    }
    private func fileInCloud() async {
        saving = true; defer { saving = false }
        do {
            var files: [ReceiptFile] = []
            for file in value.files { files.append(try await app.receipts.vault.fileToCloud(file)) }
            value.files = files; try record.apply(value); try context.save()
        } catch { context.rollback(); app.report(error) }
    }
}

struct TransactionReceiptsSection: View {
    let transactionID: String
    @Query private var receipts: [ReceiptRecord]
    @State private var adding = false
    var body: some View {
        Section("Receipts") {
            ForEach(receipts.filter { $0.transactionID == transactionID }) { receipt in
                NavigationLink { ReceiptDetailView(record: receipt) } label: { ReceiptRow(receipt: receipt.value) }
                ForEach(Array(receipt.value.lineItems.prefix(5))) { line in HStack { Text(line.name); Spacer(); AmountText(amount: line.amount, currency: receipt.value.currency) }.font(.caption).foregroundStyle(Palette.secondary) }
            }
            Button("Attach a receipt") { adding = true }
        }.sheet(isPresented: $adding) { ReceiptImportSheet(transactionID: transactionID).appErrors() }
    }
}

struct HSAView: View {
    @Environment(AppState.self) private var app
    @Query(sort: \ReceiptRecord.date, order: .reverse) private var receipts: [ReceiptRecord]
    @State private var year = Calendar.current.component(.year, from: .now)
    @State private var exporting = false
    @State private var exportFiles: [URL] = []
    @State private var sharing = false
    private var years: [Int] { Array(Set(receipts.map { Calendar.current.component(.year, from: $0.date) } + [Calendar.current.component(.year, from: .now)])).sorted(by: >) }
    var body: some View {
        List {
            Section {
                Picker("Year", selection: $year) { ForEach(years, id: \.self) { Text(String($0)).tag($0) } }
                Text("UNREIMBURSED · USD").font(.caption).foregroundStyle(Palette.secondary)
                AmountText(amount: HSAExport.unreimbursed(receipts.map(\.value), year: year)).font(.system(size: 34, design: .rounded))
                Text("Only receipts you confirmed as eligible are included. Reimbursed receipts stay in your records.").font(.caption).foregroundStyle(Palette.secondary)
                Button(exporting ? "Preparing export…" : "Export year: ZIP + CSV") { Task { await export() } }.disabled(exporting)
            }
            ForEach(receipts.filter { $0.hsaEligible && Calendar.current.component(.year, from: $0.date) == year }) { receipt in
                NavigationLink { ReceiptDetailView(record: receipt) } label: {
                    VStack(alignment: .leading, spacing: 4) { ReceiptRow(receipt: receipt.value); Text(receipt.hsaStatus == "reimbursed" ? "Reimbursed" : "Unreimbursed").font(.caption).foregroundStyle(Palette.secondary) }
                }
            }
        }.navigationTitle("HSA receipts").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $sharing) { ReceiptExportShare(files: exportFiles) }
    }
    private func export() async {
        exporting = true; defer { exporting = false }
        do { exportFiles = try await app.receipts.vault.exportHSA(receipts.map(\.value), year: year); sharing = true }
        catch { app.report(error) }
    }
}

struct ReceiptExportShare: UIViewControllerRepresentable {
    let files: [URL]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: files, applicationActivities: nil)
        controller.completionWithItemsHandler = { _, _, _, _ in
            if let folder = files.first?.deletingLastPathComponent() { try? FileManager.default.removeItem(at: folder) }
        }
        return controller
    }
    func updateUIViewController(_ uiViewController: UIActivityViewController, context: Context) {}
}
