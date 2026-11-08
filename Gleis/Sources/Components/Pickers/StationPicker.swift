import SwiftUI

// MARK: - StationPickerSheet

struct StationPickerSheet: View {
    let title: String
    let stations: [Station]
    let recentStations: [Station]
    let favoriteStations: [Station]
    private let favoriteIds: Set<String>
    let searchHandler: (String) async -> [Station]
    let onToggleFavorite: (Station) -> Void
    @Binding var selection: Station?

    init(
        title: String, stations: [Station], recentStations: [Station], favoriteStations: [Station],
        searchHandler: @escaping (String) async -> [Station], onToggleFavorite: @escaping (Station) -> Void,
        selection: Binding<Station?>
    ) {
        self.title = title
        self.stations = stations
        self.recentStations = recentStations
        self.favoriteStations = favoriteStations
        favoriteIds = Set(favoriteStations.map(\.id))
        self.searchHandler = searchHandler
        self.onToggleFavorite = onToggleFavorite
        _selection = selection
    }

    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var searchResults: [Station] = []
    @State private var isSearching = false

    private static let networkSearchDebounce: Duration = .milliseconds(300)

    var body: some View {
        NavigationStack {
            List { if searchText.isEmpty { stationSections } else { searchResultsSection } }
                .searchable(text: $searchText, prompt: "Search stations")
                .navigationTitle(title).navigationBarTitleDisplayMode(.inline).toolbar {
                    ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                }
        }.task(id: searchText) { await search(for: searchText) }
    }

    @ViewBuilder private var stationSections: some View {
        if !favoriteStations.isEmpty {
            Section("Favorites") { ForEach(favoriteStations) { stationRow($0, isFavorite: true) } }
        }
        if !recentStations.isEmpty {
            Section("Recent") { ForEach(recentStations) { stationRow($0, isFavorite: favoriteIds.contains($0.id)) } }
        }
        if !stations.isEmpty {
            Section("Popular stations") { ForEach(stations) { stationRow($0, isFavorite: favoriteIds.contains($0.id)) } }
        } else if recentStations.isEmpty, favoriteStations.isEmpty {
            Section("Loading stations") { ForEach(0 ..< 4, id: \.self) { _ in SkeletonStationRow() } }
        }
    }

    @ViewBuilder private var searchResultsSection: some View {
        Section("Results") {
            if isSearching, searchResults.isEmpty { ForEach(0 ..< 3, id: \.self) { _ in SkeletonStationRow() } }
            ForEach(searchResults) { stationRow($0, isFavorite: favoriteIds.contains($0.id)) }
            if searchText.count >= 1, !isSearching, searchResults.isEmpty {
                Text("No stations found.").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private func stationRow(_ station: Station, isFavorite: Bool) -> some View {
        StationRow(
            station: station,
            isSelected: selection?.id == station.id,
            isFavorite: isFavorite,
            onTap: {
                selection = station
                dismiss()
            },
            onFavorite: { onToggleFavorite(station) }
        )
    }

    /// Shows matches from the stations already in hand at once, then merges in the network results.
    @MainActor private func search(for query: String) async {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            searchResults = []
            isSearching = false
            return
        }
        let recentAndPopular = StationSearchService.mergeStations(primary: recentStations, secondary: stations)
        let localPool = StationSearchService.mergeStations(primary: favoriteStations, secondary: recentAndPopular)
        let localMatches = StationSearchService.rankStations(localPool, query: trimmed)
        // With no local match, the previous results stay up while the network answers.
        if !localMatches.isEmpty { searchResults = localMatches }
        isSearching = true

        // task(id:) cancels this run on the next keystroke, which is the debounce.
        do { try await Task.sleep(for: Self.networkSearchDebounce) } catch { return }
        let remote = await searchHandler(trimmed)
        guard !Task.isCancelled else { return }
        searchResults = StationSearchService.rankStations(
            StationSearchService.mergeStations(primary: remote, secondary: localMatches), query: trimmed
        )
        isSearching = false
    }
}

// MARK: - StationRow

struct StationRow: View {
    let station: Station
    let isSelected: Bool
    let isFavorite: Bool
    let onTap: () -> Void
    var onFavorite: (() -> Void)? = nil

    private var lineBadges: some View {
        ForEach(station.lines.prefix(4), id: \.self) { line in
            Text(line).font(.caption2.weight(.semibold)).foregroundStyle(.white).lineLimit(1).fixedSize()
                .padding(.horizontal, 6).padding(.vertical, 2)
                .background(Color.lineColor(for: line), in: RoundedRectangle(cornerRadius: 4))
        }
    }

    var body: some View {
        HStack {
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text(station.name).font(.body).fixedSize(horizontal: false, vertical: true)
                    if !station.lines.isEmpty {
                        ViewThatFits(in: .horizontal) {
                            HStack(spacing: 4) { lineBadges }
                            VStack(alignment: .leading, spacing: 4) { lineBadges }
                        }
                    }
                }
                Spacer()
            }
            .contentShape(Rectangle())
            .onTapGesture { onTap() }

            if let onFavorite {
                Button(action: onFavorite) {
                    Image(systemName: isFavorite ? "star.fill" : "star").foregroundStyle(
                        isFavorite ? .yellow : .secondary)
                }.buttonStyle(.plain).accessibilityLabel(isFavorite ? "Remove from favorites" : "Add to favorites")
            }
            if isSelected { Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.accentColor) }
        }.accessibilityLabel("\(station.name)\(isSelected ? ", selected" : "")")
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
        }.skeletonShimmer().padding(.vertical, 6)
    }
}
