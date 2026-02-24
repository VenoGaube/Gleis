import Foundation

// MARK: - AppSettings

struct AppSettings: Codable {
    var hasCompletedOnboarding: Bool = false
    var ticketCards: [TicketCard] = []
    var selectedTicketId: UUID?

    init() {}

    enum CodingKeys: String, CodingKey {
        case hasCompletedOnboarding
        case ticketCards
        case selectedTicketId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        ticketCards = try container.decodeIfPresent([TicketCard].self, forKey: .ticketCards) ?? []
        selectedTicketId = try container.decodeIfPresent(UUID.self, forKey: .selectedTicketId)
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
