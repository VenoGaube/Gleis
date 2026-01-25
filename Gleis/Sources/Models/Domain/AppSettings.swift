import Foundation

// MARK: - AppSettings

struct AppSettings: Codable {
    var locationPermissionGranted: Bool = false
    var useLocationForStartStation: Bool = true
    var useSmartStationSwap: Bool = true
    var allowManualOverride: Bool = true
    var hasCompletedOnboarding: Bool = false
    var ticketCards: [TicketCard] = []
    var selectedTicketId: UUID?
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
        self.createdAt = Date()
    }
}

// MARK: - StationBoardEntry

struct StationBoardEntry: Identifiable {
    let id: String
    let scheduledTime: String
    let actualTime: String?
    let product: String
    let destination: String
    let platform: String?
    let platformChanged: Bool
    let delayMinutes: Int
    let isCancelled: Bool

    var isDelayed: Bool { delayMinutes > 0 }
}
