import Foundation

public enum Carrier: String, Codable, CaseIterable, Sendable { case ups, usps, fedex, amazon, unknown
    public var title: String { switch self { case .ups: "UPS"; case .usps: "USPS"; case .fedex: "FedEx"; case .amazon: "Amazon"; case .unknown: "Carrier" } }
}
public enum ShipmentStatus: String, Codable, CaseIterable, Sendable {
    case labelCreated, inTransit, outForDelivery, delivered, exception
    public var title: String { switch self { case .labelCreated: "Label created"; case .inTransit: "In transit"; case .outForDelivery: "Out for delivery"; case .delivered: "Delivered"; case .exception: "Needs attention" } }
}
public struct DetectedTracking: Codable, Equatable, Sendable {
    public var number: String
    public var carrier: Carrier
    public var url: String?
    public init(number: String, carrier: Carrier, url: String? = nil) { self.number = TrackingDetector.normalize(number); self.carrier = carrier; self.url = url }
}
public struct TrackingEvent: Identifiable, Codable, Sendable {
    public var id: String
    public var date: Date?
    public var description: String
    public var location: String?
    public init(id: String = UUID().uuidString, date: Date? = nil, description: String, location: String? = nil) { self.id = id; self.date = date; self.description = description; self.location = location }
}
public struct ShipmentValue: Identifiable, Codable, Sendable {
    public var id: String { trackingNumber }
    public var trackingNumber: String
    public var carrier: Carrier
    public var receiptID: String
    public var transactionID: String?
    public var status: ShipmentStatus
    public var eta: Date?
    public var lastEvent: String
    public var events: [TrackingEvent]
    public var trackingURL: String?
    public var lastCheckedAt: Date?
    public var deliveredAt: Date?
    public var liveAvailable: Bool
    public init(trackingNumber: String, carrier: Carrier, receiptID: String, transactionID: String? = nil, status: ShipmentStatus = .labelCreated, eta: Date? = nil, lastEvent: String = "", events: [TrackingEvent] = [], trackingURL: String? = nil, lastCheckedAt: Date? = nil, deliveredAt: Date? = nil, liveAvailable: Bool = false) {
        self.trackingNumber = TrackingDetector.normalize(trackingNumber); self.carrier = carrier; self.receiptID = receiptID; self.transactionID = transactionID
        self.status = status; self.eta = eta; self.lastEvent = lastEvent; self.events = events; self.trackingURL = trackingURL; self.lastCheckedAt = lastCheckedAt; self.deliveredAt = deliveredAt; self.liveAvailable = liveAvailable
    }
    public func canRefresh(now: Date = .now) -> Bool { carrier != .amazon && !trackingNumber.hasPrefix("LINK") && (lastCheckedAt.map { now.timeIntervalSince($0) >= 7200 } ?? true) }
    public func isArchived(now: Date = .now) -> Bool { status == .delivered && (deliveredAt.map { now.timeIntervalSince($0) >= 7 * 86400 } ?? false) }
}
public enum TrackingDetector {
    public static func normalize(_ text: String) -> String { text.uppercased().filter { $0.isASCII && ($0.isLetter || $0.isNumber) } }
    public static func carrier(_ number: String) -> Carrier {
        let number = normalize(number)
        if number.range(of: #"^1Z[A-Z0-9]{16}$"#, options: .regularExpression) != nil { return .ups }
        if number.range(of: #"^9[0-9]{19,21}$"#, options: .regularExpression) != nil { return .usps }
        if number.range(of: #"^(?:[0-9]{12}|[0-9]{15})$"#, options: .regularExpression) != nil { return .fedex }
        if number.hasPrefix("TBA") { return .amazon }
        return .unknown
    }
    public static func safeURL(_ text: String?) -> URL? {
        guard let text, let url = URL(string: text), url.scheme == "https", let host = url.host, !host.isEmpty, url.user == nil, url.password == nil else { return nil }
        return url
    }
    public static func carrierURL(number: String, carrier: Carrier) -> URL? {
        let normalized = normalize(number)
        guard !normalized.isEmpty else { return nil }
        switch carrier {
        case .ups: return URL(string: "https://www.ups.com/track?tracknum=\(normalized)")
        case .usps: return URL(string: "https://tools.usps.com/go/TrackConfirmAction?tLabels=\(normalized)")
        case .fedex: return URL(string: "https://www.fedex.com/fedextrack/?trknbr=\(normalized)")
        case .amazon, .unknown: return nil
        }
    }
    public static func detect(_ text: String) -> [DetectedTracking] {
        let pattern = #"\b(?:1Z[A-Z0-9]{16}|9[0-9]{19,21}|[0-9]{15}|[0-9]{12}|TBA[0-9]{8,20})\b"#
        guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return [] }
        let urls = (try? NSRegularExpression(pattern: #"https://[^\s<>\"']+"#, options: .caseInsensitive))?.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { Range($0.range, in: text).map { String(text[$0]).replacingOccurrences(of: "&amp;", with: "&") } } ?? []
        var seen = Set<String>()
        var results: [DetectedTracking] = regex.matches(in: text, range: NSRange(text.startIndex..., in: text)).compactMap { match in
            guard let range = Range(match.range, in: text) else { return nil }
            let number = normalize(String(text[range]))
            guard seen.insert(number).inserted else { return nil }
            let foundCarrier = carrier(number)
            if foundCarrier == .fedex {
                let lower = text.index(range.lowerBound, offsetBy: -100, limitedBy: text.startIndex) ?? text.startIndex
                let upper = text.index(range.upperBound, offsetBy: 100, limitedBy: text.endIndex) ?? text.endIndex
                let context = String(text[lower..<upper])
                guard ["track", "fedex", "shipping", "shipped"].contains(where: { context.localizedCaseInsensitiveContains($0) }) else { return nil }
            }
            let url = urls.first { $0.localizedCaseInsensitiveContains(number) && safeURL($0) != nil } ?? carrierURL(number: number, carrier: foundCarrier)?.absoluteString
            return DetectedTracking(number: number, carrier: foundCarrier, url: url)
        }
        for text in urls {
            guard let url = safeURL(text), let host = url.host, (host == "amazon.com" || host.hasSuffix(".amazon.com")), url.path.contains("progress-tracker"), !results.contains(where: { $0.carrier == .amazon }) else { continue }
            results.append(DetectedTracking(number: "LINK" + String(StableHash.sha256(text).prefix(24)), carrier: .amazon, url: text))
        }
        return results
    }
    public static func status(from text: String) -> ShipmentStatus? {
        let text = text.lowercased()
        if text.contains("not delivered") || text.contains("delivery exception") || text.contains("delivery failed") { return .exception }
        if text.contains("out for delivery") && !text.contains("not out for delivery") { return .outForDelivery }
        let futureDelivery = ["will be delivered", "expected to be delivered", "scheduled to be delivered", "should be delivered"].contains { text.contains($0) }
        if text.contains("delivered") && !futureDelivery { return .delivered }
        if text.contains("shipped") || text.contains("in transit") || text.contains("on the way") { return .inTransit }
        if text.contains("label created") { return .labelCreated }
        return nil
    }
}
