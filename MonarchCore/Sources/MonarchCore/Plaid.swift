import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum LinkProduct: String, Codable, CaseIterable, Sendable {
    case transactions, liabilities, investments
    public var title: String {
        switch self { case .transactions: "Banking & cards"; case .liabilities: "Loans & liabilities"; case .investments: "Investments" }
    }
}

public struct PlaidAccount: Codable, Sendable {
    public var accountId: String
    public var name: String
    public var officialName: String?
    public var mask: String?
    public var type: String
    public var subtype: String?
    public var balances: Balances
    public struct Balances: Codable, Sendable {
        public var current: Decimal?
        public var available: Decimal?
        public var limit: Decimal?
        public var isoCurrencyCode: String?
        public var unofficialCurrencyCode: String?
    }
    public var kind: AccountKind {
        switch type {
        case "depository": subtype == "savings" || subtype == "cd" || subtype == "money market" ? .savings : .checking
        case "credit": .credit
        case "loan": .loan
        case "investment", "brokerage": .investment
        default: .other
        }
    }
}

public struct PlaidEntry: Codable, Sendable {
    public var transactionId: String
    public var pendingTransactionId: String?
    public var accountId: String
    public var date: String
    public var amount: Decimal
    public var name: String
    public var merchantName: String?
    public var originalDescription: String?
    public var pending: Bool
    public var personalFinanceCategory: FinanceCategory?
    public struct FinanceCategory: Codable, Sendable { public var primary: String?; public var detailed: String? }
}

public struct SyncPage: Codable, Sendable {
    public var added: [PlaidEntry]
    public var modified: [PlaidEntry]
    public var removed: [Removed]
    public var nextCursor: String
    public var hasMore: Bool
    public var transactionsUpdateStatus: String?
    public struct Removed: Codable, Sendable { public var transactionId: String }
    public init(added: [PlaidEntry] = [], modified: [PlaidEntry] = [], removed: [Removed] = [], nextCursor: String, hasMore: Bool, transactionsUpdateStatus: String? = nil) {
        self.added = added; self.modified = modified; self.removed = removed
        self.nextCursor = nextCursor; self.hasMore = hasMore; self.transactionsUpdateStatus = transactionsUpdateStatus
    }
}

public struct SyncBatch: Sendable {
    public var added: [PlaidEntry] = []
    public var modified: [PlaidEntry] = []
    public var removed: [SyncPage.Removed] = []
    public var nextCursor: String
    public var updateStatus: String?
    public init(nextCursor: String) { self.nextCursor = nextCursor }
}

public struct ProxyError: Error, Codable, LocalizedError, Sendable {
    public var errorCode: String
    public var message: String?
    public var errorDescription: String? { message ?? errorCode.replacingOccurrences(of: "_", with: " ").capitalized }
    public var needsLogin: Bool { ["ITEM_LOGIN_REQUIRED", "INVALID_ACCESS_TOKEN", "ITEM_NOT_FOUND"].contains(errorCode) }
    public init(errorCode: String, message: String? = nil) { self.errorCode = errorCode; self.message = message }
}

public struct LinkTokenResponse: Codable, Sendable { public var linkToken: String; public var expiration: String }
public struct ExchangeResponse: Codable, Sendable { public var accessToken: String; public var itemId: String }
public struct AccountsResponse: Codable, Sendable { public var accounts: [PlaidAccount] }
public struct HealthResponse: Codable, Sendable { public var ok: Bool; public var environment: String; public var configured: Bool; public var sandboxTools: Bool; public var trackingConfigured: Bool? }
public struct SandboxItemResponse: Codable, Sendable { public var publicToken: String; public var institutionId: String; public var institutionName: String; public var accountMasks: [String] }

public struct LiabilityResponse: Codable, Sendable {
    public var student: [StudentLoan]
    public var credit: [CreditLiability]
    public struct StudentLoan: Codable, Sendable {
        public var accountId: String
        public var interestRatePercentage: Decimal?
        public var minimumPaymentAmount: Decimal?
        public var nextPaymentDueDate: String?
        public var outstandingInterestAmount: Decimal?
        public var loanName: String?
        public var servicerAddress: Address?
    }
    public struct Address: Codable, Sendable { public var city: String? }
    public struct CreditLiability: Codable, Sendable {
        public var accountId: String
        public var minimumPaymentAmount: Decimal?
        public var nextPaymentDueDate: String?
        public var lastStatementIssueDate: String?
        public var lastStatementBalance: Decimal?
    }
}

public struct HoldingsResponse: Codable, Sendable {
    public var holdings: [Holding]
    public var securities: [Security]
    public struct Holding: Codable, Sendable {
        public var accountId: String
        public var securityId: String
        public var quantity: Decimal
        public var costBasis: Decimal?
        public var institutionPrice: Decimal
        public var institutionPriceAsOf: String?
    }
    public struct Security: Codable, Sendable {
        public var securityId: String
        public var name: String?
        public var tickerSymbol: String?
        public var type: String?
        public var closePrice: Decimal?
        public var closePriceAsOf: String?
    }
}

public protocol SyncTransport: Sendable {
    func sync(accessToken: String, cursor: String?) async throws -> SyncPage
}

private final class RedirectBlocker: NSObject, URLSessionTaskDelegate, Sendable {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping @Sendable (URLRequest?) -> Void) {
        completionHandler(nil)
    }
}

public struct ProxyClient: SyncTransport, Sendable {
    public let baseURL: URL
    private let appKey: String
    public init(baseURL: URL, appKey: String) { self.baseURL = baseURL; self.appKey = appKey }

    public static func validatedURL(_ text: String) throws -> URL {
        guard let url = URL(string: text), let host = url.host, url.user == nil, url.password == nil,
              url.query == nil, url.fragment == nil,
              url.scheme == "https" || (url.scheme == "http" && ["localhost", "127.0.0.1", "::1"].contains(host)) else {
            throw ProxyError(errorCode: "INVALID_PROXY_URL", message: "Use HTTPS, or http://127.0.0.1:8000 for the simulator.")
        }
        return url
    }

    public func health() async throws -> HealthResponse {
        var request = URLRequest(url: baseURL.appendingPathComponent("health"))
        request.timeoutInterval = 65
        return try await send(request)
    }

    public func post<T: Decodable & Sendable>(_ path: String, body: [String: String]) async throws -> T {
        try await postData(path, data: JSONEncoder().encode(body))
    }

    public func postData<T: Decodable & Sendable>(_ path: String, data: Data) async throws -> T {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = "POST"
        request.timeoutInterval = 65
        request.setValue(appKey, forHTTPHeaderField: "X-App-Key")
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = data
        return try await send(request)
    }

    private func send<T: Decodable & Sendable>(_ request: URLRequest) async throws -> T {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: configuration, delegate: RedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard let response = response as? HTTPURLResponse else { throw ProxyError(errorCode: "INVALID_RESPONSE") }
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        guard (200..<300).contains(response.statusCode) else {
            if let error = try? decoder.decode(ProxyError.self, from: data) { throw error }
            throw ProxyError(errorCode: "HTTP_\(response.statusCode)", message: "The sync server returned \(response.statusCode). Check its configuration and try again.")
        }
        return try decoder.decode(T.self, from: data)
    }

    public func linkToken(clientUserID: String, product: LinkProduct, accessToken: String? = nil) async throws -> LinkTokenResponse {
        var body = ["client_user_id": clientUserID, "product": product.rawValue]
        if let accessToken { body["access_token"] = accessToken }
        return try await post("link/token", body: body)
    }

    public func exchange(publicToken: String) async throws -> ExchangeResponse {
        try await post("item/exchange", body: ["public_token": publicToken])
    }

    public func accounts(accessToken: String) async throws -> AccountsResponse { try await post("accounts", body: ["access_token": accessToken]) }
    public func sync(accessToken: String, cursor: String?) async throws -> SyncPage {
        var body = ["access_token": accessToken]
        if let cursor { body["cursor"] = cursor }
        return try await post("transactions/sync", body: body)
    }
}

public enum SyncPager {
    /// No page is committed until all pages arrive. A mutation restarts at the original saved cursor.
    public static func fetch(transport: any SyncTransport, accessToken: String, cursor: String?, maximumRestarts: Int = 3) async throws -> SyncBatch {
        for attempt in 0...maximumRestarts {
            var batch = SyncBatch(nextCursor: cursor ?? "")
            var pageCursor = cursor
            var pages = 0
            do {
                while true {
                    try Task.checkCancellation()
                    let page = try await transport.sync(accessToken: accessToken, cursor: pageCursor)
                    batch.added += page.added; batch.modified += page.modified; batch.removed += page.removed
                    batch.nextCursor = page.nextCursor; batch.updateStatus = page.transactionsUpdateStatus
                    pages += 1
                    if !page.hasMore { return batch }
                    guard page.nextCursor != pageCursor, pages < 1000 else { throw ProxyError(errorCode: "INVALID_PAGINATION") }
                    pageCursor = page.nextCursor
                }
            } catch let error as ProxyError where error.errorCode == "TRANSACTIONS_SYNC_MUTATION_DURING_PAGINATION" {
                if attempt == maximumRestarts { throw error }
            }
        }
        throw ProxyError(errorCode: "SYNC_RETRY_EXHAUSTED")
    }
}

public struct ConnectionIdentity: Sendable {
    public var id: String
    public var institutionID: String
    public var masks: [String]
    public init(id: String, institutionID: String, masks: [String]) { self.id = id; self.institutionID = institutionID; self.masks = masks }
}

public enum DuplicateGuard {
    public static func existing(institutionID: String, masks: [String], connections: [ConnectionIdentity]) -> String? {
        guard !institutionID.isEmpty else { return nil }
        let masks = Set(masks.filter { !$0.isEmpty })
        return connections.first { existing in
            guard existing.institutionID == institutionID else { return false }
            let old = Set(existing.masks.filter { !$0.isEmpty })
            // Missing metadata is treated conservatively: re-authenticate the existing Item.
            return masks.isEmpty || old.isEmpty || !old.isDisjoint(with: masks)
        }?.id
    }
}

public enum SyncMerger {
    public static func merge(existing: [EntryValue], batch: SyncBatch, accountIDs: [String: String]) throws -> [EntryValue] {
        var entries = Dictionary(uniqueKeysWithValues: existing.map { ($0.id, $0) })
        var sourceIndex = Dictionary(uniqueKeysWithValues: existing.compactMap { entry in entry.sourceID.map { ($0, entry.id) } })
        for remote in batch.added + batch.modified {
            guard let accountID = accountIDs[remote.accountId] else {
                throw ProxyError(errorCode: "UNKNOWN_ACCOUNT", message: "Plaid returned a transaction for an unavailable account. Refresh again to retry safely.")
            }
            guard let date = LedgerDate.parse(remote.date) else { throw ProxyError(errorCode: "INVALID_TRANSACTION_DATE") }
            let existingID = sourceIndex[remote.transactionId] ?? remote.pendingTransactionId.flatMap { sourceIndex[$0] }
            var entry = existingID.flatMap { entries[$0] } ?? EntryValue(accountID: accountID, date: date, amount: -remote.amount, merchant: remote.merchantName ?? remote.name)
            if entry.isSplitParent && entry.amount != -remote.amount {
                entries = entries.filter { $0.value.parentID != entry.id }
                entry.isSplitParent = false; entry.isReviewed = false
            }
            if !entry.lockedFields.contains("date") { entry.date = date }
            if !entry.lockedFields.contains("merchant") { entry.merchant = (remote.merchantName ?? remote.name).trimmingCharacters(in: .whitespacesAndNewlines) }
            if !entry.lockedFields.contains("category") {
                entry.categoryID = CategoryMapper.category(primary: remote.personalFinanceCategory?.primary, detailed: remote.personalFinanceCategory?.detailed, amount: -remote.amount)
            }
            entry.accountID = accountID; entry.amount = -remote.amount
            entry.originalDescription = remote.originalDescription ?? remote.name
            entry.isPending = remote.pending; entry.sourceID = remote.transactionId
            if let pending = remote.pendingTransactionId { sourceIndex.removeValue(forKey: pending) }
            entries[entry.id] = entry; sourceIndex[remote.transactionId] = entry.id
        }
        let removed = Set(batch.removed.map(\.transactionId))
        let removedIDs = Set(entries.values.filter { $0.sourceID.map(removed.contains) ?? false }.map(\.id))
        return entries.values.filter { !removedIDs.contains($0.id) && !($0.parentID.map(removedIDs.contains) ?? false) }.sorted { $0.date > $1.date }
    }
}
