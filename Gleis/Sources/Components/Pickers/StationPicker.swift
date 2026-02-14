import SwiftUI

// MARK: - StationPickerSheet

struct StationPickerSheet: View {
    let title: String
    let stations: [Station]
    let recentStations: [Station]
    let favoriteStations: [Station]
    let nearbyStations: [Station]
    let stationDistances: [String: Double]
    let searchHandler: (String) async -> [Station]
    let onToggleFavorite: (Station) -> Void
    @Binding var selection: Station?

    init(
        title: String, stations: [Station], recentStations: [Station], favoriteStations: [Station],
        nearbyStations: [Station], stationDistances: [String: Double] = [:],
        searchHandler: @escaping (String) async -> [Station], onToggleFavorite: @escaping (Station) -> Void,
        selection: Binding<Station?>
    ) {
        self.title = title
        self.stations = stations
        self.recentStations = recentStations
        self.favoriteStations = favoriteStations
        self.nearbyStations = nearbyStations
        self.stationDistances = stationDistances
        self.searchHandler = searchHandler
        self.onToggleFavorite = onToggleFavorite
        _selection = selection
    }

    @Environment(\.dismiss) private var dismiss
    @Environment(\.colorScheme) var colorScheme
    @State private var searchText = ""
    @State private var searchResults: [Station] = []
    @State private var isSearching = false
    @State private var searchTask: Task<Void, Never>?
    @State private var isReady = false

    var body: some View {
        NavigationStack {
            Group {
                if isReady {
                    List { if searchText.isEmpty { stationSections } else { searchResultsSection } }
                        .searchable(text: $searchText, prompt: "Search stations")
                } else {
                    List { Section("Loading") { ForEach(0 ..< 4, id: \.self) { _ in SkeletonStationRow() } } }
                }
            }.navigationTitle(title).navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }.onChange(of: searchText) { _, query in handleSearch(query) }
        .onDisappear { searchTask?.cancel() }
        .task { try? await Task.sleep(nanoseconds: 50_000_000); isReady = true }
    }

    @ViewBuilder private var stationSections: some View {
        if !favoriteStations.isEmpty {
            Section("Favorites") { ForEach(favoriteStations) { stationRow($0, isFavorite: true) } }
        }
        if !recentStations.isEmpty {
            Section("Recent") { ForEach(recentStations) { stationRow($0, isFavorite: isFavorite($0)) } }
        }
        if !nearbyStations.isEmpty {
            Section("Nearby") { ForEach(nearbyStations) { stationRow($0, isFavorite: isFavorite($0)) } }
        }
        if !stations.isEmpty {
            Section("Popular Stations") { ForEach(stations) { stationRow($0, isFavorite: isFavorite($0)) } }
        } else if recentStations.isEmpty, favoriteStations.isEmpty, nearbyStations.isEmpty {
            Section("Loading Stations") { ForEach(0 ..< 4, id: \.self) { _ in SkeletonStationRow() } }
        }
    }

    @ViewBuilder private var searchResultsSection: some View {
        Section("Results") {
            if isSearching, searchResults.isEmpty { ForEach(0 ..< 3, id: \.self) { _ in SkeletonStationRow() } }
            ForEach(searchResults) { stationRow($0, isFavorite: isFavorite($0)) }
            if searchText.count >= 1, !isSearching, searchResults.isEmpty {
                Text("No stations found.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func stationRow(_ station: Station, isFavorite: Bool) -> some View {
        StationRow(
            station: station, isSelected: selection?.id == station.id, isFavorite: isFavorite,
            distance: stationDistances[station.id],
            onTap: {
                selection = station
                dismiss()
            }, onFavorite: { onToggleFavorite(station) }
        )
    }

    private func isFavorite(_ station: Station) -> Bool { favoriteStations.contains { $0.id == station.id } }

    private func handleSearch(_ query: String) {
        searchTask?.cancel()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count >= 1 else {
            searchResults = []
            isSearching = false
            return
        }
        // Keep showing previous results while typing for better responsiveness
        isSearching = true
        searchTask = Task { @MainActor in
            // Short debounce to avoid excessive API calls while typing
            try? await Task.sleep(nanoseconds: 100_000_000)
            guard !Task.isCancelled else { return }
            let results = await searchHandler(trimmed)
            guard !Task.isCancelled else { return }
            searchResults = results
            isSearching = false
        }
    }
}

// MARK: - StationRow

struct StationRow: View {
    let station: Station
    let isSelected: Bool
    let isFavorite: Bool
    let distance: Double?
    let onTap: () -> Void
    let onFavorite: (() -> Void)?

    init(
        station: Station, isSelected: Bool, isFavorite: Bool, distance: Double? = nil, onTap: @escaping () -> Void,
        onFavorite: (() -> Void)? = nil
    ) {
        self.station = station
        self.isSelected = isSelected
        self.isFavorite = isFavorite
        self.distance = distance
        self.onTap = onTap
        self.onFavorite = onFavorite
    }

    private var distanceText: String? {
        guard let distance else { return nil }
        if distance < 1000 { return "\(Int(distance))m" } else { return String(format: "%.1fkm", distance / 1000) }
    }

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(station.name).font(.body).scalableText(minimumScale: 0.8)
                    if let distanceText {
                        Text(distanceText).font(.caption2).foregroundStyle(.secondary).padding(.horizontal, 6).padding(
                            .vertical, 2
                        ).background(Color.secondary.opacity(0.1), in: Capsule())
                    }
                }
                if !station.lines.isEmpty {
                    HStack(spacing: 4) {
                        ForEach(station.lines.prefix(4), id: \.self) { line in
                            Text(line).font(.caption2.weight(.semibold)).foregroundStyle(.white).scalableText(
                                minimumScale: 0.7
                            ).padding(.horizontal, 6).padding(.vertical, 2).background(
                                Color.lineColor(for: line), in: RoundedRectangle(cornerRadius: 4)
                            )
                        }
                    }
                }
            }
            Spacer()
            if let onFavorite {
                Button(action: onFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star").foregroundStyle(
                        isFavorite ? .yellow : .secondary)
                }.buttonStyle(.plain).accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
            }
            if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
        }.contentShape(Rectangle()).onTapGesture { onTap() }.accessibilityLabel(
            "\(station.name)\(isSelected ? ", selected" : "")")
    }
}

// MARK: - SkeletonStationRow

struct SkeletonStationRow: View {
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 6) {
                SkeletonBox(width: 160, height: 14)
                SkeletonBox(width: 50, height: 10)
            }
            Spacer()
        }.padding(.vertical, 6)
    }
}
