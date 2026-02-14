import Foundation

actor ConnectionCache {
    static let shared = ConnectionCache()

    private var cache: [String: CachedConnections] = [:]
    private let maxAge: TimeInterval = 3600 // 1 hour

    struct CachedConnections: Codable {
        let connections: [TrainConnection]
        let timestamp: Date
        let startStationId: String
        let endStationId: String
    }

    private func cacheKey(for transportType: TransportType) -> String { transportType.rawValue }

    func save(_ connections: [TrainConnection], for transportType: TransportType, from: Station, to: Station) {
        let cached = CachedConnections(
            connections: connections, timestamp: Date(), startStationId: from.id, endStationId: to.id
        )
        cache[cacheKey(for: transportType)] = cached
        persistToDisk(cached, for: transportType)
    }

    func load(
        for transportType: TransportType, from: Station, to: Station
    ) -> (connections: [TrainConnection], isStale: Bool)? {
        let key = cacheKey(for: transportType)

        // Try memory cache first
        if let cached = cache[key] {
            if cached.startStationId == from.id, cached.endStationId == to.id {
                let isStale = Date().timeIntervalSince(cached.timestamp) > maxAge
                return (cached.connections, isStale)
            }
        }

        // Try disk cache
        if let cached = loadFromDisk(for: transportType) {
            cache[key] = cached
            if cached.startStationId == from.id, cached.endStationId == to.id {
                let isStale = Date().timeIntervalSince(cached.timestamp) > maxAge
                return (cached.connections, isStale)
            }
        }

        return nil
    }

    func lastUpdateTime(for transportType: TransportType) -> Date? { cache[cacheKey(for: transportType)]?.timestamp }

    // MARK: - Disk Persistence

    private func persistToDisk(_ cached: CachedConnections, for transportType: TransportType) {
        guard let url = cacheFileURL(for: transportType) else { return }

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

    private func loadFromDisk(for transportType: TransportType) -> CachedConnections? {
        guard let url = cacheFileURL(for: transportType), let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(CachedConnections.self, from: data) else { return nil }
        return cached
    }

    private func cacheFileURL(for transportType: TransportType) -> URL? {
        FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(
            "connections_\(transportType.rawValue).json")
    }
}
