import Foundation

struct RulePackDeliveryStats: Sendable, Equatable {
    var droppedHits: Int64
    var droppedKeys: Int64
}
