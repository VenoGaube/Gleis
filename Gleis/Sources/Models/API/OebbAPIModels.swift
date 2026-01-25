import Foundation

// MARK: - OebbAuthSession

struct OebbAuthSession: Codable {
    let userId: String
    let accessToken: String
    let sessionId: String
    let supportId: String
    let channel: String
    let cookie: String?
    let expiresAt: Date
    let createdAt: Date

    var isExpired: Bool { Date() >= expiresAt }
}

// MARK: - OebbAuthResponse

struct OebbAuthResponse: Decodable {
    let accessToken: String
    let sessionId: String
    let supportId: String
    let channel: String?
    let sessionTimeout: Int?
    let userId: String?
}

// MARK: - OebbStation

struct OebbStation: Decodable {
    let number: Int
    let longitude: Int
    let latitude: Int
    let name: String?
    let meta: String?
}

// MARK: - OebbStationRef

struct OebbStationRef {
    let number: Int
    let latitude: Int
    let longitude: Int
    let name: String
}

// MARK: - OebbTimetableResponse

struct OebbTimetableResponse: Decodable {
    let connections: [OebbConnection]

    enum CodingKeys: String, CodingKey { case connections }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.connections = (try? container.decodeIfPresent([OebbConnection].self, forKey: .connections)) ?? []
    }
}

// MARK: - OebbConnection

struct OebbConnection: Decodable {
    let id: String
    let from: OebbConnectionStop
    let to: OebbConnectionStop
    let sections: [OebbSection]?
    let switches: Int?
    let duration: Int?

    enum CodingKeys: String, CodingKey {
        case id, from, to, sections, switches, duration
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.id = try container.decode(String.self, forKey: .id)
        self.from = try container.decode(OebbConnectionStop.self, forKey: .from)
        self.to = try container.decode(OebbConnectionStop.self, forKey: .to)
        self.sections = try? container.decodeIfPresent([OebbSection].self, forKey: .sections)
        self.switches = OebbDecoding.intIfPresent(container, forKey: .switches)
        self.duration = OebbDecoding.intIfPresent(container, forKey: .duration)
    }
}

// MARK: - OebbSection

struct OebbSection: Decodable {
    let from: OebbConnectionStop
    let to: OebbConnectionStop
    let duration: Int?
    let category: OebbCategory?
    let type: String?
    let hasRealtime: Bool?
    let stops: [OebbConnectionStop]?

    enum CodingKeys: String, CodingKey {
        case from, to, duration, category, type, hasRealtime, stops
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.from = try container.decode(OebbConnectionStop.self, forKey: .from)
        self.to = try container.decode(OebbConnectionStop.self, forKey: .to)
        self.duration = OebbDecoding.intIfPresent(container, forKey: .duration)
        self.category = try container.decodeIfPresent(OebbCategory.self, forKey: .category)
        self.type = try container.decodeIfPresent(String.self, forKey: .type)
        self.hasRealtime = OebbDecoding.boolIfPresent(container, forKey: .hasRealtime)
        self.stops = try? container.decodeIfPresent([OebbConnectionStop].self, forKey: .stops)
    }

    var stopCount: Int? {
        guard let stops, !stops.isEmpty else { return nil }
        return stops.count
    }
}

// MARK: - OebbCategory

struct OebbCategory: Decodable {
    let name: String?
    let number: String?
    let shortName: String?
    let displayName: String?
    let ubahn: Bool?
    let sbahn: Bool?
    let train: Bool?
}

// MARK: - OebbConnectionStop

struct OebbConnectionStop: Decodable {
    let name: String?
    let esn: Int?
    let departure: String?
    let arrival: String?
    let departureRealtime: String?
    let arrivalRealtime: String?
    let departureDelay: Int?
    let arrivalDelay: Int?
    let departurePlatform: String?
    let arrivalPlatform: String?
    let departurePlatformDeviation: String?
    let arrivalPlatformDeviation: String?
    let cancelled: Bool?

    enum CodingKeys: String, CodingKey {
        case name, esn, departure, arrival, departureRealtime, arrivalRealtime
        case departureDelay, arrivalDelay, departurePlatform, arrivalPlatform
        case departurePlatformDeviation, arrivalPlatformDeviation, cancelled
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.name = try container.decodeIfPresent(String.self, forKey: .name)
        self.esn = OebbDecoding.intIfPresent(container, forKey: .esn)
        self.departure = try container.decodeIfPresent(String.self, forKey: .departure)
        self.arrival = try container.decodeIfPresent(String.self, forKey: .arrival)
        self.departureRealtime = try container.decodeIfPresent(String.self, forKey: .departureRealtime)
        self.arrivalRealtime = try container.decodeIfPresent(String.self, forKey: .arrivalRealtime)
        self.departureDelay = OebbDecoding.intIfPresent(container, forKey: .departureDelay)
        self.arrivalDelay = OebbDecoding.intIfPresent(container, forKey: .arrivalDelay)
        self.departurePlatform = try container.decodeIfPresent(String.self, forKey: .departurePlatform)
        self.arrivalPlatform = try container.decodeIfPresent(String.self, forKey: .arrivalPlatform)
        self.departurePlatformDeviation = try container.decodeIfPresent(
            String.self,
            forKey: .departurePlatformDeviation
        )
        self.arrivalPlatformDeviation = try container.decodeIfPresent(String.self, forKey: .arrivalPlatformDeviation)
        self.cancelled = OebbDecoding.boolIfPresent(container, forKey: .cancelled)
    }
}

// MARK: - OebbStationBoard

struct OebbStationBoard: Decodable {
    let stationName: String?
    let stationEvaId: String?
    let boardType: String?
    let journey: [OebbStationBoardJourney]?
}

// MARK: - OebbStationBoardJourney

struct OebbStationBoardJourney: Decodable {
    let id: String?
    let ti: String?
    let da: String?
    let pr: String?
    let st: String?
    let lastStop: String?
    let ati: String?
    let tr: String?
    let trChg: Bool?
    let rt: OebbRealtimeInfo?
    let rta: OebbRealtimeInfo?
}

// MARK: - OebbRealtimeInfo

struct OebbRealtimeInfo: Decodable {
    let status: String?
    let dlm: String?
    let dlt: String?
    let dld: String?
}

// MARK: - OebbJourneyDetails

struct OebbJourneyDetails: Decodable {
    let stops: [OebbJourneyStop]?
    let svcResL: [OebbSvcRes]?

    func stopCount(from fromEsn: Int, to toEsn: Int) -> Int {
        if let svcRes = svcResL?.first,
           let jny = svcRes.res?.jny,
           let stopL = jny.stopL
        {
            let fromIdx = stopL.firstIndex { $0.extId == String(fromEsn) || $0.locX != nil }
            let toIdx = stopL.lastIndex { $0.extId == String(toEsn) || $0.locX != nil }
            if let from = fromIdx, let to = toIdx, to > from {
                return to - from - 1
            }
            return max(0, stopL.count - 2)
        }
        guard let stops, stops.count > 2 else { return 0 }
        return stops.count - 2
    }
}

// MARK: - OebbSvcRes

struct OebbSvcRes: Decodable { let res: OebbRes? }

// MARK: - OebbRes

struct OebbRes: Decodable { let jny: OebbJny? }

// MARK: - OebbJny

struct OebbJny: Decodable { let stopL: [OebbStopL]? }

// MARK: - OebbStopL

struct OebbStopL: Decodable { let locX: Int?; let extId: String?; let name: String? }

// MARK: - OebbJourneyStop

struct OebbJourneyStop: Decodable { let name: String?; let esn: Int? }

// MARK: - OebbDecoding

enum OebbDecoding {
    static func intIfPresent<K: CodingKey>(_ container: KeyedDecodingContainer<K>, forKey key: K) -> Int? {
        if let value = try? container.decodeIfPresent(Int.self, forKey: key) { return value }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }

    static func boolIfPresent<K: CodingKey>(_ container: KeyedDecodingContainer<K>, forKey key: K) -> Bool? {
        if let value = try? container.decodeIfPresent(Bool.self, forKey: key) { return value }
        if let intValue = intIfPresent(container, forKey: key) { return intValue != 0 }
        if let value = try? container.decodeIfPresent(String.self, forKey: key) {
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if ["true", "yes", "y", "1"].contains(trimmed) { return true }
            if ["false", "no", "n", "0"].contains(trimmed) { return false }
        }
        return nil
    }
}
