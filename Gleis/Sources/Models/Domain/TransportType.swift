enum TransportType: String, CaseIterable, Codable, Identifiable {
    case trainCommute = "Train"

    var id: String { rawValue }
    var icon: String { "tram.fill" }
    var navigationTitle: String { "Train" }
}
