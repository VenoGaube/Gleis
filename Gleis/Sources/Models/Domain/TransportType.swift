import Foundation

enum TransportType: String, CaseIterable, Codable, Identifiable {
    case trainCommute = "Train"

    var id: String { rawValue }
    var icon: String { "tram.fill" }
    var tabTitle: String { "Train" }
    var navigationTitle: String { "Train" }
    var accentColor: String { "trainBlue" }
}
