import CoreLocation
import Foundation

struct Station: Identifiable, Codable, Equatable, Hashable {
    let id: String
    let name: String
    let coordinate: Coordinate?
    let transportTypes: [TransportType]
    let lines: [String]
    let countryCode: String?
    let nearbyDistanceMeters: Double?
    let nearbyDurationSeconds: Double?

    struct Coordinate: Codable, Equatable, Hashable {
        let latitude: Double
        let longitude: Double
        var clLocation: CLLocationCoordinate2D { CLLocationCoordinate2D(latitude: latitude, longitude: longitude) }
    }

    init(
        id: String, name: String, coordinate: Coordinate?, transportTypes: [TransportType], lines: [String] = [],
        countryCode: String? = nil, nearbyDistanceMeters: Double? = nil, nearbyDurationSeconds: Double? = nil
    ) {
        self.id = id
        self.name = name
        self.coordinate = coordinate
        self.transportTypes = transportTypes
        self.lines = lines
        self.countryCode = countryCode
        self.nearbyDistanceMeters = nearbyDistanceMeters
        self.nearbyDurationSeconds = nearbyDurationSeconds
    }

    var flagEmoji: String? {
        guard let code = countryCode?.uppercased(), code.count == 2 else { return nil }
        let base: UInt32 = 127_397
        var emoji = ""
        for scalar in code.unicodeScalars {
            if let flag = UnicodeScalar(base + scalar.value) { emoji.append(String(flag)) }
        }
        return emoji.isEmpty ? nil : emoji
    }
}
