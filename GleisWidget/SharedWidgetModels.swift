import Foundation

// Widget target keeps lightweight copies of app-domain-only types
// required by the shared widget contract.
enum TransportType: String, Codable {
    case trainCommute = "Train"
}

struct TrainLineColors: Codable, Equatable, Hashable {
    let backgroundHex: String?
    let foregroundHex: String?
    let accentHex: String?
}

extension WidgetData {
    static let delayedPlaceholder = WidgetData(
        transportType: .trainCommute,
        connections: [
            WidgetConnection(
                id: "delayed",
                lineNumber: "REX3",
                departureTime: Date().addingTimeInterval(1200),
                arrivalTime: Date().addingTimeInterval(3000),
                destination: "Bratislava hl.st.",
                platform: "7",
                transfers: 0,
                delay: 5,
                stopCount: 8,
                hasReminder: false,
                isPinned: false
            ),
        ],
        leaveTimes: [Date().addingTimeInterval(900)],
        updatedAt: Date(),
        state: .fresh
    )
}
