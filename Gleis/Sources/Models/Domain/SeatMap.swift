import Foundation

enum SeatStatus: Equatable { case free, taken, unknown }

/// A place on a coach drawing. `label` is the ÖBB alternative text, such as "business sitz linksblickend".
struct SeatMapPlace: Identifiable, Equatable {
    let id: String
    let number: String?
    let x: Double
    let y: Double
    let isSeat: Bool
    let status: SeatStatus
    let travelClass: String?
    let facesLeft: Bool
    let label: String?
}

struct SeatMapFixture: Identifiable, Equatable {
    let id: String
    let x: Double
    let y: Double
    let kind: SeatMapFixtureKind
}

enum SeatMapFixtureKind: Equatable { case table, toilet, luggage, door, wall, other(Int) }

struct SeatMapCoachLayout: Equatable {
    let width: Double
    let height: Double
    let places: [SeatMapPlace]
    let fixtures: [SeatMapFixture]
}

struct SeatMapCoach: Identifiable, Equatable {
    /// The coach number painted on the train.
    let id: String
    /// "1", "2", or "B" for business.
    let travelClasses: [String]
    let freeSeatsByClass: [String: Int]
    let isReservationClosed: Bool
    /// ÖBB facility codes such as quietzone, familyzone or wifi.
    let facilities: [String]
    let layout: SeatMapCoachLayout?
}

struct SeatMap: Equatable {
    /// Category and number, such as "RJ 654".
    let rideName: String
    let fromName: String
    let toName: String
    /// Direction of travel on the drawing, with coaches drawn left to right in array order.
    let travelsLeft: Bool
    let coaches: [SeatMapCoach]

    var freeFirstClassSeats: Int {
        coaches.reduce(0) { $0 + ($1.freeSeatsByClass[SeatMap.firstClass] ?? 0) }
    }

    static let firstClass = "1"
}

struct LegSeatMap: Identifiable, Equatable {
    /// Index of the leg in the connection.
    let id: Int
    let lineName: String
    let fromName: String
    let toName: String
    let content: Content

    enum Content: Equatable {
        case notReservable
        /// Seats can be reserved, but ÖBB picks the seat: it publishes no seat map for this train.
        case reservableWithoutMap
        case map(SeatMap)
    }
}

// MARK: - Mapping From The ÖBB Graphical Reservation

extension SeatMap {
    private static let spotStatusNameFree = "free"
    private static let spotStatusNameTaken = "allocated"
    private static let spotStatusFree = 2
    private static let spotStatusTaken = 1
    /// ÖBB appends this to every place text; it describes the web page's selection state, not the seat.
    private static let selectedSuffix = "ausgewählt"
    private static let facingLeftDirection = "L"
    /// `trainHeadType` 1 marks the leading end of the train in the one capture there is; 2 marks the rear.
    private static let leadingHeadType = 1

    // Drawing element types, read from the alternative texts in a captured Railjet response.
    private static let tableTypes: Set<Int> = [22, 62, 70, 71]
    private static let toiletTypes: Set<Int> = [60, 69, 115, 221]
    private static let luggageTypes: Set<Int> = [109]
    private static let doorTypes: Set<Int> = [35, 39, 209, 223]
    private static let wallTypes: Set<Int> = [72, 74, 84, 207, 208, 210, 211, 212, 217, 225, 233, 234]

    /// Builds the seat map from a decoded `api/offer/v1/graphicalReservation` response for one ride.
    static func from(
        graphicalReservation response: OebbGraphicalReservationResponse,
        rideName: String,
        fromName: String,
        toName: String
    ) -> SeatMap {
        var layoutsById: [String: OebbCoachLayoutEntry] = [:]
        for layout in response.layouts {
            if let id = layout.id, layoutsById[id] == nil { layoutsById[id] = layout }
        }
        let coachLayouts = response.coaches.map { coach in coach.layoutId.flatMap { layoutsById[$0] } }
        let coaches = zip(response.coaches, coachLayouts).enumerated().map { index, pair in
            makeCoach(pair.0, layout: pair.1, fallbackId: String(index + 1))
        }
        let rearIsLeading = coachLayouts.last??.trainHeadType == leadingHeadType
            && coachLayouts.first??.trainHeadType != leadingHeadType
        return SeatMap(
            rideName: rideName,
            fromName: fromName,
            toName: toName,
            travelsLeft: !rearIsLeading,
            coaches: coaches
        )
    }

    private static func makeCoach(
        _ coach: OebbReservationCoach, layout: OebbCoachLayoutEntry?, fallbackId: String
    ) -> SeatMapCoach {
        var freeSeatsByClass: [String: Int] = [:]
        var availableClasses: [String] = []
        for availability in coach.available {
            guard let travelClass = availability.travelClass else { continue }
            if freeSeatsByClass[travelClass] == nil { availableClasses.append(travelClass) }
            freeSeatsByClass[travelClass, default: 0] += max(availability.count ?? 0, 0)
        }
        var compartmentClasses: [String] = []
        for travelClass in coach.compartments.compactMap(\.travelClass)
            where !compartmentClasses.contains(travelClass)
        {
            compartmentClasses.append(travelClass)
        }
        return SeatMapCoach(
            id: coach.number ?? fallbackId,
            travelClasses: availableClasses.isEmpty ? compartmentClasses : availableClasses,
            freeSeatsByClass: freeSeatsByClass,
            isReservationClosed: coach.isReservationClosed ?? false,
            facilities: layout?.facilityCodes ?? [],
            layout: layout.flatMap { makeLayout($0, coach: coach) }
        )
    }

    private static func makeLayout(_ layout: OebbCoachLayoutEntry, coach: OebbReservationCoach) -> SeatMapCoachLayout? {
        guard let width = layout.width, let height = layout.height, width > 0, height > 0 else { return nil }
        var spotsByNumber: [String: (spot: OebbReservationSpot, compartmentClass: String?)] = [:]
        for compartment in coach.compartments {
            for spot in compartment.spots {
                guard let number = spot.number, spotsByNumber[number] == nil else { continue }
                spotsByNumber[number] = (spot, compartment.travelClass)
            }
        }
        let places = layout.places.enumerated().compactMap { index, element -> SeatMapPlace? in
            guard let x = element.x, let y = element.y else { return nil }
            let match = element.number.flatMap { spotsByNumber[$0] }
            return SeatMapPlace(
                id: "place-\(index)-\(element.number ?? "")",
                number: element.number,
                x: x,
                y: y,
                isSeat: match != nil,
                status: match.map { seatStatus(of: $0.spot) } ?? .unknown,
                travelClass: match.flatMap { $0.spot.travelClass ?? $0.compartmentClass },
                facesLeft: element.direction == facingLeftDirection,
                label: placeLabel(element.germanText)
            )
        }
        let drawnElements = layout.internals.map { ("internal", $0) } + layout.signs.map { ("sign", $0) }
        let fixtures = drawnElements.enumerated().compactMap { index, pair -> SeatMapFixture? in
            guard let x = pair.1.x, let y = pair.1.y, let type = pair.1.type else { return nil }
            return SeatMapFixture(id: "\(pair.0)-\(index)", x: x, y: y, kind: fixtureKind(forType: type))
        }
        return SeatMapCoachLayout(width: width, height: height, places: places, fixtures: fixtures)
    }

    private static func seatStatus(of spot: OebbReservationSpot) -> SeatStatus {
        switch spot.statusName?.lowercased() {
        case spotStatusNameFree: return .free
        case spotStatusNameTaken: return .taken
        default: break
        }
        switch spot.status {
        case spotStatusFree: return .free
        case spotStatusTaken: return .taken
        default: return .unknown
        }
    }

    private static func placeLabel(_ text: String?) -> String? {
        guard var label = text?.trimmingCharacters(in: .whitespacesAndNewlines) else { return nil }
        if label.hasSuffix(selectedSuffix) {
            label = String(label.dropLast(selectedSuffix.count)).trimmingCharacters(in: .whitespaces)
        }
        return label.isEmpty ? nil : label
    }

    private static func fixtureKind(forType type: Int) -> SeatMapFixtureKind {
        if tableTypes.contains(type) { return .table }
        if toiletTypes.contains(type) { return .toilet }
        if luggageTypes.contains(type) { return .luggage }
        if doorTypes.contains(type) { return .door }
        if wallTypes.contains(type) { return .wall }
        return .other(type)
    }
}
