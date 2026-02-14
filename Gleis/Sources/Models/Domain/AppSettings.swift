import Foundation

// MARK: - AppSettings

struct AppSettings: Codable {
    var useLocationForStartStation: Bool = true
    var useSmartStationSwap: Bool = true
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
        createdAt = Date()
    }
}
