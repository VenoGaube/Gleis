struct OebbTimetableRequest: Encodable {
    let reverse: Bool
    let datetimeDeparture: String
    let filter: Filter
    let passengers: [Passenger]
    let count: Int
    let debugFilter: DebugFilter
    let from: StationRef
    let to: StationRef
    let timeout: [String: String]

    struct Filter: Encodable {
        let regionaltrains, direct, changeTime, wheelchair: Bool
        let bikes, trains, motorail, droppedConnections: Bool
        static let `default` = Filter(
            regionaltrains: false, direct: false, changeTime: false, wheelchair: false, bikes: false, trains: false,
            motorail: false, droppedConnections: false
        )
    }

    struct Passenger: Encodable {
        let type: String
        let id: Int
        let me, remembered, markedForDeath: Bool
        let challengedFlags: ChallengedFlags
        let relations, cards: [String]
        let birthdateChangeable, birthdateDeletable, nameChangeable, passengerDeletable: Bool
        static let `default` = adult(id: 1_514_028_726)

        /// One adult passenger, the shape the shop sends; the seat lookup uses a fresh id per search like the browser.
        static func adult(id: Int) -> Passenger {
            Passenger(
                type: "ADULT", id: id, me: false, remembered: false, markedForDeath: false, challengedFlags: .default,
                relations: [], cards: [], birthdateChangeable: true, birthdateDeletable: true, nameChangeable: true,
                passengerDeletable: true
            )
        }
    }

    struct ChallengedFlags: Encodable {
        let hasHandicappedPass, hasAssistanceDog, hasWheelchair, hasAttendant: Bool
        static let `default` = ChallengedFlags(
            hasHandicappedPass: false, hasAssistanceDog: false, hasWheelchair: false, hasAttendant: false
        )
    }

    struct DebugFilter: Encodable {
        let noAggregationFilter, noEqclassFilter, noNrtpathFilter, noPaymentFilter: Bool
        let useTripartFilter, noVbxFilter, noCategoriesFilter: Bool
        static let `default` = DebugFilter(
            noAggregationFilter: false, noEqclassFilter: false, noNrtpathFilter: false, noPaymentFilter: false,
            useTripartFilter: false, noVbxFilter: false, noCategoriesFilter: false
        )
    }

    struct StationRef: Encodable {
        let latitude, longitude: Int
        let name: String
        let number: Int
    }
}

struct OebbGateTripSearchRequest: Encodable {
    let id: String
    let ver: String
    let lang: String
    let auth: Auth
    let client: Client
    let formatted: Bool
    let ext: String
    let svcReqL: [ServiceRequest]

    struct Auth: Encodable {
        let type: String
        let aid: String
    }

    struct Client: Encodable {
        let id: String
        let type: String
        let name: String
        let l: String
        let v: Int
    }

    struct ServiceRequest: Encodable {
        let meth: String
        let req: TripSearch
        let id: String?
    }

    struct TripSearch: Encodable {
        let depLocL: [LocationRef]
        let arrLocL: [LocationRef]
        /// Optional so it can be omitted entirely, letting the provider apply its own
        /// per-station minimum change times.
        let minChgTime: String?
        let liveSearch: Bool
        let maxChg: String
        let outFrwd: Bool
        let outTime: String
        let outDate: String
        let getPasslist: Bool
        let getTariff: Bool
        let getPolyline: Bool
        let numF: Int
        let ctxScr: String?
        let pt: OebbNullValue?
    }

    struct LocationRef: Encodable {
        let lid: String
        let name: String
    }
}

enum OebbNullValue: Encodable {
    case null

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encodeNil()
    }
}

/// Registers a timetable search with the shop; the offer endpoints only accept trips from a registered search.
struct OebbTravelActionsRequest: Encodable {
    struct Station: Encodable {
        let meta: String
        let latitude, longitude: Int
        let name: String
        let number: Int
    }

    struct Filter: Encodable {
        let productTypes: [String]
        let history: Bool
        let maxEntries: Int
        let channel: String
    }

    let departureTime: Bool
    let from: Station
    let to: Station
    let datetime: String
    let customerVias: [String]
    let travelActionTypes: [String]
    let filter: Filter
}

/// The shop timetable search as the browser sends it, tied to a travel action.
struct OebbSeatTimetableRequest: Encodable {
    struct Filter: Encodable {
        let regionaltrains, direct, wheelchair, bikes, trains, motorail: Bool
        let connections: [String]
        static let `default` = Filter(
            regionaltrains: false, direct: false, wheelchair: false, bikes: false, trains: false, motorail: false,
            connections: []
        )
    }

    let travelActionId: String
    let datetimeDeparture: String
    let filter: Filter
    let passengers: [OebbTimetableRequest.Passenger]
    let entryPointId: String
    let count: Int
    let debugFilter: OebbTimetableRequest.DebugFilter
    let sortType: String
    let from: OebbTimetableRequest.StationRef
    let to: OebbTimetableRequest.StationRef
}
