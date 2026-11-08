import Foundation

actor ConnectionCache {
    static let shared = ConnectionCache()

    /// How old a cached route may be before it stops being served.
    ///
    /// Entries carried a timestamp that nothing ever checked, so a snapshot of any
    /// age could be presented — and reported through `lastUpdateTime` — as if it
    /// were current. Departure times are same-day, so a few hours is generous.
    static let maximumAge: TimeInterval = 6 * 60 * 60

    private var cache: [String: CachedConnections] = [:]
    private var hasPrunedDisk = false

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
        resolve(for: transportType, from: from, to: to)?.connections
    }

    func lastUpdateTime(for transportType: TransportType, from: Station, to: Station) -> Date? {
        resolve(for: transportType, from: from, to: to)?.timestamp
    }

    /// Finds the freshest usable entry for a route, checking memory, then the
    /// route-scoped file, then the legacy file. Anything past `maximumAge` is
    /// discarded rather than returned.
    private func resolve(
        for transportType: TransportType, from: Station, to: Station
    ) -> CachedConnections? {
        pruneDiskIfNeeded()

        let key = cacheKey(for: transportType, fromId: from.id, toId: to.id)
        let legacyKey = legacyCacheKey(for: transportType)

        if let cached = cache[key] {
            guard isFresh(cached) else {
                cache.removeValue(forKey: key)
                removeFromDisk(for: transportType, fromId: from.id, toId: to.id)
                return nil
            }
            return cached
        }

        // Compatibility: legacy in-memory key.
        if let cached = cache[legacyKey], matchesRoute(cached, fromId: from.id, toId: to.id), isFresh(cached) {
            cache[key] = cached
            return cached
        }

        if let cached = loadFromDisk(for: transportType, fromId: from.id, toId: to.id) {
            guard isFresh(cached) else {
                removeFromDisk(for: transportType, fromId: from.id, toId: to.id)
                return nil
            }
            cache[key] = cached
            return cached
        }

        // Compatibility: legacy disk file, migrated to a route-scoped file if it matches.
        if let cached = loadLegacyFromDisk(for: transportType),
           matchesRoute(cached, fromId: from.id, toId: to.id),
           isFresh(cached)
        {
            cache[key] = cached
            cache[legacyKey] = cached
            persistToDisk(cached, for: transportType, fromId: from.id, toId: to.id)
            return cached
        }

        return nil
    }

    private func isFresh(_ cached: CachedConnections, now: Date = Date()) -> Bool {
        now.timeIntervalSince(cached.timestamp) <= Self.maximumAge
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

    private func removeFromDisk(for transportType: TransportType, fromId: String, toId: String) {
        guard let url = routeCacheFileURL(for: transportType, fromId: fromId, toId: toId) else { return }
        Task.detached(priority: .utility) { try? FileManager.default.removeItem(at: url) }
    }

    /// Clears cache files left behind by routes the user no longer uses. Files were
    /// written per route pair and never removed.
    private func pruneDiskIfNeeded() {
        guard !hasPrunedDisk else { return }
        hasPrunedDisk = true

        let cutoff = Date().addingTimeInterval(-Self.maximumAge)
        Task.detached(priority: .background) {
            let fileManager = FileManager.default
            guard let directory = fileManager.urls(for: .cachesDirectory, in: .userDomainMask).first,
                  let files = try? fileManager.contentsOfDirectory(
                      at: directory,
                      includingPropertiesForKeys: [.contentModificationDateKey],
                      options: [.skipsHiddenFiles]
                  )
            else { return }

            for file in files where file.lastPathComponent.hasPrefix("connections_") {
                let modified = (try? file.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate
                guard let modified, modified < cutoff else { continue }
                try? fileManager.removeItem(at: file)
            }
        }
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
