import Foundation

// MARK: - Seat Reservation Requests

/// Body of `api/offer/v6/offers`: the offers for one shop connection, priced for the given passengers.
struct OebbOffersRequest: Encodable {
    let selection: OebbOfferSelection
    let ignoreSelectionOnOfferChange: Bool
    let passengers: [OebbTimetableRequest.Passenger]
    let debugFilter: OebbTimetableRequest.DebugFilter
    let datetime: String
}

struct OebbOfferSelection: Encodable {
    let connectionId: String
    let offerSections: [OebbReservationOfferSelection]
}

/// One offer section with its seat-reservation-only offer picked, as `api/offer/v1/reservation-details` expects.
struct OebbReservationOfferSelection: Encodable {
    struct ReservationOnly: Encodable {
        let isSelected: Bool
        let offerId: String
        let travelClass: String

        enum CodingKeys: String, CodingKey {
            case isSelected, offerId
            case travelClass = "class"
        }
    }

    let reservationOnly: ReservationOnly
    let id: String
}

struct OebbReservationDetailsRequest: Encodable {
    let selection: OebbOfferSelection
}

// MARK: - Seat Reservation Responses

struct OebbOffersResponse: Decodable {
    /// Nil when the key is missing or not an array, so a broken reply is not read as a trip with no sections.
    let offerSections: [OebbOfferSection]?
    let offerError: Bool

    enum CodingKeys: String, CodingKey { case offerSections, offerError }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        offerSections = OebbDecoding.lossyArrayIfPresent(container, forKey: .offerSections)
        offerError = OebbDecoding.boolIfPresent(container, forKey: .offerError) ?? false
    }
}

struct OebbOfferSection: Decodable {
    let id: String?
    /// Offers that buy a seat reservation alone, one per travel class.
    let reservationOffers: [OebbReservationOffer]

    enum CodingKeys: String, CodingKey { case id, reservationOnly }
    enum ReservationOnlyKeys: String, CodingKey { case offers }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = OebbDecoding.stringIfPresent(container, forKey: .id)
        let reservationOnly = try? container.nestedContainer(
            keyedBy: ReservationOnlyKeys.self, forKey: .reservationOnly
        )
        reservationOffers = reservationOnly.flatMap { OebbDecoding.lossyArrayIfPresent($0, forKey: .offers) } ?? []
    }
}

struct OebbReservationOffer: Decodable {
    let id: String?
    let travelClass: String?

    enum CodingKeys: String, CodingKey {
        case id
        case travelClass = "class"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = OebbDecoding.stringIfPresent(container, forKey: .id)
        travelClass = OebbDecoding.stringIfPresent(container, forKey: .travelClass)
    }
}

struct OebbReservationDetailsResponse: Decodable {
    let sections: [OebbReservationDetailsSection]

    enum CodingKeys: String, CodingKey { case sections }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        sections = OebbDecoding.lossyArrayIfPresent(container, forKey: .sections) ?? []
    }
}

/// One leg of the connection. `graphical` is nil when ÖBB offers no reservation on it, such as a regional train.
struct OebbReservationDetailsSection: Decodable {
    let index: Int?
    let type: String?
    let fromName: String?
    let toName: String?
    let rideShortName: String?
    let rideNumber: String?
    let graphical: OebbGraphicalAvailability?

    enum CodingKeys: String, CodingKey { case index, type, from, to, ride, reservationDetails }
    enum StopKeys: String, CodingKey { case name }
    enum RideKeys: String, CodingKey { case shortName, number }
    enum ReservationDetailsKeys: String, CodingKey { case graphical }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        index = OebbDecoding.intIfPresent(container, forKey: .index)
        type = OebbDecoding.stringIfPresent(container, forKey: .type)
        let from = try? container.nestedContainer(keyedBy: StopKeys.self, forKey: .from)
        fromName = from.flatMap { OebbDecoding.stringIfPresent($0, forKey: .name) }
        let to = try? container.nestedContainer(keyedBy: StopKeys.self, forKey: .to)
        toName = to.flatMap { OebbDecoding.stringIfPresent($0, forKey: .name) }
        let ride = try? container.nestedContainer(keyedBy: RideKeys.self, forKey: .ride)
        rideShortName = ride.flatMap { OebbDecoding.stringIfPresent($0, forKey: .shortName) }
        rideNumber = ride.flatMap { OebbDecoding.stringIfPresent($0, forKey: .number) }
        let details = try? container.nestedContainer(keyedBy: ReservationDetailsKeys.self, forKey: .reservationDetails)
        graphical = details.flatMap { try? $0.decodeIfPresent(OebbGraphicalAvailability.self, forKey: .graphical) }
    }
}

struct OebbGraphicalAvailability: Decodable {
    let isAvailable: Bool?
    let ride: OebbGraphicalRide?

    enum CodingKeys: String, CodingKey { case isAvailable, ride }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isAvailable = OebbDecoding.boolIfPresent(container, forKey: .isAvailable)
        ride = try? container.decodeIfPresent(OebbGraphicalRide.self, forKey: .ride)
    }
}

/// The ride key `api/offer/v1/graphicalReservation` takes as its query. Station numbers arrive as integers.
struct OebbGraphicalRide: Decodable {
    let category: String?
    let number: String?
    let from: String?
    let to: String?
    let departure: String?
    let origin: String?
    let originDeparture: String?
    let destination: String?

    enum CodingKeys: String, CodingKey {
        case category, number, from, to, departure, origin, originDeparture, destination
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        category = OebbDecoding.stringIfPresent(container, forKey: .category)
        number = OebbDecoding.stringIfPresent(container, forKey: .number)
        from = OebbDecoding.stringIfPresent(container, forKey: .from)
        to = OebbDecoding.stringIfPresent(container, forKey: .to)
        departure = OebbDecoding.stringIfPresent(container, forKey: .departure)
        origin = OebbDecoding.stringIfPresent(container, forKey: .origin)
        originDeparture = OebbDecoding.stringIfPresent(container, forKey: .originDeparture)
        destination = OebbDecoding.stringIfPresent(container, forKey: .destination)
    }
}

struct OebbGraphicalReservationResponse: Decodable {
    let layouts: [OebbCoachLayoutEntry]
    let coaches: [OebbReservationCoach]

    enum CodingKeys: String, CodingKey { case layouts, coaches }

    init(layouts: [OebbCoachLayoutEntry], coaches: [OebbReservationCoach]) {
        self.layouts = layouts
        self.coaches = coaches
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        layouts = OebbDecoding.lossyArrayIfPresent(container, forKey: .layouts) ?? []
        coaches = OebbDecoding.lossyArrayIfPresent(container, forKey: .coaches) ?? []
    }
}

/// A coach drawing: `gridSize`, the places, and the signs and internals drawn around them.
struct OebbCoachLayoutEntry: Decodable {
    let id: String?
    let width: Double?
    let height: Double?
    let places: [OebbLayoutElement]
    let signs: [OebbLayoutElement]
    let internals: [OebbLayoutElement]
    let facilityCodes: [String]
    let trainHeadType: Int?

    enum CodingKeys: String, CodingKey { case id, layout, coachFacilities, trainHeadType }
    enum LayoutKeys: String, CodingKey { case gridSize, places, signs, internals }
    enum GridSizeKeys: String, CodingKey { case width, height }
    enum FacilityKeys: String, CodingKey { case code }

    private struct Facility: Decodable {
        let code: String?

        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: FacilityKeys.self)
            code = OebbDecoding.stringIfPresent(container, forKey: .code)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = OebbDecoding.stringIfPresent(container, forKey: .id)
        trainHeadType = OebbDecoding.intIfPresent(container, forKey: .trainHeadType)
        let facilities: [Facility] = OebbDecoding.lossyArrayIfPresent(container, forKey: .coachFacilities) ?? []
        facilityCodes = facilities.compactMap(\.code)

        let layout = try? container.nestedContainer(keyedBy: LayoutKeys.self, forKey: .layout)
        let gridSize = layout.flatMap { try? $0.nestedContainer(keyedBy: GridSizeKeys.self, forKey: .gridSize) }
        width = gridSize.flatMap { OebbDecoding.doubleIfPresent($0, forKey: .width) }
        height = gridSize.flatMap { OebbDecoding.doubleIfPresent($0, forKey: .height) }
        places = layout.flatMap { OebbDecoding.lossyArrayIfPresent($0, forKey: .places) } ?? []
        signs = layout.flatMap { OebbDecoding.lossyArrayIfPresent($0, forKey: .signs) } ?? []
        internals = layout.flatMap { OebbDecoding.lossyArrayIfPresent($0, forKey: .internals) } ?? []
    }
}

/// A place, sign or internal on a coach drawing. `nb` is the seat number and `direction` is "L" or "R".
struct OebbLayoutElement: Decodable {
    let type: Int?
    let x: Double?
    let y: Double?
    let number: String?
    let direction: String?
    let germanText: String?

    enum CodingKeys: String, CodingKey {
        case type, x, y, direction, alternativeTexts
        case number = "nb"
    }

    enum TextKeys: String, CodingKey { case de }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        type = OebbDecoding.intIfPresent(container, forKey: .type)
        x = OebbDecoding.doubleIfPresent(container, forKey: .x)
        y = OebbDecoding.doubleIfPresent(container, forKey: .y)
        number = OebbDecoding.stringIfPresent(container, forKey: .number)
        direction = OebbDecoding.stringIfPresent(container, forKey: .direction)
        let texts = try? container.nestedContainer(keyedBy: TextKeys.self, forKey: .alternativeTexts)
        germanText = texts.flatMap { OebbDecoding.stringIfPresent($0, forKey: .de) }
    }
}

struct OebbReservationCoach: Decodable {
    let number: String?
    let layoutId: String?
    let compartments: [OebbReservationCompartment]
    let isReservationClosed: Bool?
    let available: [OebbCoachAvailability]

    enum CodingKeys: String, CodingKey {
        case number, compartments, available
        case layoutId = "layout"
        case isReservationClosed = "reservationClosed"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = OebbDecoding.stringIfPresent(container, forKey: .number)
        layoutId = OebbDecoding.stringIfPresent(container, forKey: .layoutId)
        compartments = OebbDecoding.lossyArrayIfPresent(container, forKey: .compartments) ?? []
        isReservationClosed = OebbDecoding.boolIfPresent(container, forKey: .isReservationClosed)
        available = OebbDecoding.lossyArrayIfPresent(container, forKey: .available) ?? []
    }
}

struct OebbReservationCompartment: Decodable {
    let travelClass: String?
    let spots: [OebbReservationSpot]

    enum CodingKeys: String, CodingKey {
        case spots
        case travelClass = "class"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        travelClass = OebbDecoding.stringIfPresent(container, forKey: .travelClass)
        spots = OebbDecoding.lossyArrayIfPresent(container, forKey: .spots) ?? []
    }
}

/// A bookable seat. The capture shows `statusName` "free" with `status` 2 and "allocated" with `status` 1.
struct OebbReservationSpot: Decodable {
    let number: String?
    let status: Int?
    let statusName: String?
    let travelClass: String?

    enum CodingKeys: String, CodingKey {
        case number, status, statusName
        case travelClass = "class"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        number = OebbDecoding.stringIfPresent(container, forKey: .number)
        status = OebbDecoding.intIfPresent(container, forKey: .status)
        statusName = OebbDecoding.stringIfPresent(container, forKey: .statusName)
        travelClass = OebbDecoding.stringIfPresent(container, forKey: .travelClass)
    }
}

struct OebbCoachAvailability: Decodable {
    let count: Int?
    let travelClass: String?

    enum CodingKeys: String, CodingKey {
        case count
        case travelClass = "class"
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        count = OebbDecoding.intIfPresent(container, forKey: .count)
        travelClass = OebbDecoding.stringIfPresent(container, forKey: .travelClass)
    }
}

/// A reply whose body Gleis does not read, decoded only to confirm the call succeeded.
struct OebbIgnoredResponse: Decodable {
    init(from decoder: Decoder) throws {}
}

struct OebbTravelActionsResponse: Decodable {
    struct TravelAction: Decodable {
        let id: String
        let type: String?
    }

    let travelActions: [TravelAction]
}
