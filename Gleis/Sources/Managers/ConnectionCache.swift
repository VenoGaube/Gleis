import Foundation

actor ConnectionCache {
    static let shared = ConnectionCache()

    private var cache: [String: CachedConnections] = [:]

    struct CachedConnections: Codable {
        let connections: [TrainConnection]
        let timestamp: Date
        let startStationId: String
        let endStationId: String
    }

    private func cacheKey(for transportType: TransportType, fromId: String, toId: String) -> String {
        "\(transportType.rawValue)|\(fromId)|\(toId)"
    }

    private func legacyCacheKey(for transportType: TransportType) -> String { transportType.rawValue }

    func save(_ connections: [TrainConnection], for transportType: TransportType, from: Station, to: Station) {
        let cached = CachedConnections(
            connections: connections, timestamp: Date(), startStationId: from.id, endStationId: to.id
        )
        let key = cacheKey(for: transportType, fromId: from.id, toId: to.id)
        cache[key] = cached
        persistToDisk(cached, for: transportType, fromId: from.id, toId: to.id)
    }

    func load(
        for transportType: TransportType, from: Station, to: Station
    ) -> [TrainConnection]? {
        let key = cacheKey(for: transportType, fromId: from.id, toId: to.id)
        let legacyKey = legacyCacheKey(for: transportType)

        // Try memory cache first
        if let cached = cache[key] {
            return cached.connections
        }

        // Compatibility: try legacy in-memory key.
        if let cached = cache[legacyKey], matchesRoute(cached, fromId: from.id, toId: to.id) {
            cache[key] = cached
            return cached.connections
        }

        // Try route-scoped disk cache first.
        if let cached = loadFromDisk(for: transportType, fromId: from.id, toId: to.id) {
            cache[key] = cached
            return cached.connections
        }

        // Compatibility: try legacy disk file and migrate to route-scoped file if it matches.
        if let cached = loadLegacyFromDisk(for: transportType), matchesRoute(cached, fromId: from.id, toId: to.id) {
            cache[key] = cached
            cache[legacyKey] = cached
            persistToDisk(cached, for: transportType, fromId: from.id, toId: to.id)
            return cached.connections
        }

        return nil
    }

    func lastUpdateTime(for transportType: TransportType, from: Station, to: Station) -> Date? {
        let key = cacheKey(for: transportType, fromId: from.id, toId: to.id)
        let legacyKey = legacyCacheKey(for: transportType)

        if let cached = cache[key] { return cached.timestamp }
        if let cached = cache[legacyKey], matchesRoute(cached, fromId: from.id, toId: to.id) {
            cache[key] = cached
            return cached.timestamp
        }
        if let cached = loadFromDisk(for: transportType, fromId: from.id, toId: to.id) {
            cache[key] = cached
            return cached.timestamp
        }
        if let cached = loadLegacyFromDisk(for: transportType), matchesRoute(cached, fromId: from.id, toId: to.id) {
            cache[key] = cached
            cache[legacyKey] = cached
            persistToDisk(cached, for: transportType, fromId: from.id, toId: to.id)
            return cached.timestamp
        }

        return nil
    }

    // MARK: - Disk Persistence

    private func persistToDisk(_ cached: CachedConnections, for transportType: TransportType, fromId: String, toId: String) {
        guard let url = routeCacheFileURL(for: transportType, fromId: fromId, toId: toId) else { return }

        // Move disk I/O to background thread to avoid blocking
        Task.detached(priority: .utility) {
            do {
                let data = try JSONEncoder().encode(cached)
                try data.write(to: url, options: .atomic)
            } catch {
                // Silent fail - cache writes are not critical
            }
        }
    }

    private func loadFromDisk(for transportType: TransportType, fromId: String, toId: String) -> CachedConnections? {
        guard let url = routeCacheFileURL(for: transportType, fromId: fromId, toId: toId),
              let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(CachedConnections.self, from: data) else { return nil }
        return cached
    }

    private func loadLegacyFromDisk(for transportType: TransportType) -> CachedConnections? {
        guard let url = legacyCacheFileURL(for: transportType), let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(CachedConnections.self, from: data) else { return nil }
        return cached
    }

    private func matchesRoute(_ cached: CachedConnections, fromId: String, toId: String) -> Bool {
        cached.startStationId == fromId && cached.endStationId == toId
    }

    private func routeCacheFileURL(for transportType: TransportType, fromId: String, toId: String) -> URL? {
        let typeToken = pathToken(transportType.rawValue)
        let fromToken = pathToken(fromId)
        let toToken = pathToken(toId)
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(
            "connections_\(typeToken)_\(fromToken)_\(toToken).json"
        )
    }

    private func legacyCacheFileURL(for transportType: TransportType) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(
            "connections_\(transportType.rawValue).json")
    }

    private func pathToken(_ value: String) -> String {
        let token = value.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        return token.isEmpty ? "na" : token
    }
}
