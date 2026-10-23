import ActivityKit
import WidgetKit
import SwiftUI

@main struct MonarchShipmentWidgets: WidgetBundle {
    var body: some Widget { ShipmentActivityWidget() }
}
struct ShipmentActivityWidget: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: ShipmentActivityAttributes.self) { context in
            HStack(spacing: 14) {
                Image(systemName: "shippingbox.fill").font(.title2)
                VStack(alignment: .leading, spacing: 5) { Text(context.attributes.merchant).font(.headline); Text(context.state.status).font(.subheadline); Text(context.attributes.carrier).font(.caption) }
                Spacer()
                if let eta = context.state.eta { Text(eta, style: .date).font(.caption) }
            }.padding().activityBackgroundTint(Color(red: 0.13, green: 0.29, blue: 0.24)).activitySystemActionForegroundColor(.white).foregroundStyle(.white)
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) { Image(systemName: "shippingbox.fill") }
                DynamicIslandExpandedRegion(.trailing) { Text(context.attributes.carrier).font(.caption) }
                DynamicIslandExpandedRegion(.bottom) { VStack(alignment: .leading) { Text(context.attributes.merchant).font(.headline); Text(context.state.status).font(.caption) } }
            } compactLeading: { Image(systemName: "shippingbox.fill") } compactTrailing: { Image(systemName: "truck.box") } minimal: { Image(systemName: "shippingbox.fill") }
        }
    }
}
