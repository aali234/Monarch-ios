import SwiftUI
import SwiftData
import MonarchCore

struct ShipmentsView: View {
    @Environment(AppState.self) private var app
    @Query private var shipments: [ShipmentRecord]
    @Query private var receipts: [ReceiptRecord]
    @State private var archived = false
    var body: some View {
        List {
            Section {
                Toggle("Show archived deliveries", isOn: $archived)
                Text("Carrier lookups run at most once every two hours per shipment. Tracking links stay available when live updates aren’t supported.").font(.caption).foregroundStyle(Palette.secondary)
                if app.receipts.isRefreshingShipments { ProgressView("Checking carriers…") }
                if let error = app.receipts.lastError { Text(error).font(.caption).foregroundStyle(Palette.orange) }
            }
            ForEach(ShipmentStatus.allCases, id: \.self) { status in
                let records = shipments.filter { $0.statusRaw == status.rawValue && (archived || !$0.value.isArchived()) }
                if !records.isEmpty {
                    Section(status.title) {
                        ForEach(records) { shipment in
                            NavigationLink { ShipmentDetailView(record: shipment) } label: {
                                let receipt = receipts.first { $0.id == shipment.receiptID }
                                VStack(alignment: .leading, spacing: 8) {
                                    HStack { Text(receipt?.merchant ?? "Your order").font(.headline); Spacer(); if let amount = receipt?.total { AmountText(amount: amount, currency: receipt?.value.currency ?? "USD").font(.subheadline) } }
                                    HStack {
                                        Label(shipment.value.carrier.title, systemImage: status == .delivered ? "checkmark.circle" : "shippingbox")
                                        Spacer()
                                        if let date = shipment.value.eta { Text(date, format: .dateTime.month(.abbreviated).day()) }
                                    }.font(.caption).foregroundStyle(Palette.secondary)
                                    if receipt?.transactionID != nil { Label("Linked to purchase", systemImage: "link").font(.caption2).foregroundStyle(Palette.forest) }
                                    if !shipment.value.liveAvailable { Text("Carrier link available").font(.caption2).foregroundStyle(Palette.secondary) }
                                }.padding(.vertical, 7)
                            }
                        }
                    }
                }
            }
            if shipments.isEmpty { EmptyCard(title: "Know what’s on the way", message: "Tracking numbers from receipts and order emails appear here. You can also add one to a receipt.", symbol: "shippingbox") }
        }.navigationTitle("Shipments").navigationBarTitleDisplayMode(.inline)
            .refreshable { await ShipmentTrackingService.refresh(app: app) }
            .toolbar { Button { Task { await ShipmentTrackingService.refresh(app: app) } } label: { Image(systemName: "arrow.clockwise") }.disabled(app.receipts.isRefreshingShipments) }
            .task { await ShipmentTrackingService.refresh(app: app) }
    }
}

private struct ShipmentDetailView: View {
    let record: ShipmentRecord
    @Environment(AppState.self) private var app
    @Query private var receipts: [ReceiptRecord]
    @Query private var transactions: [TransactionRecord]
    private var value: ShipmentValue { record.value }
    var body: some View {
        List {
            Section(value.status.title) {
                Text(receipts.first { $0.id == value.receiptID }?.merchant ?? "Your order").font(.title2)
                LabeledContent("Carrier", value: value.carrier.title)
                Text(value.trackingNumber.hasPrefix("LINK") ? "Tracking link only" : value.trackingNumber).font(.caption).textSelection(.enabled)
                if let eta = value.eta { LabeledContent("Estimated delivery", value: eta.formatted(date: .abbreviated, time: .omitted)) }
                if !value.lastEvent.isEmpty { Text(value.lastEvent).font(.subheadline) }
                if let url = TrackingDetector.safeURL(value.trackingURL) ?? TrackingDetector.carrierURL(number: value.trackingNumber, carrier: value.carrier) { Link("Open carrier tracking", destination: url) }
                if let receipt = receipts.first(where: { $0.id == value.receiptID }) { NavigationLink("Receipt & order details") { ReceiptDetailView(record: receipt) } }
                if let transaction = transactions.first(where: { $0.id == value.transactionID }) { NavigationLink("Linked transaction") { TransactionDetailView(transaction: transaction) } }
            }
            Section("Timeline") {
                ForEach(value.events) { event in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(event.description).font(.subheadline)
                        if let location = event.location { Text(location).font(.caption).foregroundStyle(Palette.secondary) }
                        if let date = event.date { Text(date.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(Palette.secondary) }
                    }.padding(.vertical, 5)
                }
                if value.events.isEmpty { Text("The carrier has no live timeline available. Use the tracking link for the latest information.").font(.caption).foregroundStyle(Palette.secondary) }
            }
            Section {
                if let checked = value.lastCheckedAt { LabeledContent("Last checked", value: checked.formatted(date: .abbreviated, time: .shortened)) }
                Button("Check eligible shipments") { Task { await ShipmentTrackingService.refresh(app: app) } }.disabled(!value.canRefresh() || app.receipts.isRefreshingShipments)
                Text("Delivered orders leave the active list after seven days. Their receipts and tracking history are retained.").font(.caption).foregroundStyle(Palette.secondary)
            }
        }.navigationTitle("Shipment").navigationBarTitleDisplayMode(.inline)
    }
}
