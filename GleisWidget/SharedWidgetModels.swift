import Foundation

// Compatibility types for the widget target.
// The widget runtime models now live in Gleis/Sources/Models/Widget/WidgetModels.swift.

enum TransportType: String, Codable {
    case trainCommute = "Train"
}

struct TrainLineColors: Codable, Equatable, Hashable {
    let backgroundHex: String?
    let foregroundHex: String?
    let accentHex: String?
}
