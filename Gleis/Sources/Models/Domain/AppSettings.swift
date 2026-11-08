import Foundation

// MARK: - AppSettings

struct AppSettings: Codable {
    var hasCompletedOnboarding: Bool = false
    /// True when the stored blob still carries the removed ticket wallet, so it should be rewritten without it.
    private(set) var containsLegacyTicketData = false

    init() {}

    enum CodingKeys: String, CodingKey {
        case hasCompletedOnboarding
    }

    private enum LegacyCodingKeys: String, CodingKey {
        case ticketCards
        case selectedTicketId
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        hasCompletedOnboarding = try container.decodeIfPresent(Bool.self, forKey: .hasCompletedOnboarding) ?? false
        let legacyContainer = try decoder.container(keyedBy: LegacyCodingKeys.self)
        containsLegacyTicketData =
            legacyContainer.contains(.ticketCards) || legacyContainer.contains(.selectedTicketId)
    }
}
