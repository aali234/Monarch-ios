import SwiftUI
import SwiftData
import UniformTypeIdentifiers
import MonarchCore

struct SettingsView: View {
    @Environment(AppState.self) private var app
    @Query private var connections: [InstitutionRecord]
    @State private var url = ""
    @State private var key = ""
    @State private var checking = false
    @State private var adding = false
    var body: some View {
        Form {
            Section("Plaid Sandbox") {
                TextField("Proxy URL", text: $url).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("App key (leave blank to keep saved key)", text: $key).textInputAutocapitalization(.never).autocorrectionDisabled()
                Button("Save & test connection") { Task { await configure() } }.disabled(checking || app.isSyncing)
                if checking { HStack { ProgressView(); Text("Waking sync server…").font(.caption) } }
                if let health = app.serverHealth {
                    Label("\(health.environment.capitalized) server is reachable", systemImage: "checkmark.circle.fill").font(.caption).foregroundStyle(Palette.forest)
                }
                Text("On the iPhone simulator, use http://127.0.0.1:8000 for a proxy running on the same Mac. Remote servers require HTTPS. The Plaid client ID and secret belong only in the proxy’s environment.").font(.caption).foregroundStyle(Palette.secondary)
            }.disabled(app.isSyncing)
            Section("Connections") {
                ForEach(connections) { connection in
                    NavigationLink { ConnectionDetailView(connection: connection) } label: {
                        VStack(alignment: .leading, spacing: 5) {
                            Text(connection.name)
                            Text(connection.serverID == app.serverID ? connection.status : "Uses a different sync server").font(.caption).foregroundStyle(connection.status == "Reconnect required" ? Palette.orange : Palette.secondary)
                        }
                    }
                }
                Button("Connect a Sandbox account") { adding = true }.disabled(app.isSyncing)
                Button("Sync all connections") { Task { await app.sync() } }.disabled(app.isSyncing)
            }
            Section("Privacy") {
                NavigationLink("Receipt email & delivery settings") { EmailSettingsView() }
                Toggle("Face ID / device passcode lock", isOn: Binding(get: { app.faceIDEnabled }, set: { enabled in Task { await app.setProtection(enabled) } }))
                Text("Locks at launch and after one minute in the background. In Simulator, enroll Face ID using Features → Face ID → Enrolled.").font(.caption).foregroundStyle(Palette.secondary)
                NavigationLink("Encrypted backup & restore") { BackupView() }
                Text("Financial records stay in a protected local SwiftData store. The sync server keeps no financial database. Bank tokens and app keys stay in Keychain.").font(.caption).foregroundStyle(Palette.secondary)
            }
            Section("This testing build") {
                LabeledContent("Environment", value: "Sandbox only")
                LabeledContent("Storage", value: "On this device")
                LabeledContent("AI network calls", value: "None")
                Text("This is the Sandbox testing milestone. Production bank linking, TestFlight signing, automatic iCloud backups, widgets, FinanceKit, and the on-device AI assistant are not enabled yet.").font(.caption).foregroundStyle(Palette.secondary)
                Link("Plaid Sandbox test credentials", destination: URL(string: "https://plaid.com/docs/sandbox/test-credentials/")!)
            }
        }.navigationTitle("Settings").navigationBarTitleDisplayMode(.inline)
            .onAppear { url = app.proxyURL }
            .sheet(isPresented: $adding) { AddAccountSheet().appErrors() }
    }
    private func configure() async {
        checking = true; defer { checking = false }
        do {
            let validated = try ProxyClient.validatedURL(url.trimmingCharacters(in: .whitespacesAndNewlines))
            app.proxyURL = validated.absoluteString.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            if !key.isEmpty { try app.saveKey(key.trimmingCharacters(in: .whitespacesAndNewlines)); key = "" }
            let health = try await app.client().health()
            guard health.environment == "sandbox" else { throw ProxyError(errorCode: "SANDBOX_REQUIRED", message: "This build uses a Sandbox sync server.") }
            struct OK: Decodable, Sendable { var ok: Bool }
            let _: OK = try await app.client().post("session/check", body: [:])
            app.serverHealth = health
            try app.recoverPendingConnection()
            app.notice = health.configured ? "Sandbox server and app key are ready. Add a test bank to begin." : "Server connected. Add Plaid Sandbox credentials to enable bank linking; receipt features work independently."
        } catch { app.report(error) }
    }
}

private struct ConnectionDetailView: View {
    let connection: InstitutionRecord
    @Environment(AppState.self) private var app
    @State private var reconnecting = false
    @State private var busy = false
    var body: some View {
        Form {
            Section("Connection") {
                LabeledContent("Bank", value: connection.name)
                LabeledContent("Status", value: connection.status)
                LabeledContent("Product", value: LinkProduct(rawValue: connection.product)?.title ?? connection.product)
                if let date = connection.lastSyncedAt { LabeledContent("Last sync", value: date.formatted(date: .abbreviated, time: .shortened)) }
                Text("Item: " + connection.itemID).font(.caption2).textSelection(.enabled)
                Button("Sync now") { Task { await app.sync(connectionID: connection.id) } }
                Button("Reconnect (update existing Item)") { reconnecting = true }
            }.disabled(app.isSyncing || busy || connection.serverID != app.serverID)
            if connection.serverID == app.serverID {
                Section("Sandbox test controls") {
                    if connection.product == "transactions" { Button("Generate the next transaction update") { sandboxAction("sandbox/transactions/refresh") } }
                    Button("Simulate a broken bank login") { sandboxAction("sandbox/item/reset-login") }
                    Text("After resetting the login, use Reconnect. Update mode retains the same Item and access token. If history is still preparing, pull to refresh again shortly.").font(.caption).foregroundStyle(Palette.secondary)
                }.disabled(busy || app.isSyncing)
            } else {
                Text("Switch to this connection’s original proxy URL in Settings before syncing or reconnecting.").font(.caption).foregroundStyle(Palette.orange)
            }
            Section { Text("Connections are kept locally. This app does not call Plaid’s Item removal API. Archiving an account hides it from current balances while preserving its transaction history.").font(.caption).foregroundStyle(Palette.secondary) }
        }.navigationTitle(connection.name).navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $reconnecting) { AddAccountSheet(updatingID: connection.id).appErrors() }
    }
    private func sandboxAction(_ path: String) {
        Task {
            busy = true; defer { busy = false }
            do { try await app.sandboxAction(path, connection: connection) }
            catch { app.report(error) }
        }
    }
}

private struct BackupView: View {
    @Environment(\.modelContext) private var context
    @Environment(AppState.self) private var app
    @State private var passphrase = ""
    @State private var confirmation = ""
    @State private var includeReceiptFiles = true
    @State private var file: EncryptedBackupFile?
    @State private var exporting = false
    @State private var importing = false
    @State private var busy = false
    var body: some View {
        Form {
            Section("Encrypted export") {
                SecureField("Passphrase (12+ characters)", text: $passphrase)
                SecureField("Confirm passphrase", text: $confirmation)
                Toggle("Include receipt file data", isOn: $includeReceiptFiles)
                Button("Create encrypted backup") { Task { await export() } }.disabled(busy || passphrase.count < 12 || passphrase != confirmation || app.isSyncing)
                Text("Choose iCloud Drive to save an encrypted copy. The receipt vault key and up to 25 MB of receipt files are included. Bank tokens, email credentials, and the proxy app key are excluded. Keep the passphrase safe; there is no reset.").font(.caption).foregroundStyle(Palette.secondary)
                if !includeReceiptFiles { Text("Without file data, all receipt originals must have finished uploading to iCloud. The backup still contains their links and encryption key.").font(.caption).foregroundStyle(Palette.secondary) }
            }
            Section("Restore") {
                Button("Choose a backup to restore") { importing = true }.disabled(busy || passphrase.isEmpty || app.isSyncing)
                Text("Enter the backup’s passphrase above. Restore requires an empty ledger and never replaces existing financial records. Connections restored to a new device cannot sync without their original Keychain tokens.").font(.caption).foregroundStyle(Palette.secondary)
            }
            if busy { ProgressView("Working securely…") }
        }.navigationTitle("Backup & restore").navigationBarTitleDisplayMode(.inline)
            .fileExporter(isPresented: $exporting, document: file, contentType: .monarchBackup, defaultFilename: "Monarch-\(LedgerDate.string(.now))") { result in
                switch result { case .success: app.notice = "Encrypted backup saved."; case .failure(let error): app.report(error) }
                file = nil; passphrase = ""; confirmation = ""
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.monarchBackup, .data]) { result in
                do {
                    let url = try result.get()
                    let access = url.startAccessingSecurityScopedResource(); defer { if access { url.stopAccessingSecurityScopedResource() } }
                    let size = try url.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
                    guard size <= 50 * 1024 * 1024 else { throw BackupFailure.invalidFile }
                    let data = try Data(contentsOf: url), password = passphrase
                    Task {
                        busy = true; defer { busy = false; passphrase = ""; confirmation = "" }
                        do {
                            let archive = try await Task.detached { try BackupService.decrypt(data, passphrase: password) }.value
                            try await BackupService.restore(archive, into: context)
                            app.notice = "Ledger restored. Bank tokens remain in the original device’s Keychain."
                        } catch { app.report(error) }
                    }
                } catch { app.report(error) }
            }
    }
    private func export() async {
        busy = true; defer { busy = false }
        do {
            let archive = try await BackupService.capture(context, includeReceiptFiles: includeReceiptFiles), password = passphrase
            let encrypted = try await Task.detached { try BackupService.encrypt(archive, passphrase: password) }.value
            file = EncryptedBackupFile(data: encrypted); exporting = true
        } catch { app.report(error) }
    }
}
