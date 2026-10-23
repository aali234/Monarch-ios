import SwiftUI
import SwiftData
import MonarchCore

struct EmailSettingsView: View {
    @Environment(AppState.self) private var app
    @Query private var accounts: [EmailAccountRecord]
    @State private var addingIMAP = false
    @State private var connecting = false
    @State private var disconnecting: EmailAccountRecord?
    @AppStorage("encryptReceiptFiles") private var encryptFiles = true
    @AppStorage("shipmentNotifications") private var notifications = false
    @AppStorage("shipmentLiveActivities") private var liveActivities = false
    var body: some View {
        Form {
            Section("Receipt email accounts") {
                ForEach(accounts) { account in
                    VStack(alignment: .leading, spacing: 8) {
                        Text(account.address).font(.subheadline.weight(.medium))
                        Text(account.provider.uppercased() + " · " + account.status).font(.caption).foregroundStyle(Palette.secondary)
                        if let date = account.lastScannedAt { Text("Checked " + date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(Palette.secondary) }
                        Button("Disconnect", role: .destructive) { disconnecting = account }.font(.caption)
                    }
                }
                Button("Connect Gmail (read-only)") {
                    Task {
                        connecting = true; defer { connecting = false }
                        do { try await app.receipts.connectGmail() } catch { app.report(error) }
                    }
                }.disabled(connecting || app.receipts.isScanning)
                Button("Connect another account with IMAP") { addingIMAP = true }.disabled(connecting || app.receipts.isScanning)
                Button("Scan for new receipt emails") { Task { await app.receipts.scanEmails() } }.disabled(connecting || app.receipts.isScanning || app.receipts.isProcessing)
                if connecting || app.receipts.isScanning { HStack { ProgressView(); Text("Connecting or checking mail…").font(.caption) } }
                if let error = app.receipts.lastError { Text(error).font(.caption).foregroundStyle(Palette.orange) }
                Text("The first scan covers matching mail from the last 90 days. New messages are checked when you open the app and during best-effort background refresh. Mail goes directly between this phone and the provider; it never passes through the bank sync server.").font(.caption).foregroundStyle(Palette.secondary)
            }
            Section("Receipt files") {
                Toggle("Encrypt new receipt files in iCloud", isOn: $encryptFiles)
                Text("Encrypted originals and PDF copies open inside Monarch. Turn this off only if you want new files to be readable directly in Files. Existing receipts keep their original encryption setting. Include the receipt vault key in an encrypted backup before moving to another phone.").font(.caption).foregroundStyle(Palette.secondary)
            }
            Section("Delivery updates") {
                Toggle("Out-for-delivery notification", isOn: Binding(get: { notifications }, set: { enabled in
                    if !enabled { notifications = false; return }
                    Task { do { notifications = try await ShipmentAlerts.requestNotifications() } catch { app.report(error) } }
                }))
                Toggle("Delivery Live Activity", isOn: $liveActivities)
                Text("Delivery updates depend on the carrier lookup and background opportunities. Live Activities show the merchant and carrier on the Lock Screen. No receipt total is included.").font(.caption).foregroundStyle(Palette.secondary)
            }
        }.navigationTitle("Receipts & email").navigationBarTitleDisplayMode(.inline)
            .sheet(isPresented: $addingIMAP) { IMAPConnectSheet().appErrors() }
            .confirmationDialog("Disconnect this email account? Saved receipts will remain.", isPresented: Binding(get: { disconnecting != nil }, set: { if !$0 { disconnecting = nil } }), titleVisibility: .visible) {
                Button("Disconnect", role: .destructive) {
                    guard let account = disconnecting else { return }
                    do { try app.receipts.disconnect(account); disconnecting = nil } catch { app.report(error) }
                }
            }
    }
}

private struct IMAPConnectSheet: View {
    @Environment(AppState.self) private var app
    @Environment(\.dismiss) private var dismiss
    @State private var address = ""
    @State private var host = ""
    @State private var username = ""
    @State private var mailbox = "INBOX"
    @State private var password = ""
    @State private var busy = false
    var body: some View {
        NavigationStack {
            Form {
                TextField("Email address", text: $address).keyboardType(.emailAddress).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("IMAP host, e.g. imap.mail.me.com", text: $host).keyboardType(.URL).textInputAutocapitalization(.never).autocorrectionDisabled()
                TextField("Username (defaults to address)", text: $username).textInputAutocapitalization(.never).autocorrectionDisabled()
                SecureField("App-specific password", text: $password).textInputAutocapitalization(.never)
                TextField("Mailbox", text: $mailbox).textInputAutocapitalization(.never)
                LabeledContent("Connection", value: "TLS · port 993 · read-only scans")
                Text("Generate an app password in your mail provider’s account settings. The password is stored only in this device’s Keychain. Monarch uses EXAMINE and BODY.PEEK so receipts are not marked read.").font(.caption).foregroundStyle(Palette.secondary)
                if busy { ProgressView("Connecting securely…") }
            }.navigationTitle("Connect IMAP").toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { password = ""; dismiss() }.disabled(busy) }
                ToolbarItem(placement: .confirmationAction) { Button("Connect") {
                    Task {
                        busy = true; defer { busy = false; password = "" }
                        do { try await app.receipts.connectIMAP(address: address, host: host, username: username.isEmpty ? address : username, password: password, mailbox: mailbox); dismiss() }
                        catch { app.report(error) }
                    }
                }.disabled(busy || !address.contains("@") || host.isEmpty || password.isEmpty || mailbox.isEmpty) }
            }
        }
    }
}
