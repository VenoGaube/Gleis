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

    private func cacheKey(fromId: String, toId: String) -> String {
        "\(fromId)|\(toId)"
    }

    func save(_ connections: [TrainConnection], from: Station, to: Station) {
        let cached = CachedConnections(
            connections: connections, timestamp: Date(), startStationId: from.id, endStationId: to.id
        )
        let key = cacheKey(fromId: from.id, toId: to.id)
        cache[key] = cached
        persistToDisk(cached, fromId: from.id, toId: to.id)
    }

    func load(from: Station, to: Station) -> [TrainConnection]? {
        // Files written before pages dropped repeated trips can still hold the same id twice.
        guard let connections = resolve(from: from, to: to)?.connections else { return nil }
        var seenIds = Set<String>()
        return connections.filter { seenIds.insert($0.id).inserted }
    }

    func lastUpdateTime(from: Station, to: Station) -> Date? {
        resolve(from: from, to: to)?.timestamp
    }

    /// Finds the freshest usable entry for a route, checking memory, then the
    /// route-scoped file. Anything past `maximumAge` is discarded rather than returned.
    private func resolve(from: Station, to: Station) -> CachedConnections? {
        pruneDiskIfNeeded()

        let key = cacheKey(fromId: from.id, toId: to.id)

        if let cached = cache[key] {
            guard isFresh(cached) else {
                cache.removeValue(forKey: key)
                removeFromDisk(fromId: from.id, toId: to.id)
                return nil
            }
            return cached
        }

        if let cached = loadFromDisk(fromId: from.id, toId: to.id) {
            guard isFresh(cached) else {
                removeFromDisk(fromId: from.id, toId: to.id)
                return nil
            }
            cache[key] = cached
            return cached
        }

        return nil
    }

    private func isFresh(_ cached: CachedConnections, now: Date = Date()) -> Bool {
        now.timeIntervalSince(cached.timestamp) <= Self.maximumAge
    }

    // MARK: - Disk Persistence

    // Disk I/O runs inline on the actor so a delete and a later write to the same file keep their order.
    private func persistToDisk(_ cached: CachedConnections, fromId: String, toId: String) {
        guard let url = routeCacheFileURL(fromId: fromId, toId: toId),
              let data = try? JSONEncoder().encode(cached) else { return }
        try? data.write(to: url, options: .atomic)
    }

    private func loadFromDisk(fromId: String, toId: String) -> CachedConnections? {
        guard let url = routeCacheFileURL(fromId: fromId, toId: toId),
              let data = try? Data(contentsOf: url),
              let cached = try? JSONDecoder().decode(CachedConnections.self, from: data) else { return nil }
        return cached
    }

    private func removeFromDisk(fromId: String, toId: String) {
        guard let url = routeCacheFileURL(fromId: fromId, toId: toId) else { return }
        try? FileManager.default.removeItem(at: url)
    }

    /// Clears cache files left behind by routes the user no longer uses. Files were
    /// written per route pair and never removed.
    private func pruneDiskIfNeeded() {
        guard !hasPrunedDisk else { return }
        hasPrunedDisk = true

        let cutoff = Date().addingTimeInterval(-Self.maximumAge)
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

    // The old transport-type token, kept so cache files already on disk keep their names.
    private static let fileNameTypeToken = "Train"

    private func routeCacheFileURL(fromId: String, toId: String) -> URL? {
        let typeToken = Self.fileNameTypeToken
        let fromToken = pathToken(fromId)
        let toToken = pathToken(toId)
        return FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first?.appendingPathComponent(
            "connections_\(typeToken)_\(fromToken)_\(toToken).json"
        )
    }

    private func pathToken(_ value: String) -> String {
        let token = value.replacingOccurrences(of: "[^A-Za-z0-9_-]", with: "_", options: .regularExpression)
        return token.isEmpty ? "na" : token
    }
}
