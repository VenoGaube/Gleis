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
            regionaltrains: false,
            direct: false,
            changeTime: false,
            wheelchair: false,
            bikes: false,
            trains: false,
            motorail: false,
            droppedConnections: false
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
            type: "ADULT",
            id: 1_514_028_726,
            me: false,
            remembered: false,
            challengedFlags: .default,
            relations: [],
            cards: [],
            birthdateChangeable: true,
            birthdateDeletable: true,
            nameChangeable: true,
            passengerDeletable: true
        )
    }

    struct ChallengedFlags: Encodable {
        let hasHandicappedPass, hasAssistanceDog, hasWheelchair, hasAttendant: Bool
        static let `default` = ChallengedFlags(
            hasHandicappedPass: false,
            hasAssistanceDog: false,
            hasWheelchair: false,
            hasAttendant: false
        )
    }

    struct DebugFilter: Encodable {
        let noAggregationFilter, noEqclassFilter, noNrtpathFilter, noPaymentFilter: Bool
        let useTripartFilter, noVbxFilter, noCategoriesFilter: Bool
        static let `default` = DebugFilter(
            noAggregationFilter: false,
            noEqclassFilter: false,
            noNrtpathFilter: false,
            noPaymentFilter: false,
            useTripartFilter: false,
            noVbxFilter: false,
            noCategoriesFilter: false
        )
    }

    struct StationRef: Encodable {
        let latitude, longitude: Int
        let name: String
        let number: Int
    }
}
