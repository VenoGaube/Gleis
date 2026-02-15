import CoreLocation
import Foundation

// MARK: - AppSettings

struct AppSettings: Codable {
    var useLocationForStartStation: Bool = true
    var useSmartStationSwap: Bool = true
    var hasCompletedOnboarding: Bool = false
    var ticketCards: [TicketCard] = []
    var selectedTicketId: UUID?
    var autoSelectionPreferences: AutoSelectionPreferences = .init()

    init() {}

    enum CodingKeys: String, CodingKey {
        case useLocationForStartStation
        case useSmartStationSwap
        case hasCompletedOnboarding
        case ticketCards
        case selectedTicketId
        case autoSelectionPreferences
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        useLocationForStartStation = try container.decodeIfPresent(Bool.self, forKey: .useLocationForStartStation) ?? true
        useSmartStationSwap = try container.decodeIfPresent(Bool.self, forKey: .useSmartStationSwap) ?? true
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        ticketCards = try container.decodeIfPresent([TicketCard].self, forKey: .ticketCards) ?? []
        selectedTicketId = try container.decodeIfPresent(UUID.self, forKey: .selectedTicketId)
        autoSelectionPreferences = try container.decodeIfPresent(AutoSelectionPreferences.self, forKey: .autoSelectionPreferences)
            ?? .init()
    }

    mutating func setAutoSelectionExcluded(_ stationId: String, excluded: Bool) {
        autoSelectionPreferences.setExcluded(stationId, excluded: excluded)
    }

    mutating func setPreferredAutoStation(
        stationId: String,
        stationName: String,
        location: CLLocation,
        radiusMeters: CLLocationDistance = 2_000
    ) {
        autoSelectionPreferences.setPreferredStation(
            stationId: stationId,
            stationName: stationName,
            latitude: location.coordinate.latitude,
            longitude: location.coordinate.longitude,
            radiusMeters: radiusMeters
        )
    }
}

// MARK: - AutoSelectionPreferences

struct AutoSelectionPreferences: Codable, Equatable {
    var excludedStationIds: Set<String> = []
    var areaPreferences: [PreferredAutoStationArea] = []

    mutating func setExcluded(_ stationId: String, excluded: Bool) {
        if excluded {
            excludedStationIds.insert(stationId)
        } else {
            excludedStationIds.remove(stationId)
        }
    }

    mutating func setPreferredStation(
        stationId: String,
        stationName: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: CLLocationDistance
    ) {
        let location = CLLocation(latitude: latitude, longitude: longitude)

        if let index = areaPreferences.enumerated().min(
            by: {
                $0.element.distance(to: location) < $1.element.distance(to: location)
            }
        ).map(\.offset),
            areaPreferences[index].distance(to: location) <= max(radiusMeters, areaPreferences[index].radiusMeters)
        {
            areaPreferences[index].stationId = stationId
            areaPreferences[index].stationName = stationName
            areaPreferences[index].latitude = latitude
            areaPreferences[index].longitude = longitude
            areaPreferences[index].radiusMeters = radiusMeters
            areaPreferences[index].updatedAt = Date()
        } else {
            areaPreferences.append(
                PreferredAutoStationArea(
                    stationId: stationId,
                    stationName: stationName,
                    latitude: latitude,
                    longitude: longitude,
                    radiusMeters: radiusMeters
                )
            )
        }

        // Keep only the newest rules to avoid unbounded growth.
        if areaPreferences.count > 20 {
            areaPreferences = areaPreferences
                .sorted(by: { $0.updatedAt > $1.updatedAt })
                .prefix(20)
                .map { $0 }
        }
    }

    func preferredStationId(near location: CLLocation) -> String? {
        areaPreferences
            .filter { $0.contains(location: location) }
            .min(by: { $0.distance(to: location) < $1.distance(to: location) })?
            .stationId
    }
}

// MARK: - PreferredAutoStationArea

struct PreferredAutoStationArea: Identifiable, Codable, Equatable {
    let id: UUID
    var stationId: String
    var stationName: String
    var latitude: Double
    var longitude: Double
    var radiusMeters: CLLocationDistance
    var updatedAt: Date

    init(
        id: UUID = UUID(),
        stationId: String,
        stationName: String,
        latitude: Double,
        longitude: Double,
        radiusMeters: CLLocationDistance
    ) {
        self.id = id
        self.stationId = stationId
        self.stationName = stationName
        self.latitude = latitude
        self.longitude = longitude
        self.radiusMeters = radiusMeters
        updatedAt = Date()
    }

    func contains(location: CLLocation) -> Bool { distance(to: location) <= radiusMeters }

    func distance(to location: CLLocation) -> CLLocationDistance {
        CLLocation(latitude: latitude, longitude: longitude).distance(from: location)
    }
}

// MARK: - TicketCard

struct TicketCard: Identifiable, Codable, Equatable {
    let id: UUID
    var name: String
    var frontImageData: Data?
    var backImageData: Data?
    var createdAt: Date

    init(id: UUID = UUID(), name: String, frontImageData: Data? = nil, backImageData: Data? = nil) {
        self.id = id
        self.name = name
        self.frontImageData = frontImageData
        self.backImageData = backImageData
        createdAt = Date()
    }
}
