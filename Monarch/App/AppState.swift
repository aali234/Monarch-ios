import Foundation
import SwiftData
import Observation
import LocalAuthentication
import MonarchCore

@MainActor @Observable final class AppState {
    let container: ModelContainer
    let writer: LedgerWriter
    let receipts: ReceiptInbox
    var selectedTab = 0
    var showingMenu = false
    var errorMessage: String?
    var notice: String?
    var syncMessage = ""
    var isSyncing = false
    var serverHealth: HealthResponse?
    var isLocked: Bool
    var isAuthenticating = false
    var lockMessage: String?
    var isObscured = false
    private var backgroundAt: Date?
    private var linking = false

    var proxyURL: String {
        didSet { UserDefaults.standard.set(proxyURL, forKey: "proxyURL"); serverHealth = nil }
    }
    var faceIDEnabled: Bool {
        didSet { UserDefaults.standard.set(faceIDEnabled, forKey: "faceIDEnabled") }
    }
    var serverID: String { StableHash.sha256(proxyURL.trimmingCharacters(in: CharacterSet(charactersIn: "/"))) }
    var clientUserID: String {
        if let saved = UserDefaults.standard.string(forKey: "clientUserID") { return saved }
        let id = UUID().uuidString
        UserDefaults.standard.set(id, forKey: "clientUserID"); return id
    }
    init(container: ModelContainer) {
        self.container = container; writer = LedgerWriter(modelContainer: container); receipts = ReceiptInbox(container: container)
        self.proxyURL = UserDefaults.standard.string(forKey: "proxyURL") ?? "http://127.0.0.1:8000"
        self.faceIDEnabled = UserDefaults.standard.bool(forKey: "faceIDEnabled")
        self.isLocked = UserDefaults.standard.bool(forKey: "faceIDEnabled")
    }

    func report(_ error: Error) { errorMessage = error.localizedDescription }
    func save(_ context: ModelContext) {
        do { try context.save() } catch { context.rollback(); report(error) }
    }
    func appKey() throws -> String { try SecureStore.string(for: "appKey.\(serverID)") ?? "" }
    func saveKey(_ key: String) throws { try SecureStore.set(key, for: "appKey.\(serverID)") }
    func tokenKey(itemID: String) -> String { "token.\(serverID).\(itemID)" }
    func client() throws -> ProxyClient {
        let url = try ProxyClient.validatedURL(proxyURL)
        let key = try appKey()
        guard !key.isEmpty else { throw ProxyError(errorCode: "MISSING_APP_KEY", message: "Open Settings and enter the sync server’s app key.") }
        return .init(baseURL: url, appKey: key)
    }

    @discardableResult func checkServer() async throws -> HealthResponse {
        let selectedServer = serverID
        syncMessage = "Waking sync server…"
        defer { if !isSyncing { syncMessage = "" } }
        let url = try ProxyClient.validatedURL(proxyURL)
        let health = try await ProxyClient(baseURL: url, appKey: "").health()
        guard selectedServer == serverID else { throw ProxyError(errorCode: "SERVER_CHANGED", message: "The sync server changed. Try again with the new settings.") }
        guard health.environment == "sandbox" else {
            throw ProxyError(errorCode: "SANDBOX_REQUIRED", message: "This testing build only connects to a Plaid Sandbox server.")
        }
        guard health.configured else { throw ProxyError(errorCode: "SERVER_NOT_CONFIGURED", message: "Add your Plaid Sandbox client ID, secret, and app key to proxy/.env, then restart the server.") }
        serverHealth = health
        return health
    }

    func createLinkToken(product: LinkProduct, updating connectionID: String? = nil) async throws -> String {
        _ = try await checkServer()
        let connection = try connectionID.map { try findConnection($0) }
        var token: String?
        if let connection {
            guard connection.serverID == serverID else { throw ProxyError(errorCode: "WRONG_SERVER", message: "Switch back to the server used by this connection.") }
            token = try SecureStore.string(for: tokenKey(itemID: connection.itemID))
            guard token != nil else { throw ProxyError(errorCode: "TOKEN_MISSING", message: "This device no longer has the connection token. Restore the original Keychain or create a new Sandbox connection.") }
        }
        let response = try await client().linkToken(clientUserID: clientUserID, product: product, accessToken: token)
        return response.linkToken
    }

    /// Returns an existing connection ID when metadata identifies a duplicate.
    func finishLink(publicToken: String, institutionID: String, name: String, masks: [String], product: LinkProduct, updating: String? = nil) async throws -> String? {
        guard !linking else { throw ProxyError(errorCode: "LINK_IN_PROGRESS") }
        linking = true; defer { linking = false }
        if let updating {
            // Update mode keeps the Item and token. It must never call /item/exchange.
            try await writer.markStatus(connectionID: updating, status: "Connected")
            await sync(connectionID: updating)
            return nil
        }
        let records = try container.mainContext.fetch(FetchDescriptor<InstitutionRecord>()).filter { $0.serverID == serverID }
        let identities = records.map { ConnectionIdentity(id: $0.id, institutionID: $0.institutionID, masks: $0.accountMasks) }
        if let duplicate = DuplicateGuard.existing(institutionID: institutionID, masks: masks, connections: identities) {
            notice = "This bank is already connected. Reconnect the existing connection to avoid a duplicate Item."
            return duplicate
        }
        let selectedServer = serverID
        let exchange = try await client().exchange(publicToken: publicToken)
        // Persist immediately, before any account fetch. Metadata is also recoverable
        // from Keychain if the SwiftData insertion fails or the app is terminated.
        let pending = PendingConnection(id: UUID().uuidString, name: name, institutionID: institutionID, itemID: exchange.itemId, masks: masks, product: product.rawValue, accessToken: exchange.accessToken)
        try SecureStore.setData(JSONEncoder().encode(pending), for: "pending.\(selectedServer)")
        guard selectedServer == serverID else { throw ProxyError(errorCode: "SERVER_CHANGED", message: "Switch back to the original sync server to finish recovering this connection.") }
        try recoverPendingConnection()
        await sync(connectionID: pending.id)
        return nil
    }

    func recoverPendingConnection() throws {
        guard let data = try SecureStore.data(for: "pending.\(serverID)") else { return }
        let pending = try JSONDecoder().decode(PendingConnection.self, from: data)
        try SecureStore.set(pending.accessToken, for: tokenKey(itemID: pending.itemID))
        let records = try container.mainContext.fetch(FetchDescriptor<InstitutionRecord>())
        if !records.contains(where: { $0.itemID == pending.itemID && $0.serverID == serverID }) {
            container.mainContext.insert(InstitutionRecord(id: pending.id, name: pending.name, institutionID: pending.institutionID, itemID: pending.itemID, serverID: serverID, accountMasks: pending.masks, product: pending.product))
            try container.mainContext.save()
        }
        try SecureStore.delete("pending.\(serverID)")
    }

    func sandboxBank(product: LinkProduct) async throws -> String? {
        let health = try await checkServer()
        guard health.sandboxTools else { throw ProxyError(errorCode: "SANDBOX_TOOLS_DISABLED", message: "Set ENABLE_SANDBOX_TOOLS=true in proxy/.env.") }
        let records = try container.mainContext.fetch(FetchDescriptor<InstitutionRecord>()).filter { $0.serverID == serverID }
        let institutionID = product == .transactions ? "ins_109508" : product == .liabilities ? "ins_109509" : "ins_109511"
        if let existing = records.first(where: { $0.institutionID == institutionID }) {
            notice = "This test bank is already connected. Refresh or reconnect it in Settings."
            return existing.id
        }
        let data = try JSONSerialization.data(withJSONObject: ["product": product.rawValue, "dynamic": product == .transactions])
        let response: SandboxItemResponse = try await client().postData("sandbox/item/create", data: data)
        return try await finishLink(publicToken: response.publicToken, institutionID: response.institutionId, name: response.institutionName, masks: response.accountMasks, product: product)
    }

    func findConnection(_ id: String) throws -> InstitutionRecord {
        guard let record = try container.mainContext.fetch(FetchDescriptor<InstitutionRecord>()).first(where: { $0.id == id }) else { throw ProxyError(errorCode: "CONNECTION_MISSING") }
        return record
    }

    func sync(connectionID: String? = nil) async {
        guard !isSyncing else { return }
        isSyncing = true; defer { isSyncing = false; syncMessage = "" }
        do {
            _ = try await checkServer()
            let api = try client()
            let records = try container.mainContext.fetch(FetchDescriptor<InstitutionRecord>()).filter { $0.serverID == serverID && (connectionID == nil || $0.id == connectionID) }
            if records.isEmpty { notice = "Connect a Sandbox bank to start syncing."; return }
            var changes = 0, preparing = false
            var failures: [String] = []
            for connection in records {
                syncMessage = "Syncing \(connection.name)…"
                do {
                    guard let token = try SecureStore.string(for: tokenKey(itemID: connection.itemID)) else { throw ProxyError(errorCode: "TOKEN_MISSING", message: "The token is missing on this device.") }
                    let accounts = try await api.accounts(accessToken: token)
                    let product = LinkProduct(rawValue: connection.product) ?? .transactions
                    var batch: SyncBatch?
                    var liabilities: LiabilityResponse?
                    var holdings: HoldingsResponse?
                    switch product {
                    case .transactions:
                        let cursor = try await writer.savedCursor(connectionID: connection.id)
                        batch = try await SyncPager.fetch(transport: api, accessToken: token, cursor: cursor)
                    case .liabilities: liabilities = try await api.post("liabilities", body: ["access_token": token])
                    case .investments: holdings = try await api.post("investments", body: ["access_token": token])
                    }
                    guard connection.serverID == serverID else { throw ProxyError(errorCode: "SERVER_CHANGED", message: "The server changed during sync. Refresh again with the intended server.") }
                    let outcome = try await writer.commit(connectionID: connection.id, accounts: accounts.accounts, batch: batch, liabilities: liabilities, holdings: holdings)
                    changes += outcome.changed; preparing = preparing || outcome.preparing
                } catch {
                    let status = (error as? ProxyError)?.needsLogin == true ? "Reconnect required" : "Sync failed"
                    try await writer.markStatus(connectionID: connection.id, status: status)
                    failures.append("\(connection.name): \(error.localizedDescription)")
                }
            }
            if !failures.isEmpty { errorMessage = failures.joined(separator: "\n") }
            else { notice = preparing ? "Plaid is preparing transaction history. Pull to refresh again shortly." : "Up to date · \(changes) transaction updates" }
            try receipts.rematch()
        } catch { report(error) }
    }

    func sandboxAction(_ path: String, connection: InstitutionRecord) async throws {
        _ = try await checkServer()
        guard connection.serverID == serverID, let token = try SecureStore.string(for: tokenKey(itemID: connection.itemID)) else { throw ProxyError(errorCode: "TOKEN_MISSING") }
        struct OK: Decodable, Sendable { var ok: Bool }
        let _: OK = try await client().post(path, body: ["access_token": token])
        if path.contains("reset-login") { try await writer.markStatus(connectionID: connection.id, status: "Reconnect required") }
        else { notice = "Refresh requested. Pull to refresh after Plaid finishes preparing the update." }
    }

    func unlock() async {
        guard !isAuthenticating else { return }
        lockMessage = nil
        isAuthenticating = true; defer { isAuthenticating = false }
        let context = LAContext()
        do {
            let allowed = try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Unlock your finances")
            if allowed { isLocked = false; Task { await receipts.foreground(); await ShipmentTrackingService.refresh(app: self) } }
        } catch { lockMessage = error.localizedDescription }
    }
    func setProtection(_ enabled: Bool) async {
        if enabled {
            let context = LAContext()
            do {
                if try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Enable app lock") { faceIDEnabled = true }
            } catch { report(error) }
        } else if faceIDEnabled {
            let context = LAContext()
            do {
                if try await context.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: "Turn off app lock") { faceIDEnabled = false; isLocked = false }
            } catch { report(error) }
        }
    }
    func background() { isObscured = true; backgroundAt = .now }
    func active() {
        isObscured = false
        if faceIDEnabled, let backgroundAt, Date.now.timeIntervalSince(backgroundAt) >= 60 { isLocked = true }
        backgroundAt = nil
        if isLocked { Task { await unlock() } }
    }
}
