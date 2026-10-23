import Foundation

public enum MailText {
    public static func plain(_ input: String) -> String {
        var text = String(input.prefix(1_000_000))
        for pattern in [#"(?is)<script\b[^>]*>.*?</script>"#, #"(?is)<style\b[^>]*>.*?</style>"#] { text = text.replacingOccurrences(of: pattern, with: "", options: .regularExpression) }
        text = text.replacingOccurrences(of: #"(?is)<a\b[^>]*href=["'](https://[^"']+)["'][^>]*>(.*?)</a>"#, with: "$2 $1", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?i)<(?:br\s*/?|/p|/div|/tr|/li|/h[1-6])\s*>"#, with: "\n", options: .regularExpression)
        text = text.replacingOccurrences(of: #"(?s)<[^>]+>"#, with: " ", options: .regularExpression)
        for (entity, replacement) in [("&nbsp;", " "), ("&quot;", "\""), ("&#39;", "'"), ("&lt;", "<"), ("&gt;", ">"), ("&amp;", "&")] { text = text.replacingOccurrences(of: entity, with: replacement) }
        if let regex = try? NSRegularExpression(pattern: #"&#(x[0-9a-fA-F]+|[0-9]+);"#) {
            for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
                guard let range = Range(match.range, in: text), let digits = Range(match.range(at: 1), in: text) else { continue }
                let raw = String(text[digits]), value = raw.hasPrefix("x") ? UInt32(raw.dropFirst(), radix: 16) : UInt32(raw)
                if let value, let scalar = UnicodeScalar(value) { text.replaceSubrange(range, with: String(scalar)) }
            }
        }
        return text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }
    public static func matchesReceipt(subject: String, sender: String) -> Bool {
        let text = subject + " " + sender
        return ["order", "receipt", "shipped", "shipping", "delivered", "invoice", "tracking", "delivery"].contains { text.localizedCaseInsensitiveContains($0) }
    }
    public static func gmailQuery(now: Date = .now) -> String {
        let since = Calendar.current.date(byAdding: .day, value: -90, to: now) ?? now
        return "after:\(LedgerDate.string(since, format: "yyyy/MM/dd")) {subject:order subject:receipt subject:shipped subject:shipping subject:delivered subject:invoice subject:tracking from:orders from:receipts from:shipping}"
    }
    public static func base64URL(_ text: String) -> Data? {
        var value = text.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
        value += String(repeating: "=", count: (4 - value.count % 4) % 4)
        return Data(base64Encoded: value, options: .ignoreUnknownCharacters)
    }
}

public struct MailAttachment: Sendable {
    public var filename: String
    public var contentType: String
    public var data: Data
    public init(filename: String, contentType: String, data: Data) { self.filename = filename; self.contentType = contentType; self.data = data }
}
public struct ParsedMail: Sendable {
    public var subject: String
    public var sender: String
    public var messageID: String
    public var plainText: String
    public var attachments: [MailAttachment]
    public var date: Date?
}
public enum MailFailure: Error, LocalizedError {
    case tooLarge, invalidMessage, invalidServer, disconnected, invalidResponse, rejected, needsReconnect, timedOut
    public var errorDescription: String? {
        switch self {
        case .tooLarge: "This message or file is larger than the 25 MB import limit."
        case .invalidMessage: "This email could not be read. Share a PDF or image of the receipt instead."
        case .invalidServer: "Enter a valid IMAP hostname and use TLS on port 993."
        case .disconnected: "The mail server disconnected. Your saved scan position has not advanced."
        case .invalidResponse: "The mail server returned an unreadable response. Try again later."
        case .rejected: "The mail server rejected the login or command. Check the account and app password."
        case .needsReconnect: "Reconnect this email account to renew access."
        case .timedOut: "The mail server took too long to respond. Try again."
        }
    }
}

public enum MIMEReader {
    public static func parse(_ data: Data) throws -> ParsedMail {
        guard data.count <= 25 * 1024 * 1024 else { throw MailFailure.tooLarge }
        let root = try node(data, depth: 0)
        var bodies: [(String, String)] = [], attachments: [MailAttachment] = []
        func visit(_ part: Node) {
            if !part.children.isEmpty { part.children.forEach(visit); return }
            let type = part.headers["content-type"] ?? "text/plain"
            let mime = type.components(separatedBy: ";")[0].lowercased().trimmingCharacters(in: .whitespaces)
            let disposition = part.headers["content-disposition"] ?? ""
            let filename = parameter("filename", in: disposition) ?? parameter("name", in: type)
            let content = decodeBody(part.body, encoding: part.headers["content-transfer-encoding"] ?? "")
            if disposition.lowercased().contains("attachment") || (mime == "application/pdf" && filename != nil) {
                if attachments.count < 10 && (mime == "application/pdf" || mime.hasPrefix("image/")) { attachments.append(.init(filename: decodeHeader(filename ?? "receipt"), contentType: mime, data: content)) }
            } else if mime == "text/plain" || mime == "text/html" {
                let encoding = parameter("charset", in: type)?.lowercased()
                let decoded: String
                if encoding == "iso-8859-1" || encoding == "windows-1252" { decoded = String(data: content, encoding: .isoLatin1) ?? String(decoding: content, as: UTF8.self) }
                else { decoded = String(decoding: content, as: UTF8.self) }
                bodies.append((mime, decoded))
            }
        }
        visit(root)
        let plain = bodies.filter { $0.0 == "text/plain" }.map(\.1)
        let chosen = plain.isEmpty ? bodies.map(\.1) : plain
        let html = bodies.filter { $0.0 == "text/html" }.map { MailText.plain($0.1) }.joined(separator: "\n")
        let linkRegex = try NSRegularExpression(pattern: #"https://[^\s<>\"']+"#)
        let links = linkRegex.matches(in: html, range: NSRange(html.startIndex..., in: html)).compactMap { Range($0.range, in: html).map { String(html[$0]) } }.filter { TrackingDetector.safeURL($0) != nil }
        var date: Date?
        if let rawDate = root.headers["date"] {
            let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX")
            for format in ["EEE, d MMM yyyy HH:mm:ss Z", "d MMM yyyy HH:mm:ss Z", "EEE, d MMM yyyy HH:mm Z"] {
                formatter.dateFormat = format
                if let parsed = formatter.date(from: rawDate) { date = parsed; break }
            }
        }
        let plainText = chosen.map(MailText.plain).joined(separator: "\n") + (links.isEmpty ? "" : "\nTracking links:\n" + links.joined(separator: "\n"))
        return ParsedMail(subject: decodeHeader(root.headers["subject"] ?? ""), sender: decodeHeader(root.headers["from"] ?? ""), messageID: root.headers["message-id"] ?? "", plainText: plainText, attachments: attachments, date: date)
    }
    private struct Node { var headers: [String: String]; var body: Data; var children: [Node] }
    private static func node(_ data: Data, depth: Int) throws -> Node {
        guard depth < 12 else { throw MailFailure.invalidMessage }
        let separator = data.range(of: Data("\r\n\r\n".utf8)) ?? data.range(of: Data("\n\n".utf8))
        guard let separator else { return Node(headers: [:], body: data, children: []) }
        let rawHeaders = String(decoding: data[..<separator.lowerBound], as: UTF8.self).replacingOccurrences(of: "\r\n", with: "\n")
        var unfolded: [String] = []
        for line in rawHeaders.components(separatedBy: "\n") {
            if (line.hasPrefix(" ") || line.hasPrefix("\t")), !unfolded.isEmpty { unfolded[unfolded.count - 1] += " " + line.trimmingCharacters(in: .whitespaces) }
            else { unfolded.append(line) }
        }
        var headers: [String: String] = [:]
        for line in unfolded {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[String(line[..<colon]).lowercased()] = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
        }
        let body = Data(data[separator.upperBound...])
        var children: [Node] = []
        if let type = headers["content-type"], type.lowercased().hasPrefix("multipart/"), let boundary = parameter("boundary", in: type), !boundary.isEmpty, boundary.count < 200 {
            let delimiter = Data(("--" + boundary).utf8)
            var search = body.startIndex
            var starts: [Range<Data.Index>] = []
            while search < body.endIndex, let range = body.range(of: delimiter, in: search..<body.endIndex) {
                if range.lowerBound == 0 || body[body.index(before: range.lowerBound)] == 10 { starts.append(range) }
                search = range.upperBound
            }
            for (first, second) in zip(starts, starts.dropFirst()) {
                var start = first.upperBound, end = second.lowerBound
                if start + 1 < body.endIndex && body[start] == 45 && body[start + 1] == 45 { break }
                while start < end && (body[start] == 13 || body[start] == 10) { start += 1 }
                while end > start && (body[end - 1] == 13 || body[end - 1] == 10) { end -= 1 }
                if start < end { children.append(try node(Data(body[start..<end]), depth: depth + 1)) }
            }
        }
        return Node(headers: headers, body: body, children: children)
    }
    private static func parameter(_ name: String, in header: String) -> String? {
        let pattern = "(?:^|;)\\s*" + name + #"\s*=\s*(?:"([^"]*)"|([^;\s]*))"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive), let match = regex.firstMatch(in: header, range: NSRange(header.startIndex..., in: header)) else { return nil }
        for index in 1...2 { if let range = Range(match.range(at: index), in: header) { return String(header[range]) } }
        return nil
    }
    private static func decodeBody(_ data: Data, encoding: String) -> Data {
        if encoding.lowercased() == "base64" { return Data(base64Encoded: data, options: .ignoreUnknownCharacters) ?? Data() }
        if encoding.lowercased() != "quoted-printable" { return data }
        let bytes = Array(data); var output = Data(); var index = 0
        while index < bytes.count {
            if bytes[index] == 61, index + 1 < bytes.count {
                if bytes[index + 1] == 10 { index += 2; continue }
                if index + 2 < bytes.count, bytes[index + 1] == 13, bytes[index + 2] == 10 { index += 3; continue }
                if index + 2 < bytes.count, let value = UInt8(String(bytes: bytes[(index + 1)...(index + 2)], encoding: .ascii) ?? "", radix: 16) { output.append(value); index += 3; continue }
            }
            output.append(bytes[index]); index += 1
        }
        return output
    }
    public static func decodeHeader(_ text: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: #"=\?([^?]+)\?([bBqQ])\?([^?]*)\?="#) else { return text }
        var output = text
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).reversed() {
            guard let full = Range(match.range, in: output), let method = Range(match.range(at: 2), in: text), let body = Range(match.range(at: 3), in: text) else { continue }
            let encoded = String(text[body])
            let data = text[method].lowercased() == "b" ? Data(base64Encoded: encoded) : decodeBody(Data(encoded.replacingOccurrences(of: "_", with: " ").utf8), encoding: "quoted-printable")
            if let data { output.replaceSubrange(full, with: String(data: data, encoding: .utf8) ?? String(data: data, encoding: .isoLatin1) ?? "") }
        }
        return output
    }
}

public enum IMAPSyntax {
    public static func quote(_ value: String) throws -> String {
        guard !value.contains("\r"), !value.contains("\n"), !value.contains("\0") else { throw MailFailure.invalidResponse }
        return "\"" + value.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
    public static func searchUIDs(_ lines: [String]) -> [UInt64] { lines.filter { $0.uppercased().hasPrefix("* SEARCH") }.flatMap { $0.split(separator: " ").dropFirst(2).compactMap { UInt64($0) } }.sorted() }
    public static func uidValidity(_ lines: [String]) -> String? {
        for line in lines {
            if let range = line.range(of: #"(?i)\[UIDVALIDITY ([0-9]+)\]"#, options: .regularExpression) { return line[range].split(separator: " ").last.map { $0.replacingOccurrences(of: "]", with: "") } }
        }
        return nil
    }
    public static func literalLength(_ line: String) -> Int? {
        guard let range = line.range(of: #"\{([0-9]+)\+?\}$"#, options: .regularExpression) else { return nil }
        return Int(line[range].filter(\.isNumber))
    }
}
