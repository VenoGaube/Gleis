import Foundation

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
        let me, remembered: Bool
        let challengedFlags: ChallengedFlags
        let relations, cards: [String]
        let birthdateChangeable, birthdateDeletable, nameChangeable, passengerDeletable: Bool
        static let `default` = Passenger(
            type: "ADULT", id: 1_514_028_726, me: false, remembered: false, challengedFlags: .default, relations: [],
            cards: [], birthdateChangeable: true, birthdateDeletable: true, nameChangeable: true,
            passengerDeletable: true
        )
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

struct OebbGateRequest: Encodable {
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
        let pos: Position
    }

    struct Position: Encodable {
        let x: Int
        let y: Int
        let acc: Int
    }

    struct ServiceRequest: Encodable {
        let meth: String
        let req: LocGeoPosRequest
    }

    struct LocGeoPosRequest: Encodable {
        let centerCrd: Coordinate
        let getPOIs: Bool
        let getStops: Bool
        let maxLoc: Int
    }

    struct Coordinate: Encodable {
        let y: Int
        let x: Int
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
        let minChgTime: String
        let liveSearch: Bool
        let maxChg: String
        let outFrwd: Bool
        let outTime: String
        let outDate: String
        let getPasslist: Bool
        let getTariff: Bool
        let getPolyline: Bool
        let numF: Int
    }

    struct LocationRef: Encodable {
        let lid: String
        let name: String
    }
}
