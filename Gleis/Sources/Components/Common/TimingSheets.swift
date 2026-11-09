import SwiftUI

// MARK: - TimingSheet

/// Which timing sheet a RouteHeader tap opened, and for which station.
enum TimingSheet: Identifiable {
    case travel(Station)
    case buffer(Station)

    var id: String {
        switch self {
        case let .travel(station): "travel-\(station.id)"
        case let .buffer(station): "buffer-\(station.id)"
        }
    }
}

// MARK: - TravelTimeSheet

struct TravelTimeSheet: View {
    let station: Station
    let currentValue: Int?
    let onSave: (Int?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var minutes: Int = 10

    init(station: Station, currentValue: Int? = nil, onSave: @escaping (Int?) -> Void) {
        self.station = station
        self.currentValue = currentValue
        self.onSave = onSave
        _minutes = State(initialValue: currentValue ?? 10)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $minutes, in: 1 ... 60) {
                        HStack {
                            Image(systemName: "figure.walk").foregroundStyle(.blue)
                            Text("\(minutes) min")
                        }
                    }
                } header: {
                    Text("How long does it take you to get to \(station.name)?")
                } footer: {
                    Text("From home or work.")
                }
            }.navigationTitle("Time to Station").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(minutes)
                        dismiss()
                    }
                }
            }
        }.modifier(TimingSheetDetents())
    }
}

// MARK: - BufferTimeSheet

struct BufferTimeSheet: View {
    let station: Station
    let currentValue: Int?
    let onSave: (Int?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var minutes: Int = 2

    init(station: Station, currentValue: Int? = nil, onSave: @escaping (Int?) -> Void) {
        self.station = station
        self.currentValue = currentValue
        self.onSave = onSave
        _minutes = State(initialValue: currentValue ?? 2)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Stepper(value: $minutes, in: 0 ... 30) {
                        HStack {
                            Image(systemName: "clock.badge.checkmark").foregroundStyle(.orange)
                            Text("\(minutes) min")
                        }
                    }
                } header: {
                    Text("Buffer for \(station.name)")
                } footer: {
                    Text("Extra minutes on top of your time to the station, for delays, queues or finding your platform.")
                }
            }.navigationTitle("Buffer").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(minutes)
                        dismiss()
                    }
                }
            }
        }.modifier(TimingSheetDetents())
    }
}

/// The 220 pt detent scales with Dynamic Type, and the sheet can always be pulled to full height.
private struct TimingSheetDetents: ViewModifier {
    @ScaledMetric(relativeTo: .body) private var compactHeight: CGFloat = 220

    func body(content: Content) -> some View {
        content.presentationDetents([.height(compactHeight), .large])
    }
}

// MARK: - DepartureTimeSheet

/// Picks the time the Train list jumps to. The presenter sets the detent.
struct DepartureTimeSheet: View {
    let anchor: Date?
    let onApply: (Date) -> Void
    let onBackToNow: () -> Void

    private static let pickerRange: TimeInterval = 7 * 24 * 60 * 60
    private static let eveningHour = 17
    private static let eveningMinute = 30
    private static let morningHour = 7

    @Environment(\.dismiss) private var dismiss
    @Environment(\.dynamicTypeSize) private var dynamicTypeSize
    @State private var selectedDate: Date

    init(anchor: Date?, onApply: @escaping (Date) -> Void, onBackToNow: @escaping () -> Void) {
        self.anchor = anchor
        self.onApply = onApply
        self.onBackToNow = onBackToNow
        _selectedDate = State(initialValue: max(anchor ?? Date(), Date()))
    }

    private struct QuickChoice: Identifiable {
        let title: String
        let date: Date
        var id: String { title }
    }

    private func quickChoices(now: Date, calendar: Calendar = .current) -> [QuickChoice] {
        var choices = [
            QuickChoice(title: "In 1 Hour", date: now.addingTimeInterval(60 * 60)),
            QuickChoice(title: "In 2 Hours", date: now.addingTimeInterval(2 * 60 * 60)),
        ]
        let startOfToday = calendar.startOfDay(for: now)
        if let eveningToday = calendar.date(
            bySettingHour: Self.eveningHour, minute: Self.eveningMinute, second: 0, of: startOfToday
        ) {
            let evening = eveningToday > now ? eveningToday : calendar.date(byAdding: .day, value: 1, to: eveningToday)
            if let evening {
                let time = evening.formatted(date: .omitted, time: .shortened)
                choices.append(QuickChoice(title: "Evening \(time)", date: evening))
            }
        }
        if let startOfTomorrow = calendar.date(byAdding: .day, value: 1, to: startOfToday),
           let morning = calendar.date(bySettingHour: Self.morningHour, minute: 0, second: 0, of: startOfTomorrow)
        {
            let time = morning.formatted(date: .omitted, time: .shortened)
            choices.append(QuickChoice(title: "Tomorrow \(time)", date: morning))
        }
        return choices
    }

    private var chipColumns: [GridItem] {
        let column = GridItem(.flexible(), spacing: 10)
        return dynamicTypeSize.isAccessibilitySize ? [column] : [column, column]
    }

    var body: some View {
        let now = Date()
        let range = now ... now.addingTimeInterval(Self.pickerRange)
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    LazyVGrid(columns: chipColumns, spacing: 10) {
                        ForEach(quickChoices(now: now)) { choice in
                            Button {
                                Haptics.selection()
                                apply(choice.date)
                            } label: {
                                Text(choice.title).font(.subheadline.weight(.semibold))
                                    .multilineTextAlignment(.center).fixedSize(horizontal: false, vertical: true)
                                    .frame(maxWidth: .infinity, minHeight: 44)
                            }
                            .buttonStyle(.bordered)
                        }
                    }

                    VStack(alignment: .leading, spacing: 8) {
                        Text("Or pick a time").font(.subheadline).foregroundStyle(.secondary)
                        datePicker(in: range)
                    }

                    Button {
                        apply(selectedDate)
                    } label: {
                        Text("Show Trains").font(.headline).multilineTextAlignment(.center)
                            .frame(maxWidth: .infinity, minHeight: 44)
                    }
                    .buttonStyle(.borderedProminent)

                    if anchor != nil {
                        Button {
                            onBackToNow()
                            dismiss()
                        } label: {
                            Text("Back to Now").font(.headline).multilineTextAlignment(.center)
                                .frame(maxWidth: .infinity, minHeight: 44)
                        }
                        .buttonStyle(.bordered)
                    }
                }.padding(20)
            }
            .navigationTitle("Departure Time").navigationBarTitleDisplayMode(.inline).toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
        }
    }

    /// One compact picker normally; date and time on separate rows at accessibility sizes so neither is clipped.
    @ViewBuilder private func datePicker(in range: ClosedRange<Date>) -> some View {
        if dynamicTypeSize.isAccessibilitySize {
            VStack(alignment: .leading, spacing: 8) {
                DatePicker("Date", selection: $selectedDate, in: range, displayedComponents: .date)
                DatePicker("Time", selection: $selectedDate, in: range, displayedComponents: .hourAndMinute)
            }.labelsHidden().datePickerStyle(.compact)
        } else {
            DatePicker("Departs", selection: $selectedDate, in: range, displayedComponents: [.date, .hourAndMinute])
                .labelsHidden().datePickerStyle(.compact)
        }
    }

    private func apply(_ date: Date) {
        onApply(date)
        dismiss()
    }
}
