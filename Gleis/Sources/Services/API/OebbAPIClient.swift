import Foundation

actor OebbAPIClient {
    static let shared = OebbAPIClient()

    private let baseURL = URL(string: "https://shop.oebbtickets.at")!
    private let fahrplanBaseURL = URL(string: "https://fahrplan.oebb.at")!
    private let storage: StorageServiceProtocol
    private let urlSession: URLSession
    private let decoder = JSONDecoder()
    private let encoder = JSONEncoder()
    private var authSession: OebbAuthSession?

    private lazy var dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone.current
        f.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
        return f
    }()

    init(storage: StorageServiceProtocol = LocalStorageService.shared, urlSession: URLSession = .shared) {
        self.storage = storage
        self.urlSession = urlSession
        authSession = try? storage.load(forKey: StorageKey.oebbAuthSession.rawValue)
    }

    // MARK: - Public API

    func searchStations(query: String, count: Int) async throws -> [OebbStation] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/hafas/v1/stations"), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "name", value: query.trimmingCharacters(in: .whitespacesAndNewlines)),
        ]
        return try await performAuthorized(url: components?.url, method: "GET", decode: [OebbStation].self)
    }

    func searchStationsNearby(latitude: Double, longitude: Double, count: Int) async throws -> [OebbStation] {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/hafas/v1/stations"), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [
            URLQueryItem(name: "count", value: String(count)),
            URLQueryItem(name: "latitude", value: String(Int(latitude * 1_000_000))),
            URLQueryItem(name: "longitude", value: String(Int(longitude * 1_000_000))),
        ]
        return try await performAuthorized(url: components?.url, method: "GET", decode: [OebbStation].self)
    }

    func searchStationsNearbyWithDistance(
        latitude: Double, longitude: Double, count: Int, accuracyMeters: Int = 35
    ) async throws -> [OebbNearbyLocation] {
        let latMicro = Int((latitude * 1_000_000).rounded())
        let lonMicro = Int((longitude * 1_000_000).rounded())

        var components = URLComponents(url: fahrplanBaseURL.appendingPathComponent("gate"), resolvingAgainstBaseURL: false)
        components?.queryItems = [
            URLQueryItem(name: "rnd", value: String(Int(Date().timeIntervalSince1970 * 1000))),
        ]
        guard let url = components?.url else { throw GleisError.networkError("Invalid gate URL") }

        let payload = OebbGateRequest(
            id: makeGateRequestId(), ver: "1.88", lang: "deu",
            auth: .init(type: "AID", aid: "5vHavmuWPWIfetEe"),
            client: .init(
                id: "OEBB", type: "WEB", name: "webapp", l: "vs_webapp", v: 21901,
                pos: .init(x: lonMicro, y: latMicro, acc: max(0, accuracyMeters))
            ),
            formatted: false, ext: "OEBB.14",
            svcReqL: [
                .init(
                    meth: "LocGeoPos",
                    req: .init(
                        centerCrd: .init(y: latMicro, x: lonMicro), getPOIs: false, getStops: true,
                        maxLoc: max(1, count)
                    )
                ),
            ]
        )

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.httpBody = try encoder.encode(payload)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")

        let response = try await perform(request, decode: OebbGateResponse.self, retryAuth: false)
        if let err = response.err, err.uppercased() != "OK" { throw GleisError.apiError("Gate error: \(err)") }
        let service = response.svcResL?.first {
            ($0.meth ?? "").localizedCaseInsensitiveCompare("LocGeoPos") == .orderedSame
        } ?? response.svcResL?.first
        if let err = service?.err, err.uppercased() != "OK" { throw GleisError.apiError("Gate error: \(err)") }

        let locations = service?.res?.locL ?? []
        return locations.compactMap { location in
            guard let rawId = location.extId?.trimmingCharacters(in: .whitespacesAndNewlines), !rawId.isEmpty else {
                return nil
            }
            let fallbackName = location.name?.trimmingCharacters(in: .whitespacesAndNewlines)
            let name = (fallbackName?.isEmpty == false) ? fallbackName! : rawId
            return OebbNearbyLocation(
                id: rawId, name: name, latitude: location.crd?.y, longitude: location.crd?.x,
                distanceMeters: location.dist, durationSeconds: location.dur,
                countryCode: location.countryCodeL?.first?.lowercased()
            )
        }
    }

    func fetchTimetable(
        from: OebbStationRef, to: OebbStationRef, count: Int, departure: Date
    ) async throws -> OebbTimetableResponse {
        let payload = OebbTimetableRequest(
            reverse: false, datetimeDeparture: dateFormatter.string(from: departure), filter: .default,
            passengers: [.default], count: count, debugFilter: .default,
            from: .init(latitude: from.latitude, longitude: from.longitude, name: from.name, number: from.number),
            to: .init(latitude: to.latitude, longitude: to.longitude, name: to.name, number: to.number), timeout: [:]
        )
        let url = baseURL.appendingPathComponent("api/hafas/v4/timetable")
        return try await performAuthorized(
            url: url, method: "POST", body: encoder.encode(payload), decode: OebbTimetableResponse.self
        )
    }

    func fetchStationBoard(evaId: Int, directionId: Int? = nil, date: Date = Date()) async throws -> OebbStationBoard {
        let df = DateFormatter()
        df.dateFormat = "HH:mm"
        let time = df.string(from: date)
        df.dateFormat = "dd.MM.yyyy"
        let dateStr = df.string(from: date)

        var components = URLComponents(string: "http://fahrplan.oebb.at/bin/stboard.exe/dn")!
        var queryItems = [
            URLQueryItem(name: "L", value: "vs_scotty.vs_liveticker"),
            URLQueryItem(name: "evaId", value: String(evaId)), URLQueryItem(name: "boardType", value: "dep"),
            URLQueryItem(name: "time", value: time), URLQueryItem(name: "productsFilter", value: "1111111111111111"),
            URLQueryItem(name: "additionalTime", value: "0"), URLQueryItem(name: "maxJourneys", value: "50"),
            URLQueryItem(name: "outputMode", value: "tickerDataOnly"), URLQueryItem(name: "start", value: "yes"),
            URLQueryItem(name: "selectDate", value: "period"), URLQueryItem(name: "dateBegin", value: dateStr),
            URLQueryItem(name: "dateEnd", value: dateStr),
        ]
        if let dirId = directionId { queryItems.append(URLQueryItem(name: "dirInput", value: String(dirId))) }
        components.queryItems = queryItems

        guard let url = components.url else { throw GleisError.networkError("Invalid URL") }
        let (data, _) = try await urlSession.data(from: url)
        guard var text = String(data: data, encoding: .isoLatin1) ?? String(data: data, encoding: .utf8) else {
            throw GleisError.apiError("Invalid encoding")
        }
        text = text.replacingOccurrences(of: "\n", with: "").replacingOccurrences(of: "\r", with: "")
        guard let startRange = text.range(of: "="),
              let endRange = text.range(of: ";SLs.", options: .backwards) ?? text.range(of: ";", options: .backwards) else { throw GleisError.apiError("Invalid format") }
        let jsonStr = String(text[startRange.upperBound ..< endRange.lowerBound]).trimmingCharacters(in: .whitespaces)
        guard let jsonData = jsonStr.data(using: .utf8) else { throw GleisError.apiError("Invalid JSON") }
        return try decoder.decode(OebbStationBoard.self, from: jsonData)
    }

    // MARK: - Private Helpers

    private func performAuthorized<T: Decodable>(
        url: URL?, method: String, body: Data? = nil, decode: T.Type
    ) async throws -> T {
        guard let url else { throw GleisError.networkError("Invalid URL") }
        var request = URLRequest(url: url)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        let authorized = try await applyAuth(to: request)
        return try await perform(authorized, decode: decode)
    }

    private func applyAuth(to request: URLRequest) async throws -> URLRequest {
        let session = try await ensureAuthSession()
        var req = request
        req.setValue(session.channel, forHTTPHeaderField: "Channel")
        req.setValue(session.accessToken, forHTTPHeaderField: "AccessToken")
        req.setValue(session.sessionId, forHTTPHeaderField: "SessionId")
        req.setValue("WEB_\(session.supportId)", forHTTPHeaderField: "x-ts-supportid")
        if let cookie = session.cookie, !cookie.isEmpty {
            req.setValue("ts-cookie=\(cookie)", forHTTPHeaderField: "Cookie")
        }
        return req
    }

    private func perform<T: Decodable>(
        _ request: URLRequest, decode: T.Type, retryAuth: Bool = true, retryTransient: Bool = true
    ) async throws -> T {
        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse else { throw GleisError.networkError("Invalid response") }

        if [401, 403, 440].contains(http.statusCode) {
            if retryAuth {
                authSession = nil
                try? storage.delete(forKey: StorageKey.oebbAuthSession.rawValue)
                return try await perform(
                    applyAuth(to: request), decode: decode, retryAuth: false, retryTransient: retryTransient
                )
            }
            throw GleisError.apiError(http.statusCode == 440 ? "Session expired" : "Auth failed")
        }

        if retryTransient, http.statusCode == 429 || (500 ... 504).contains(http.statusCode) {
            try? await Task.sleep(nanoseconds: http.statusCode == 429 ? 2_000_000_000 : 1_000_000_000)
            return try await perform(request, decode: decode, retryAuth: retryAuth, retryTransient: false)
        }

        guard (200 ..< 300).contains(http.statusCode) else { throw GleisError.apiError("HTTP \(http.statusCode)") }
        return try decoder.decode(T.self, from: data)
    }

    private func ensureAuthSession() async throws -> OebbAuthSession {
        if let session = authSession, !session.isExpired { return session }
        let userId = authSession?.userId ?? makeUserId()
        let session = try await authenticate(userId: userId)
        authSession = session
        try? storage.save(session, forKey: StorageKey.oebbAuthSession.rawValue)
        return session
    }

    private func authenticate(userId: String) async throws -> OebbAuthSession {
        var components = URLComponents(
            url: baseURL.appendingPathComponent("api/domain/v3/init"), resolvingAgainstBaseURL: false
        )
        components?.queryItems = [URLQueryItem(name: "userId", value: userId)]
        guard let url = components?.url else { throw GleisError.networkError("Invalid auth URL") }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.setValue("inet", forHTTPHeaderField: "Channel")

        let (data, response) = try await urlSession.data(for: request)
        guard let http = response as? HTTPURLResponse, (200 ..< 300).contains(http.statusCode) else {
            throw GleisError.apiError("Auth failed")
        }

        let auth = try decoder.decode(OebbAuthResponse.self, from: data)
        let timeout = TimeInterval(max(auth.sessionTimeout ?? 2400, 0))
        return OebbAuthSession(
            userId: auth.userId ?? userId, accessToken: auth.accessToken, sessionId: auth.sessionId,
            supportId: auth.supportId, channel: auth.channel ?? "inet",
            cookie: extractCookie(from: http.allHeaderFields),
            expiresAt: Date().addingTimeInterval(max(timeout - 60, 0)), createdAt: Date()
        )
    }

    private func extractCookie(from headers: [AnyHashable: Any]) -> String? {
        for (key, value) in headers where String(describing: key).lowercased() == "set-cookie" {
            let header = String(describing: value)
            if let range = header.range(of: "ts-cookie=") {
                return header[range.upperBound...].split(separator: ";").first.map(String.init)
            }
        }
        return nil
    }

    private func makeUserId() -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789")
        func random(_ n: Int) -> String { String((0 ..< n).map { _ in chars.randomElement()! }).lowercased() }
        return "anonym-\(random(8))-\(random(4))-\(random(2))"
    }

    private func makeGateRequestId() -> String {
        let chars = Array("abcdefghijklmnopqrstuvwxyz0123456789")
        return String((0 ..< 16).map { _ in chars.randomElement()! })
    }
}
