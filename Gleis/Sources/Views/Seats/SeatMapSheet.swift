import SwiftUI

// MARK: - SeatMapSheet

/// Shows free seats per coach and the seat layout of the chosen coach for every leg of a connection.
struct SeatMapSheet: View {
    let connection: TrainConnection
    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var loadState: SeatMapLoadState = .loading
    @State private var selectedLegID: Int?
    @State private var reloadCount = 0

    private static let oebbShopURL = URL(string: "https://shop.oebbtickets.at/de/ticket")!

    init(connection: TrainConnection) {
        self.connection = connection
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    content
                    if stacksForAccessibilitySize { reserveLink }
                }
                .padding()
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .safeAreaInset(edge: .bottom, spacing: 0) {
                if !stacksForAccessibilitySize {
                    reserveLink
                        .padding(.horizontal)
                        .padding(.vertical, 12)
                        .background(.bar)
                }
            }
            .navigationTitle("Seats")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } } }
        }
        .task(id: "\(connection.id)-\(reloadCount)") { await loadSeatMaps() }
    }

    private var stacksForAccessibilitySize: Bool { dynamicTypeSize.isAccessibilitySize }

    @ViewBuilder private var content: some View {
        switch loadState {
        case .loading:
            HStack(spacing: 10) {
                ProgressView()
                Text("Checking seats…").foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        case .failed:
            VStack(spacing: 12) {
                Text("Couldn't load seats from ÖBB.")
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                Button("Try Again") { reloadCount += 1 }
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 40)
        case .loaded(let legs):
            loadedContent(legs: legs)
        }
    }

    @ViewBuilder private func loadedContent(legs: [LegSeatMap]) -> some View {
        if legs.isEmpty {
            noticeText("No seat reservation on this train.")
        } else {
            if legs.count > 1 { LegPicker(legs: legs, selectedLegID: $selectedLegID) }
            if let leg = legs.first(where: { $0.id == selectedLegID }) ?? legs.first {
                LegSeatMapView(leg: leg).id(leg.id)
            }
        }
    }

    private var reserveLink: some View {
        Link(destination: Self.oebbShopURL) {
            Label("Reserve in ÖBB", systemImage: "arrow.up.forward.app")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
    }

    private func loadSeatMaps() async {
        loadState = .loading
        do {
            let legs = try await TransportService.shared.fetchSeatMaps(for: connection)
            if selectedLegID == nil || !legs.contains(where: { $0.id == selectedLegID }) {
                selectedLegID = Self.defaultLegID(in: legs)
            }
            loadState = .loaded(legs)
        } catch is CancellationError {
            return
        } catch {
            loadState = .failed
        }
    }

    // Opens on the first leg that has a seat map, so a short bus leg first does not hide the train.
    private static func defaultLegID(in legs: [LegSeatMap]) -> Int? {
        let firstWithMap = legs.first { leg in
            if case .map = leg.content { return true }
            return false
        }
        return (firstWithMap ?? legs.first)?.id
    }
}

private enum SeatMapLoadState {
    case loading
    case failed
    case loaded([LegSeatMap])
}

private func noticeText(_ message: String) -> some View {
    Text(message)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
}

// MARK: - Leg picker

private struct LegPicker: View {
    let legs: [LegSeatMap]
    @Binding var selectedLegID: Int?

    var body: some View {
        // A segmented control truncates its titles, so long line names fall back to a wrapping list.
        ViewThatFits(in: .horizontal) {
            Picker("Train", selection: $selectedLegID) {
                ForEach(legs) { leg in Text(leg.lineName).tag(Optional(leg.id)) }
            }
            .pickerStyle(.segmented)
            .fixedSize()

            VStack(spacing: 8) {
                ForEach(legs) { leg in legButton(leg) }
            }
        }
    }

    private func legButton(_ leg: LegSeatMap) -> some View {
        let isSelected = leg.id == selectedLegID
        return Button { selectedLegID = leg.id } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                Text(leg.lineName).fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(12)
            .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - One leg

private struct LegSeatMapView: View {
    let leg: LegSeatMap
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var selectedCoachID: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            switch leg.content {
            case .notReservable:
                noticeText("No seat reservation on this train.")
            case .map(let seatMap):
                if seatMap.coaches.isEmpty {
                    noticeText("ÖBB has no seat map for this train.")
                } else {
                    seatMapContent(seatMap)
                }
            }
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(leg.lineName).font(.title3.weight(.semibold))
            (Text(leg.fromName) + Text(" ") + Text(Image(systemName: "arrow.right")) + Text(" ") + Text(leg.toName))
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .accessibilityLabel("\(leg.fromName) to \(leg.toName)")
        }
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isHeader)
    }

    @ViewBuilder private func seatMapContent(_ seatMap: SeatMap) -> some View {
        let coaches = seatMap.coaches
        let shownCoachID = selectedCoachID ?? Self.defaultCoachID(in: coaches)
        let index = coaches.firstIndex { $0.id == shownCoachID } ?? 0
        CoachStrip(coaches: coaches, selectedCoachID: coaches[index].id) { coachID in
            select(coachID)
        }
        CoachDetail(
            coach: coaches[index],
            travelsLeft: seatMap.travelsLeft,
            previousCoachID: index > 0 ? coaches[index - 1].id : nil,
            nextCoachID: index < coaches.count - 1 ? coaches[index + 1].id : nil,
            onSelect: select
        )
    }

    private func select(_ coachID: String) {
        if reduceMotion {
            selectedCoachID = coachID
        } else {
            withAnimation(.easeInOut(duration: 0.2)) { selectedCoachID = coachID }
        }
    }

    private static func defaultCoachID(in coaches: [SeatMapCoach]) -> String? {
        let firstClassWithFreeSeats = coaches.first { ($0.freeSeatsByClass[firstClassCode] ?? 0) > 0 }
        let anyWithFreeSeats = coaches.first { totalFreeSeats(in: $0) > 0 }
        return (firstClassWithFreeSeats ?? anyWithFreeSeats ?? coaches.first)?.id
    }
}

// MARK: - Coach strip

private struct CoachStrip: View {
    let coaches: [SeatMapCoach]
    let selectedCoachID: String?
    let onSelect: (String) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(alignment: .top, spacing: 8) {
                    ForEach(coaches) { coach in
                        CoachTile(coach: coach, isSelected: coach.id == selectedCoachID) { onSelect(coach.id) }
                            .id(coach.id)
                    }
                }
                .padding(.vertical, 4)
            }
            .onAppear { scroll(proxy, animated: false) }
            .onChange(of: selectedCoachID) { scroll(proxy, animated: !reduceMotion) }
        }
    }

    private func scroll(_ proxy: ScrollViewProxy, animated: Bool) {
        guard let selectedCoachID else { return }
        if animated {
            withAnimation { proxy.scrollTo(selectedCoachID, anchor: .center) }
        } else {
            proxy.scrollTo(selectedCoachID, anchor: .center)
        }
    }
}

private struct CoachTile: View {
    let coach: SeatMapCoach
    let isSelected: Bool
    let onTap: () -> Void

    private var freeSeats: Int { totalFreeSeats(in: coach) }
    // Filled only when first class has a free seat, which is the class the default selection looks for first.
    private var isFilled: Bool { !coach.isReservationClosed && (coach.freeSeatsByClass[firstClassCode] ?? 0) > 0 }
    private var foreground: Color { isFilled ? .white : (coach.isReservationClosed ? .secondary : .primary) }

    var body: some View {
        Button(action: onTap) {
            VStack(alignment: .leading, spacing: 6) {
                Text(coach.id).font(.headline)
                HStack(spacing: 4) {
                    ForEach(coach.travelClasses, id: \.self) { code in
                        Text(classBadgeText(code))
                            .font(.caption2.weight(.bold))
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .overlay(RoundedRectangle(cornerRadius: 4).stroke(foreground, lineWidth: 1))
                    }
                }
                Text(coach.isReservationClosed ? "Closed" : "\(freeSeats) free").font(.caption)
            }
            .foregroundStyle(foreground)
            .padding(10)
            .background(tileBackground)
            .overlay(selectionRing)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(coachAccessibilityLabel(coach))
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder private var tileBackground: some View {
        let shape = RoundedRectangle(cornerRadius: 10)
        if isFilled {
            shape.fill(Color(.systemGreen))
        } else {
            shape.strokeBorder(freeSeats > 0 && !coach.isReservationClosed ? Color(.systemGreen) : Color(.systemGray3), lineWidth: 1.5)
                .background(shape.fill(coach.isReservationClosed ? Color(.systemGray6) : Color.clear))
        }
    }

    @ViewBuilder private var selectionRing: some View {
        if isSelected {
            RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 3).padding(-3)
        }
    }
}

// MARK: - Coach detail

private struct CoachDetail: View {
    let coach: SeatMapCoach
    let travelsLeft: Bool
    let previousCoachID: String?
    let nextCoachID: String?
    let onSelect: (String) -> Void

    private static let swipeDistance: CGFloat = 50

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 12) {
                titleRow
                Label {
                    Text("Direction of Travel")
                } icon: {
                    Image(systemName: travelsLeft ? "arrow.left" : "arrow.right")
                }
                .font(.subheadline)
                .foregroundStyle(.secondary)
                let facilities = coach.facilities.compactMap { facilityNames[$0.lowercased()] }
                if !facilities.isEmpty {
                    WrappingRow(spacing: 6) {
                        ForEach(facilities, id: \.name) { facility in FacilityChip(facility: facility) }
                    }
                }
            }
            .contentShape(Rectangle())
            .simultaneousGesture(coachSwipe)

            if let layout = coach.layout {
                CoachLayoutView(layout: layout, coachID: coach.id, swipe: coachSwipe)
            } else {
                noticeText("No seat map for this coach.")
            }
        }
        .padding(16)
        .background(Color(.secondarySystemBackground), in: RoundedRectangle(cornerRadius: 16))
    }

    private var titleRow: some View {
        HStack(alignment: .center, spacing: 8) {
            chevron("chevron.left", label: "Previous Coach", target: previousCoachID)
            VStack(alignment: .leading, spacing: 2) {
                Text("Coach \(coach.id)").font(.headline)
                Text(freeSeatsText).font(.subheadline).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            chevron("chevron.right", label: "Next Coach", target: nextCoachID)
        }
    }

    private var freeSeatsText: String {
        if coach.isReservationClosed { return "Reservation closed" }
        let free = totalFreeSeats(in: coach)
        return free == 1 ? "1 seat free" : "\(free) seats free"
    }

    private func chevron(_ symbol: String, label: String, target: String?) -> some View {
        Button { if let target { onSelect(target) } } label: {
            Image(systemName: symbol).font(.body.weight(.semibold)).padding(8)
        }
        .buttonStyle(.bordered)
        .buttonBorderShape(.circle)
        .disabled(target == nil)
        .accessibilityLabel(label)
    }

    private var coachSwipe: some Gesture {
        DragGesture(minimumDistance: 20).onEnded { value in
            let horizontal = value.translation.width
            guard abs(horizontal) > Self.swipeDistance, abs(horizontal) > abs(value.translation.height) else { return }
            if let target = horizontal < 0 ? nextCoachID : previousCoachID { onSelect(target) }
        }
    }
}

// MARK: - Coach layout drawing

private struct CoachLayoutView<Swipe: Gesture>: View {
    let layout: SeatMapCoachLayout
    let coachID: String
    let swipe: Swipe
    // The smallest seat that still shows its number; it grows with the text size.
    @ScaledMetric(relativeTo: .caption2) private var minimumSeatSide: CGFloat = 28
    @State private var availableWidth: CGFloat = 0

    private var cell: Double { Self.cellSize(of: layout) }

    var body: some View {
        let fitScale = availableWidth > 0 ? Double(availableWidth) / max(layout.width + cell, cell) : 0
        let minimumScale = Double(minimumSeatSide) / cell
        let scrolls = fitScale < minimumScale
        let scale = scrolls ? minimumScale : fitScale

        Group {
            if scrolls {
                ScrollView(.horizontal) { drawing(scale: scale) }
            } else {
                drawing(scale: scale).simultaneousGesture(swipe)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(GeometryReader { proxy in
            Color.clear
                .onAppear { availableWidth = proxy.size.width }
                .onChange(of: proxy.size.width) { availableWidth = proxy.size.width }
        })
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Seats in coach \(coachID)")
    }

    private func drawing(scale: Double) -> some View {
        let side = CGFloat(cell * scale)
        return ZStack(alignment: .topLeading) {
            RoundedRectangle(cornerRadius: side * 0.4)
                .strokeBorder(Color(.systemGray3), lineWidth: 1.5)
            ForEach(layout.fixtures) { fixture in
                FixtureShape(kind: fixture.kind, side: side)
                    .frame(width: side, height: side)
                    .position(center(x: fixture.x, y: fixture.y, scale: scale))
            }
            ForEach(layout.places) { place in
                SeatShape(place: place, side: side)
                    .frame(width: side, height: side)
                    .position(center(x: place.x, y: place.y, scale: scale))
            }
        }
        .frame(
            width: CGFloat((layout.width + cell) * scale),
            height: CGFloat((layout.height + cell) * scale)
        )
    }

    // Positions are top-left grid corners: half a cell centres the item and half a cell is the margin.
    private func center(x: Double, y: Double, scale: Double) -> CGPoint {
        CGPoint(x: (x + cell) * scale, y: (y + cell) * scale)
    }

    // ÖBB coordinates have no seat size, so one seat is the smallest step between two distinct positions.
    private static func cellSize(of layout: SeatMapCoachLayout) -> Double {
        let xs = Set(layout.places.map(\.x)).sorted()
        let ys = Set(layout.places.map(\.y)).sorted()
        let steps = zip(xs, xs.dropFirst()).map { $1 - $0 } + zip(ys, ys.dropFirst()).map { $1 - $0 }
        return steps.filter { $0 > 0 }.min() ?? 1
    }
}

private struct SeatShape: View {
    let place: SeatMapPlace
    let side: CGFloat

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: side * 0.2)
        ZStack {
            shape.fill(fill)
            shape.strokeBorder(Color(.systemGray3), lineWidth: place.status == .unknown ? 1 : 0)
            seatMark
        }
        .overlay(alignment: place.facesLeft ? .trailing : .leading) {
            // The backrest sits behind the passenger, opposite the way the seat faces.
            Capsule().fill(Color.primary.opacity(0.35)).frame(width: max(2, side * 0.1)).padding(.vertical, side * 0.15)
        }
        .padding(side * 0.06)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(seatAccessibilityLabel(place))
    }

    private var fill: Color {
        switch place.status {
        case .free: return Color(.systemGreen)
        case .taken: return Color(.systemGray3)
        case .unknown: return Color(.systemGray6)
        }
    }

    @ViewBuilder private var seatMark: some View {
        if place.status == .taken {
            Image(systemName: "xmark").font(.system(size: side * 0.4, weight: .bold)).foregroundStyle(.secondary)
        } else if let number = place.number, place.isSeat {
            Text(number)
                .font(.caption2.weight(.semibold))
                .minimumScaleFactor(0.5)
                .foregroundStyle(place.status == .free ? Color.white : Color.secondary)
                .padding(.horizontal, 1)
        }
    }
}

private struct FixtureShape: View {
    let kind: SeatMapFixtureKind
    let side: CGFloat

    var body: some View {
        switch kind {
        case .table:
            RoundedRectangle(cornerRadius: side * 0.15).fill(Color(.systemGray4)).padding(side * 0.15)
                .accessibilityHidden(true)
        case .wall:
            Rectangle().fill(Color(.systemGray2)).accessibilityHidden(true)
        case .toilet:
            symbol("toilet", label: "Toilet")
        case .luggage:
            symbol("suitcase", label: "Luggage Rack")
        case .door:
            symbol("door.left.hand.open", label: "Door")
        case .other:
            Circle().fill(Color(.systemGray5)).padding(side * 0.3).accessibilityHidden(true)
        }
    }

    private func symbol(_ name: String, label: String) -> some View {
        Image(systemName: name)
            .font(.system(size: side * 0.55))
            .foregroundStyle(.secondary)
            .accessibilityLabel(label)
    }
}

// MARK: - Facilities

private struct Facility {
    let name: String
    let symbol: String
}

// Exact ÖBB codes only; a code missing here is hidden rather than shown as raw jargon.
private let facilityNames: [String: Facility] = [
    "quietzone": Facility(name: "Quiet Zone", symbol: "speaker.slash"),
    "familyzone": Facility(name: "Family Zone", symbol: "figure.2.and.child.holdinghands"),
    "wifi": Facility(name: "Wi-Fi", symbol: "wifi"),
    "power": Facility(name: "Power Sockets", symbol: "powerplug"),
    "socket": Facility(name: "Power Sockets", symbol: "powerplug"),
    "wheelchair": Facility(name: "Wheelchair Space", symbol: "figure.roll"),
    "bicycle": Facility(name: "Bike Space", symbol: "bicycle"),
    "bike": Facility(name: "Bike Space", symbol: "bicycle"),
    "restaurant": Facility(name: "Restaurant", symbol: "fork.knife"),
    "bistro": Facility(name: "Bistro", symbol: "cup.and.saucer"),
    "kinderkino": Facility(name: "Kids Cinema", symbol: "film"),
    "sleeper": Facility(name: "Sleeper", symbol: "bed.double"),
    "couchette": Facility(name: "Couchette", symbol: "bed.double"),
]

private struct FacilityChip: View {
    let facility: Facility

    var body: some View {
        Label(facility.name, systemImage: facility.symbol)
            .font(.caption)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(Color(.tertiarySystemBackground), in: Capsule())
            .fixedSize(horizontal: false, vertical: true)
    }
}

/// Lays children out left to right and starts a new row when the next child does not fit.
private struct WrappingRow: Layout {
    var spacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let rows = arrange(subviews: subviews, maxWidth: proposal.width ?? .infinity)
        let width = rows.map(\.width).max() ?? 0
        let height = rows.map(\.height).reduce(0, +) + spacing * CGFloat(max(rows.count - 1, 0))
        return CGSize(width: width, height: height)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for row in arrange(subviews: subviews, maxWidth: bounds.width) {
            var x = bounds.minX
            for (index, size) in zip(row.indices, row.sizes) {
                subviews[index].place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
                x += size.width + spacing
            }
            y += row.height + spacing
        }
    }

    private struct Row {
        var indices: [Int] = []
        var sizes: [CGSize] = []
        var width: CGFloat = 0
        var height: CGFloat = 0
    }

    private func arrange(subviews: Subviews, maxWidth: CGFloat) -> [Row] {
        var rows: [Row] = [Row()]
        for index in subviews.indices {
            let size = subviews[index].sizeThatFits(ProposedViewSize(width: maxWidth, height: nil))
            let widthWithChild = rows[rows.count - 1].width + (rows[rows.count - 1].indices.isEmpty ? 0 : spacing) + size.width
            if widthWithChild > maxWidth, !rows[rows.count - 1].indices.isEmpty { rows.append(Row()) }
            var row = rows.removeLast()
            row.width += (row.indices.isEmpty ? 0 : spacing) + size.width
            row.height = max(row.height, size.height)
            row.indices.append(index)
            row.sizes.append(size)
            rows.append(row)
        }
        return rows.filter { !$0.indices.isEmpty }
    }
}

// MARK: - Shared wording

private let firstClassCode = "1"

private func totalFreeSeats(in coach: SeatMapCoach) -> Int {
    coach.freeSeatsByClass.values.reduce(0, +)
}

private func classBadgeText(_ code: String) -> String {
    code == "B" ? "Business" : code
}

private func className(_ code: String) -> String? {
    switch code {
    case "1": return "first class"
    case "2": return "second class"
    case "B": return "business class"
    default: return nil
    }
}

private func coachAccessibilityLabel(_ coach: SeatMapCoach) -> String {
    var parts = ["Coach \(coach.id)"]
    parts += coach.travelClasses.compactMap(className)
    if coach.isReservationClosed {
        parts.append("reservation closed")
    } else {
        let free = totalFreeSeats(in: coach)
        parts.append(free == 1 ? "1 seat free" : "\(free) seats free")
    }
    return parts.joined(separator: ", ")
}

private func seatAccessibilityLabel(_ place: SeatMapPlace) -> String {
    let status: String
    switch place.status {
    case .free: status = "free"
    case .taken: status = "taken"
    case .unknown: status = "status unknown"
    }
    let name = place.isSeat ? "Seat \(place.number ?? "")" : "Space"
    let parts = [name.trimmingCharacters(in: .whitespaces), status, place.travelClass.flatMap(className)]
    return parts.compactMap { $0 }.joined(separator: ", ")
}
