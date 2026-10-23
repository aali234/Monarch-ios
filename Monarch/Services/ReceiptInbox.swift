import Foundation
import SwiftData
import Observation
import CryptoKit
import BackgroundTasks
import MonarchCore

@MainActor @Observable final class ReceiptInbox {
    let container: ModelContainer
    let vault: ReceiptVault
    let authorization = GmailAuthorization()
    var isProcessing = false
    var isScanning = false
    var isRefreshingShipments = false
    var message = ""
    var lastError: String?
    private var lastForegroundRun: Date?
    init(container: ModelContainer, vault: ReceiptVault = ReceiptVault()) { self.container = container; self.vault = vault }

    @discardableResult func importFile(_ url: URL, source: ReceiptSource = .file, transactionID: String? = nil) async throws -> String {
        let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
        let input = try ReceiptDocumentReader.input(url: url)
        return try await ingest([input], source: source, transactionID: transactionID)
    }
    @discardableResult func ingest(_ input: [ReceiptInputFile], source: ReceiptSource, sourceMessageID: String? = nil, transactionID: String? = nil) async throws -> String {
        guard !isProcessing else { throw ProxyError(errorCode: "IMPORT_BUSY", message: "Another receipt is being processed. Try again when it finishes.") }
        isProcessing = true; message = "Reading receipt on this device…"
        defer { isProcessing = false; message = "" }
        let context = container.mainContext
        let hashes = input.map { SHA256.hash(data: $0.data).map { String(format: "%02x", $0) }.joined() }
        let existing = try context.fetch(FetchDescriptor<ReceiptRecord>())
        if let duplicate = existing.first(where: { record in
            let value = record.value
            return (sourceMessageID.map { value.sourceMessageIDs.contains($0) } ?? false) || hashes.contains { value.contentHashes.contains($0) }
        }) { return duplicate.id }
        let read = try await Task.detached { try await ReceiptDocumentReader.read(input) }.value
        try Task.checkCancellation()
        let parsed = read.parsed
        let sameOrder = existing.first { record in
            let value = record.value
            return !parsed.orderNumber.isEmpty && value.orderNumber == parsed.orderNumber &&
                ReceiptMatcher.normalizeMerchant(value.merchant) == ReceiptMatcher.normalizeMerchant(parsed.merchant)
        }
        var receipt = sameOrder?.value ?? ReceiptValue(source: source, merchant: parsed.merchant, orderNumber: parsed.orderNumber, date: parsed.date ?? .now, subtotal: parsed.subtotal, tax: parsed.tax, total: parsed.total, currency: parsed.currency, lineItems: parsed.lineItems, extractedText: read.text, dateIsEstimated: parsed.date == nil)
        if sameOrder != nil {
            if receipt.total == nil { receipt.total = parsed.total; receipt.currency = parsed.currency }
            receipt.subtotal = receipt.subtotal ?? parsed.subtotal; receipt.tax = receipt.tax ?? parsed.tax
            if receipt.lineItems.isEmpty { receipt.lineItems = parsed.lineItems }
            receipt.extractedText = String((receipt.extractedText + "\n" + read.text).prefix(100_000))
        }
        if let sourceMessageID, !receipt.sourceMessageIDs.contains(sourceMessageID) { receipt.sourceMessageIDs.append(sourceMessageID) }
        receipt.contentHashes += hashes.filter { !receipt.contentHashes.contains($0) }
        let encrypt = UserDefaults.standard.object(forKey: "encryptReceiptFiles") as? Bool ?? true
        for file in read.files {
            let stored = try await vault.store(data: file.data, name: file.name, type: file.type, receiptID: receipt.id, date: receipt.date, role: file.role, encrypted: encrypt)
            receipt.files.append(stored)
        }
        if let transactionID { receipt.transactionID = transactionID; receipt.candidateTransactionIDs = []; receipt.suppressAutoMatch = false }
        else if receipt.transactionID == nil && !receipt.suppressAutoMatch { try match(&receipt, context: context) }
        var alerts: [(ShipmentValue, ShipmentStatus)] = []
        do {
            if let sameOrder { try sameOrder.apply(receipt) } else { context.insert(try ReceiptRecord(receipt)) }
            let shipments = try context.fetch(FetchDescriptor<ShipmentRecord>())
            for tracking in parsed.tracking {
                if let existing = shipments.first(where: { $0.trackingNumber == tracking.number }) {
                    var value = existing.value
                    if let status = TrackingDetector.status(from: read.text), value.status != .delivered {
                        let old = value.status; value.status = status; value.lastEvent = "Status from order email or receipt"
                        if status == .delivered { value.deliveredAt = read.messageDate ?? .now }
                        try existing.apply(value)
                        alerts.append((value, old))
                    }
                } else {
                    let status = TrackingDetector.status(from: read.text) ?? .labelCreated
                    let value = ShipmentValue(trackingNumber: tracking.number, carrier: tracking.carrier, receiptID: receipt.id, transactionID: receipt.transactionID, status: status, lastEvent: "Detected on receipt", trackingURL: tracking.url, deliveredAt: status == .delivered ? read.messageDate ?? .now : nil)
                    context.insert(try ShipmentRecord(value))
                    alerts.append((value, .labelCreated))
                }
            }
            try context.save()
        } catch { context.rollback(); throw error }
        if source != .email || (read.messageDate.map { Date.now.timeIntervalSince($0) < 86400 } ?? false) {
            for (shipment, old) in alerts { await ShipmentAlerts.updated(shipment, merchant: receipt.merchant, previous: old) }
        }
        return receipt.id
    }
    private func match(_ receipt: inout ReceiptValue, context: ModelContext) throws {
        switch ReceiptMatcher.match(receipt: receipt, entries: try context.fetch(FetchDescriptor<TransactionRecord>()).map(\.value), accounts: try context.fetch(FetchDescriptor<AccountRecord>()).map(\.value)) {
        case .exact(let id): receipt.transactionID = id; receipt.candidateTransactionIDs = []
        case .suggestions(let ids): receipt.candidateTransactionIDs = ids
        case .none: receipt.candidateTransactionIDs = []
        }
    }
    func rematch() throws {
        let context = container.mainContext
        let transactionIDs = Set(try context.fetch(FetchDescriptor<TransactionRecord>()).map(\.id))
        do {
            var receipts: [String: ReceiptValue] = [:]
            for record in try context.fetch(FetchDescriptor<ReceiptRecord>()) {
                var value = try record.decoded()
                if let linked = value.transactionID, !transactionIDs.contains(linked) { value.transactionID = nil }
                if let withdrawal = value.hsaWithdrawalID, !transactionIDs.contains(withdrawal) { value.hsaWithdrawalID = nil }
                value.candidateTransactionIDs.removeAll { !transactionIDs.contains($0) }
                if value.transactionID == nil && !value.suppressAutoMatch { try match(&value, context: context) }
                try record.apply(value); receipts[value.id] = value
            }
            for shipment in try context.fetch(FetchDescriptor<ShipmentRecord>()) {
                var state = try shipment.decoded()
                state.transactionID = receipts[state.receiptID]?.transactionID
                try shipment.apply(state)
            }
            try context.save()
        } catch { context.rollback(); throw error }
    }
    func foreground() async {
        guard !ProcessInfo.processInfo.arguments.contains("--ui-testing"), !isScanning, !isProcessing,
              lastForegroundRun.map({ Date.now.timeIntervalSince($0) >= 15 }) ?? true else { return }
        lastForegroundRun = .now
        await drainShareInbox()
        await scanEmails()
        do { try rematch() } catch { lastError = error.localizedDescription }
    }
    func drainShareInbox() async {
        guard let inbox = try? ReceiptSharedConfig.inboxURL(), let folders = try? FileManager.default.contentsOfDirectory(at: inbox, includingPropertiesForKeys: nil) else { return }
        for folder in folders {
            do {
                for url in try FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil) {
                    _ = try await importFile(url, source: .share)
                }
                try FileManager.default.removeItem(at: folder)
            } catch { lastError = error.localizedDescription; break }
        }
    }
    func connectGmail() async throws {
        let credential = try await authorization.authorize(), id = UUID().uuidString
        guard credential.refreshToken != nil else { throw MailFailure.needsReconnect }
        let profile = try await GmailAPI(accountID: id, credential: credential).profile()
        let context = container.mainContext
        guard !(try context.fetch(FetchDescriptor<EmailAccountRecord>())).contains(where: { $0.provider == "gmail" && $0.address.caseInsensitiveCompare(profile.emailAddress) == .orderedSame }) else {
            throw ProxyError(errorCode: "EMAIL_ALREADY_CONNECTED", message: "This Gmail account is already connected. Disconnect it first if access needs renewing.")
        }
        try credential.save(id)
        context.insert(EmailAccountRecord(id: id, provider: "gmail", address: profile.emailAddress, oauthClientID: credential.clientID ?? ""))
        do { try context.save() } catch { context.rollback(); try? SecureStore.delete(EmailCredential.key(id)); throw error }
        await scanEmails()
    }
    func connectIMAP(address: String, host: String, username: String, password: String, mailbox: String) async throws {
        let client = try IMAPSession(host: host)
        do { _ = try await client.open(username: username, password: password, mailbox: mailbox) }
        catch { await client.close(); throw error }
        await client.close()
        let context = container.mainContext
        guard !(try context.fetch(FetchDescriptor<EmailAccountRecord>())).contains(where: { $0.provider == "imap" && $0.address.caseInsensitiveCompare(address) == .orderedSame && $0.host == host && $0.mailbox == mailbox }) else { throw ProxyError(errorCode: "EMAIL_ALREADY_CONNECTED", message: "This mailbox is already connected.") }
        let account = EmailAccountRecord(provider: "imap", address: address, host: host, username: username, mailbox: mailbox)
        try EmailCredential(appPassword: password, imapHost: host.lowercased(), imapUsername: username).save(account.id)
        context.insert(account)
        do { try context.save() } catch { context.rollback(); try? SecureStore.delete(EmailCredential.key(account.id)); throw error }
        await scanEmails()
    }
    func disconnect(_ account: EmailAccountRecord) throws {
        guard !isScanning else { throw ProxyError(errorCode: "MAIL_BUSY", message: "Wait for the email scan to finish.") }
        try SecureStore.delete(EmailCredential.key(account.id))
        container.mainContext.delete(account); try container.mainContext.save()
    }
    func scanEmails() async {
        guard !isScanning, !isProcessing else { return }
        isScanning = true; defer { isScanning = false; message = "" }
        let context = container.mainContext
        do {
            for account in try context.fetch(FetchDescriptor<EmailAccountRecord>()) {
                try Task.checkCancellation()
                message = "Checking receipt emails…"
                do {
                    let credential = try EmailCredential.load(account.id)
                    if account.provider == "gmail" {
                        let gmail = GmailAPI(accountID: account.id, credential: credential)
                        let batch = try await gmail.changes(historyID: account.historyID)
                        let seen = Set(try context.fetch(FetchDescriptor<ImportedMessageRecord>()).map(\.id))
                        for id in batch.ids where !seen.contains(account.id + ":" + id) {
                            try Task.checkCancellation()
                            if try await gmail.matchesReceipt(id), let raw = try await gmail.raw(id) { try await importMail(raw, accountID: account.id, messageID: id) }
                            context.insert(ImportedMessageRecord(accountID: account.id, messageID: id)); try context.save()
                        }
                        account.historyID = batch.checkpoint
                    } else {
                        guard let password = credential.appPassword, credential.imapHost == account.host.lowercased(), credential.imapUsername == account.username else { throw MailFailure.needsReconnect }
                        let client = try IMAPSession(host: account.host)
                        do {
                            let state = try await client.open(username: account.username, password: password, mailbox: account.mailbox)
                            let previous = state.validity == account.uidValidity ? account.lastUID.flatMap(UInt64.init) : nil
                            let maximum = state.nextUID.map { $0 > 0 ? $0 - 1 : 0 }
                            let ids = try await client.matchingUIDs(after: previous, through: maximum)
                            let seen = Set(try context.fetch(FetchDescriptor<ImportedMessageRecord>()).map(\.id))
                            for id in ids {
                                try Task.checkCancellation()
                                let identity = (state.validity ?? "unknown") + ":" + String(id)
                                if seen.contains(account.id + ":" + identity) { continue }
                                try await importMail(try await client.raw(id), accountID: account.id, messageID: identity)
                                context.insert(ImportedMessageRecord(accountID: account.id, messageID: identity)); try context.save()
                            }
                            account.uidValidity = state.validity
                            account.lastUID = maximum.map(String.init) ?? ids.last.map(String.init) ?? account.lastUID
                            await client.close()
                        } catch { await client.close(); throw error }
                    }
                    account.lastScannedAt = .now; account.status = "Connected"; try context.save()
                } catch {
                    context.rollback()
                    account.status = error is CancellationError ? "Scan paused" : "Needs attention"
                    try? context.save(); lastError = error.localizedDescription
                }
            }
        } catch { lastError = error.localizedDescription }
    }
    private func importMail(_ data: Data, accountID: String, messageID: String) async throws {
        let mail = try MIMEReader.parse(data)
        let parsed = ReceiptParser.parse("Subject: " + mail.subject + "\n" + mail.plainText)
        // Keyword-only newsletters remain checkpointed without becoming empty receipts.
        guard parsed.total != nil || !parsed.orderNumber.isEmpty || !parsed.tracking.isEmpty || !mail.attachments.isEmpty else { return }
        _ = try await ingest([ReceiptInputFile(data: data, name: "receipt-email.eml", type: "public.email-message")], source: .email, sourceMessageID: accountID + ":" + messageID)
    }
    static func scheduleBackgroundRefresh() {
        let request = BGAppRefreshTaskRequest(identifier: ReceiptSharedConfig.refreshTaskID)
        request.earliestBeginDate = .now.addingTimeInterval(2 * 3600)
        try? BGTaskScheduler.shared.submit(request)
    }
}
