import Foundation
import AuthenticationServices
import CryptoKit
import Security
import UIKit
import Network
import MonarchCore

struct EmailCredential: Codable, Sendable {
    var accessToken: String?
    var refreshToken: String?
    var expiresAt: Date?
    var clientID: String?
    var appPassword: String?
    var imapHost: String?
    var imapUsername: String?
    static func key(_ accountID: String) -> String { "email.\(accountID)" }
    static func load(_ accountID: String) throws -> EmailCredential {
        guard let data = try SecureStore.data(for: key(accountID)) else { throw MailFailure.needsReconnect }
        return try JSONDecoder().decode(Self.self, from: data)
    }
    func save(_ accountID: String) throws { try SecureStore.setData(JSONEncoder().encode(self), for: Self.key(accountID)) }
}

private final class MailRedirectBlocker: NSObject, URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) { completionHandler(nil) }
}
enum MailHTTP {
    static func send(_ request: URLRequest) async throws -> (Data, Int) {
        let config = URLSessionConfiguration.ephemeral
        config.urlCache = nil; config.httpCookieStorage = nil; config.httpShouldSetCookies = false; config.timeoutIntervalForRequest = 45
        let session = URLSession(configuration: config, delegate: MailRedirectBlocker(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        let (data, response) = try await session.data(for: request)
        guard data.count <= 36 * 1024 * 1024, let response = response as? HTTPURLResponse else { throw MailFailure.tooLarge }
        return (data, response.statusCode)
    }
    static func form(_ values: [String: String]) -> Data {
        var parts = URLComponents(); parts.queryItems = values.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) }
        return Data((parts.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B").utf8)
    }
}

@MainActor final class GmailAuthorization: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.flatMap(\.windows).first(where: \.isKeyWindow) ?? ASPresentationAnchor()
    }
    func authorize() async throws -> EmailCredential {
        guard let clientID = Bundle.main.object(forInfoDictionaryKey: "GmailClientID") as? String, clientID.hasSuffix(".apps.googleusercontent.com"), !clientID.contains("$("),
              let scheme = Bundle.main.object(forInfoDictionaryKey: "GmailRedirectScheme") as? String, scheme.hasPrefix("com.googleusercontent.apps."), !scheme.contains("$(") else {
            throw ProxyError(errorCode: "GMAIL_SETUP_REQUIRED", message: "Set the iOS Gmail OAuth client ID and reversed URL scheme in Local.xcconfig, then rebuild. The setup guide includes the steps.")
        }
        func random() throws -> String {
            var data = Data(count: 32)
            let status = data.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
            guard status == errSecSuccess else { throw BackupFailure.keyDerivation }
            return data.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        }
        let verifier = try random(), state = try random(), redirect = scheme + ":/oauthredirect"
        let challenge = Data(SHA256.hash(data: Data(verifier.utf8))).base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        var url = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
        url.queryItems = ["client_id": clientID, "redirect_uri": redirect, "response_type": "code", "scope": "https://www.googleapis.com/auth/gmail.readonly", "access_type": "offline", "prompt": "consent", "state": state, "code_challenge": challenge, "code_challenge_method": "S256"].map { URLQueryItem(name: $0.key, value: $0.value) }
        let callback: URL = try await withCheckedThrowingContinuation { continuation in
            session = ASWebAuthenticationSession(url: url.url!, callbackURLScheme: scheme) { callback, error in
                if let error { continuation.resume(throwing: error) }
                else if let callback { continuation.resume(returning: callback) }
                else { continuation.resume(throwing: MailFailure.needsReconnect) }
            }
            session?.presentationContextProvider = self; session?.prefersEphemeralWebBrowserSession = true
            if session?.start() != true { continuation.resume(throwing: MailFailure.needsReconnect) }
        }
        defer { session = nil }
        let parameters = URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? []
        guard callback.scheme == scheme, parameters.first(where: { $0.name == "state" })?.value == state,
              let code = parameters.first(where: { $0.name == "code" })?.value else { throw MailFailure.needsReconnect }
        return try await GmailAPI.exchange(["client_id": clientID, "redirect_uri": redirect, "code": code, "code_verifier": verifier, "grant_type": "authorization_code"], clientID: clientID)
    }
}

actor GmailAPI {
    private let accountID: String
    private var credential: EmailCredential
    init(accountID: String, credential: EmailCredential) { self.accountID = accountID; self.credential = credential }
    private struct TokenResponse: Decodable { var access_token: String; var refresh_token: String?; var expires_in: Int }
    static func exchange(_ parameters: [String: String], clientID: String) async throws -> EmailCredential {
        var request = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        request.httpMethod = "POST"; request.httpBody = MailHTTP.form(parameters); request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        let (data, status) = try await MailHTTP.send(request)
        guard status == 200 else { throw MailFailure.needsReconnect }
        let token = try JSONDecoder().decode(TokenResponse.self, from: data)
        return EmailCredential(accessToken: token.access_token, refreshToken: token.refresh_token, expiresAt: .now.addingTimeInterval(Double(token.expires_in)), clientID: clientID)
    }
    private func token() async throws -> String {
        if let token = credential.accessToken, (credential.expiresAt?.timeIntervalSinceNow ?? 0) > 60 { return token }
        guard let refresh = credential.refreshToken, let clientID = credential.clientID else { throw MailFailure.needsReconnect }
        var renewed = try await Self.exchange(["client_id": clientID, "refresh_token": refresh, "grant_type": "refresh_token"], clientID: clientID)
        renewed.refreshToken = renewed.refreshToken ?? refresh
        try renewed.save(accountID); credential = renewed
        return renewed.accessToken!
    }
    private func get<T: Decodable>(_ path: String, query: [URLQueryItem] = []) async throws -> T {
        var url = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/" + path)!
        url.queryItems = query.isEmpty ? nil : query
        var request = URLRequest(url: url.url!)
        request.setValue("Bearer " + (try await token()), forHTTPHeaderField: "Authorization")
        let (data, status) = try await MailHTTP.send(request)
        if status == 401 || status == 403 { throw MailFailure.needsReconnect }
        if status == 404 { throw GmailHistoryExpired() }
        guard status == 200 else { throw MailFailure.invalidResponse }
        return try JSONDecoder().decode(T.self, from: data)
    }
    struct Profile: Decodable, Sendable { var emailAddress: String; var historyId: String }
    private struct MessageID: Decodable { var id: String }
    private struct MessageList: Decodable { var messages: [MessageID]?; var nextPageToken: String? }
    private struct HistoryList: Decodable {
        struct History: Decodable { struct Added: Decodable { var message: MessageID }; var messagesAdded: [Added]? }
        var history: [History]?; var nextPageToken: String?; var historyId: String
    }
    private struct Message: Decodable {
        struct Payload: Decodable { struct Header: Decodable { var name: String; var value: String }; var headers: [Header]? }
        var raw: String?; var payload: Payload?
    }
    struct GmailHistoryExpired: Error {}
    func profile() async throws -> Profile { try await get("profile") }
    func changes(historyID: String?) async throws -> (ids: [String], checkpoint: String) {
        let initial = try await profile()
        var ids: [String] = [], page: String?, checkpoint = initial.historyId, count = 0
        if let historyID {
            do {
                repeat {
                    var query = [URLQueryItem(name: "startHistoryId", value: historyID), URLQueryItem(name: "historyTypes", value: "messageAdded"), URLQueryItem(name: "maxResults", value: "100")]
                    if let page { query.append(.init(name: "pageToken", value: page)) }
                    let result: HistoryList = try await get("history", query: query)
                    ids += result.history?.flatMap { $0.messagesAdded?.map { $0.message.id } ?? [] } ?? []
                    page = result.nextPageToken; checkpoint = result.historyId; count += 1
                    guard count <= 100 else { throw MailFailure.tooLarge }
                } while page != nil
                return (Array(Set(ids)).sorted(), checkpoint)
            } catch is GmailHistoryExpired { /* Invalid history IDs need a new bounded initial scan. */ }
        }
        ids = []; page = nil; count = 0
        repeat {
            var query = [URLQueryItem(name: "q", value: MailText.gmailQuery()), URLQueryItem(name: "maxResults", value: "100")]
            if let page { query.append(.init(name: "pageToken", value: page)) }
            let result: MessageList = try await get("messages", query: query)
            ids += result.messages?.map(\.id) ?? []; page = result.nextPageToken; count += 1
            guard count <= 100 else { throw MailFailure.tooLarge }
        } while page != nil
        return (Array(Set(ids)).sorted(), initial.historyId)
    }
    func matchesReceipt(_ id: String) async throws -> Bool {
        do {
            let message: Message = try await get("messages/" + id, query: [.init(name: "format", value: "metadata"), .init(name: "metadataHeaders", value: "Subject"), .init(name: "metadataHeaders", value: "From")])
            let headers = message.payload?.headers ?? []
            return MailText.matchesReceipt(subject: headers.first { $0.name.lowercased() == "subject" }?.value ?? "", sender: headers.first { $0.name.lowercased() == "from" }?.value ?? "")
        } catch is GmailHistoryExpired { return false } // a message can be deleted between history and fetch
    }
    func raw(_ id: String) async throws -> Data? {
        do {
            let message: Message = try await get("messages/" + id, query: [.init(name: "format", value: "raw")])
            guard let raw = message.raw, let data = MailText.base64URL(raw), data.count <= ReceiptSharedConfig.maximumBytes else { throw MailFailure.tooLarge }
            return data
        } catch is GmailHistoryExpired { return nil }
    }
}

actor IMAPSession {
    private let connection: NWConnection
    private let queue = DispatchQueue(label: "app.monarch.imap")
    private var buffer = Data()
    private var counter = 0
    init(host: String) throws {
        guard host.range(of: #"^[A-Za-z0-9](?:[A-Za-z0-9.-]*[A-Za-z0-9])?$"#, options: .regularExpression) != nil, host.contains("."), !host.contains("..") else { throw MailFailure.invalidServer }
        let tls = NWProtocolTLS.Options()
        sec_protocol_options_set_tls_server_name(tls.securityProtocolOptions, host)
        sec_protocol_options_set_min_tls_protocol_version(tls.securityProtocolOptions, .TLSv12)
        connection = NWConnection(host: NWEndpoint.Host(host), port: 993, using: NWParameters(tls: tls, tcp: NWProtocolTCP.Options()))
    }
    func open(username: String, password: String, mailbox: String) async throws -> (validity: String?, nextUID: UInt64?) {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            var finished = false
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready: if !finished { finished = true; continuation.resume() }
                case .failed, .cancelled: if !finished { finished = true; continuation.resume(throwing: MailFailure.disconnected) }
                default: break
                }
            }
            queue.asyncAfter(deadline: .now() + 30) { [connection] in if !finished { finished = true; continuation.resume(throwing: MailFailure.timedOut); connection.cancel() } }
            connection.start(queue: queue)
        }
        let greeting = try await line()
        guard greeting.uppercased().hasPrefix("* OK") else { throw MailFailure.rejected }
        _ = try await command("LOGIN \(IMAPSyntax.quote(username)) \(IMAPSyntax.quote(password))")
        let result = try await command("EXAMINE \(IMAPSyntax.quote(mailbox))")
        let next = result.lines.compactMap { line -> UInt64? in
            guard let range = line.range(of: #"(?i)\[UIDNEXT ([0-9]+)\]"#, options: .regularExpression) else { return nil }
            return UInt64(line[range].filter(\.isNumber))
        }.first
        return (IMAPSyntax.uidValidity(result.lines), next)
    }
    func close() { connection.cancel() }
    private func receive() async throws {
        let connection = connection, queue = queue
        let data: Data = try await withCheckedThrowingContinuation { continuation in
            let timeout = DispatchWorkItem { connection.cancel() }
            queue.asyncAfter(deadline: .now() + 30, execute: timeout)
            connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { data, _, complete, error in
                timeout.cancel()
                if let data, !data.isEmpty { continuation.resume(returning: data) }
                else { continuation.resume(throwing: (error as Error?) ?? MailFailure.disconnected) }
            }
        }
        buffer.append(data)
    }
    private func line() async throws -> String {
        while true {
            if let range = buffer.range(of: Data("\r\n".utf8)) {
                let result = String(decoding: buffer[..<range.lowerBound], as: UTF8.self)
                buffer.removeSubrange(..<range.upperBound); return result
            }
            guard buffer.count < 65536 else { throw MailFailure.invalidResponse }
            try await receive(); try Task.checkCancellation()
        }
    }
    private func bytes(_ count: Int) async throws -> Data {
        guard count <= ReceiptSharedConfig.maximumBytes else { throw MailFailure.tooLarge }
        while buffer.count < count { try await receive(); try Task.checkCancellation() }
        let data = Data(buffer.prefix(count)); buffer.removeFirst(count); return data
    }
    private func command(_ text: String) async throws -> (lines: [String], literals: [Data]) {
        counter += 1; let tag = "M\(counter)"
        let data = Data("\(tag) \(text)\r\n".utf8)
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            connection.send(content: data, completion: .contentProcessed { error in if let error { continuation.resume(throwing: error) } else { continuation.resume() } })
        }
        var lines: [String] = [], literals: [Data] = []
        while true {
            let response = try await line(); lines.append(response)
            if let size = IMAPSyntax.literalLength(response) { literals.append(try await bytes(size)) }
            if response.hasPrefix(tag + " ") {
                guard response.uppercased().hasPrefix(tag + " OK") else { throw MailFailure.rejected }
                return (lines, literals)
            }
            guard lines.count < 20000 else { throw MailFailure.tooLarge }
        }
    }
    func matchingUIDs(after: UInt64?, through: UInt64?) async throws -> [UInt64] {
        let clauses = ["SUBJECT \"order\"", "SUBJECT \"receipt\"", "SUBJECT \"invoice\"", "SUBJECT \"shipped\"", "SUBJECT \"shipping\"", "SUBJECT \"delivered\"", "SUBJECT \"tracking\"", "FROM \"orders\"", "FROM \"receipts\"", "FROM \"shipping\""]
        let keywords = clauses.dropLast().reversed().reduce(clauses.last!) { "OR (\($1)) (\($0))" }
        var filter = "(\(keywords))"
        if let after {
            let maximum = through.map(String.init) ?? "*"
            if let through, through <= after { return [] }
            filter = "UID \(after + 1):\(maximum) " + filter
        } else {
            let since = Calendar.current.date(byAdding: .day, value: -90, to: .now) ?? .now
            filter = "SINCE \(LedgerDate.string(since, format: "d-MMM-yyyy")) " + filter
        }
        return IMAPSyntax.searchUIDs(try await command("UID SEARCH " + filter).lines).filter { (after == nil || $0 > after!) && (through == nil || $0 <= through!) }
    }
    func raw(_ uid: UInt64) async throws -> Data {
        guard let data = try await command("UID FETCH \(uid) (BODY.PEEK[])").literals.first else { throw MailFailure.invalidMessage }
        return data
    }
}
