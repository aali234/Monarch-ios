import Foundation
import ActivityKit

struct ShipmentActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        var status: String
        var eta: Date?
    }
    var trackingNumber: String
    var merchant: String
    var carrier: String
}
