import Foundation
import SwiftData
import UserNotifications
import ActivityKit
import MonarchCore

@MainActor enum ShipmentTrackingService {
    private struct Response: Decodable, Sendable {
        struct Event: Decodable, Sendable { var id: String; var date: String?; var description: String; var location: String? }
        var available: Bool; var status: String?; var eta: String?; var lastEvent: String; var events: [Event]
    }
    static func date(_ raw: String?) -> Date? {
        guard let raw else { return nil }
        let formatter = ISO8601DateFormatter(); formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.date(from: raw) ?? ISO8601DateFormatter().date(from: raw) ?? LedgerDate.parse(String(raw.prefix(10)))
    }
    static func refresh(app: AppState) async {
        guard !ProcessInfo.processInfo.arguments.contains("--ui-testing"), !app.receipts.isRefreshingShipments else { return }
        app.receipts.isRefreshingShipments = true; defer { app.receipts.isRefreshingShipments = false }
        guard let key = try? app.appKey(), !key.isEmpty else { return } // no server configured: keep carrier links working
        let context = app.container.mainContext
        do {
            let shipments = try context.fetch(FetchDescriptor<ShipmentRecord>()).filter { $0.value.canRefresh() && !$0.value.isArchived() }
            guard !shipments.isEmpty else { return }
            let client = try app.client()
            guard try await client.health().environment == "sandbox" else { throw ProxyError(errorCode: "SANDBOX_REQUIRED") }
            for record in shipments {
                try Task.checkCancellation()
                var value = try record.decoded()
                let previous = value.status
                value.lastCheckedAt = .now
                try record.apply(value); try context.save() // persist the two-hour gate before the lookup, including failures
                do {
                    let response: Response = try await client.post("tracking", body: ["tracking_number": value.trackingNumber])
                    value.liveAvailable = response.available
                    if let status = response.status.flatMap(ShipmentStatus.init(rawValue:)) { value.status = status }
                    value.eta = date(response.eta) ?? value.eta
                    value.lastEvent = response.lastEvent
                    if !response.events.isEmpty { value.events = response.events.map { TrackingEvent(id: $0.id, date: date($0.date), description: $0.description, location: $0.location) } }
                    if value.status == .delivered && value.deliveredAt == nil { value.deliveredAt = value.events.first(where: { $0.description.localizedCaseInsensitiveContains("deliver") })?.date ?? .now }
                    try record.apply(value); try context.save()
                    let merchant = try context.fetch(FetchDescriptor<ReceiptRecord>()).first { $0.id == value.receiptID }?.merchant ?? "Your order"
                    await ShipmentAlerts.updated(value, merchant: merchant, previous: previous)
                } catch { app.receipts.lastError = error.localizedDescription }
            }
        } catch { app.receipts.lastError = error.localizedDescription }
    }
}

@MainActor enum ShipmentAlerts {
    static func requestNotifications() async throws -> Bool {
        try await UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .badge, .sound])
    }
    static func updated(_ shipment: ShipmentValue, merchant: String, previous: ShipmentStatus) async {
        if shipment.status == .outForDelivery && previous != .outForDelivery && UserDefaults.standard.bool(forKey: "shipmentNotifications") {
            let content = UNMutableNotificationContent()
            content.title = "A package is out for delivery"
            content.body = "Open Monarch to see the carrier and latest update."
            content.sound = .default
            try? await UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: "shipment-\(shipment.id)-out", content: content, trigger: nil))
        }
        let existing = Activity<ShipmentActivityAttributes>.activities.first { $0.attributes.trackingNumber == shipment.trackingNumber }
        let state = ShipmentActivityAttributes.ContentState(status: shipment.status.title, eta: shipment.eta)
        if let existing {
            if shipment.status == .delivered { await existing.end(ActivityContent(state: state, staleDate: nil), dismissalPolicy: .after(.now.addingTimeInterval(3600))) }
            else { await existing.update(ActivityContent(state: state, staleDate: .now.addingTimeInterval(7200))) }
        } else if shipment.status == .outForDelivery && UserDefaults.standard.bool(forKey: "shipmentLiveActivities") && ActivityAuthorizationInfo().areActivitiesEnabled {
            _ = try? Activity.request(attributes: ShipmentActivityAttributes(trackingNumber: shipment.trackingNumber, merchant: merchant, carrier: shipment.carrier.title), content: ActivityContent(state: state, staleDate: .now.addingTimeInterval(7200)), pushType: nil)
        }
    }
}
