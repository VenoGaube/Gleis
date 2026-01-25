import AVFoundation
import PhotosUI
import SwiftUI
import Vision

// MARK: - TicketWalletView

struct TicketWalletView: View {
    @EnvironmentObject private var settingsManager: SettingsManager
    @State private var showAddTicket = false
    @State private var showToast = false
    @State private var toastMessage = ""
    @State private var toastType: ToastView.ToastType = .info
    @Environment(\.colorScheme) var colorScheme

    private var tickets: [TicketCard] { settingsManager.appSettings.ticketCards }

    var body: some View {
        ScrollView {
            if tickets.isEmpty {
                TicketWalletEmptyState {
                    showAddTicket = true
                }
            } else {
                VStack(spacing: 20) {
                    // Header stats
                    HStack(spacing: 12) {
                        StatCard(
                            icon: "wallet.pass.fill",
                            value: "\(tickets.count)",
                            label: tickets.count == 1 ? "Ticket" : "Tickets",
                            color: .green
                        )
                        .fixedSize(horizontal: true, vertical: false)

                        if let selectedId = settingsManager.appSettings.selectedTicketId,
                           let selected = tickets.first(where: { $0.id == selectedId })
                        {
                            StatCard(
                                icon: "checkmark.circle.fill",
                                value: selected.name,
                                label: "Default",
                                color: .blue
                            )
                            .frame(maxWidth: .infinity)
                        }
                    }
                    .padding(.horizontal, 20)
                    .padding(.top, 8)

                    // Tickets grid
                    LazyVStack(spacing: 20) {
                        ForEach(tickets) { ticket in
                            NavigationLink {
                                TicketDetailView(ticket: ticket, onDelete: {
                                    displayToast("Ticket deleted", type: .info)
                                }, onSetDefault: {
                                    displayToast("Set as default ticket", type: .success)
                                })
                            } label: {
                                TicketCardPreview(
                                    ticket: ticket,
                                    isSelected: settingsManager.appSettings.selectedTicketId == ticket.id
                                )
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.horizontal, 20)
                }
                .padding(.vertical, 12)
            }
        }
        .background(colorScheme == .dark ? Color(.systemBackground) : Color(.systemGroupedBackground))
        .navigationTitle("Ticket Wallet")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showAddTicket = true
                } label: {
                    Image(systemName: "plus")
                        .fontWeight(.semibold)
                }
            }
        }
        .sheet(isPresented: $showAddTicket) {
            TicketScannerView(onTicketAdded: { ticketName in
                displayToast(
                    tickets.count == 1 ? "🎉 First ticket added!" : "Ticket '\(ticketName)' added",
                    type: .success
                )
            })
        }
        .overlay(alignment: .top) {
            if showToast {
                ToastView(message: toastMessage, type: toastType)
                    .padding(.top, 60)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .onAppear {
                        DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                            withAnimation {
                                showToast = false
                            }
                        }
                    }
            }
        }
    }

    private func displayToast(_ message: String, type: ToastView.ToastType = .info) {
        toastMessage = message
        toastType = type
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) {
            showToast = true
        }
    }
}

// MARK: - StatCard

struct StatCard: View {
    let icon: String
    let value: String
    let label: String
    let color: Color
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
                .frame(width: 40, height: 40)
                .background(
                    Circle()
                        .fill(color.opacity(colorScheme == .dark ? 0.2 : 0.1))
                )

            VStack(alignment: .leading, spacing: 2) {
                Text(value)
                    .font(.title3.weight(.bold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }
        .padding(16)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(colorScheme == .dark ? Color(.secondarySystemBackground) : .white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16)
                .stroke(color.opacity(0.2), lineWidth: 1)
        )
        .shadow(color: colorScheme == .dark ? .clear : .black.opacity(0.05), radius: 8, y: 4)
    }
}

// MARK: - TicketWalletEmptyState

struct TicketWalletEmptyState: View {
    let onAddTicket: () -> Void
    @Environment(\.colorScheme) var colorScheme
    @State private var animate = false

    var body: some View {
        VStack(spacing: 32) {
            Spacer()

            // Animated illustration
            ZStack {
                Circle()
                    .fill(Color.green.opacity(colorScheme == .dark ? 0.15 : 0.1))
                    .frame(width: 140, height: 140)
                    .scaleEffect(animate ? 1.1 : 1.0)

                Image(systemName: "wallet.pass.fill")
                    .font(.system(size: 60))
                    .foregroundStyle(Color.green)
                    .offset(y: animate ? -3 : 3)
            }

            // Content
            VStack(spacing: 12) {
                Text("Your Ticket Wallet")
                    .font(.title2.weight(.bold))

                Text("Store your train tickets digitally and access them anytime you need")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 40)
            }

            // Features
            VStack(spacing: 16) {
                TicketFeatureRow(icon: "qrcode.viewfinder", text: "Scan your physical tickets")
                TicketFeatureRow(icon: "checkmark.circle.fill", text: "Set your default ticket")
                TicketFeatureRow(icon: "arrow.up.left.and.arrow.down.right", text: "View in fullscreen with zoom")
            }
            .padding(.horizontal, 40)

            // CTA
            Button(action: onAddTicket) {
                Label("Add Your First Ticket", systemImage: "plus")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 16)
            }
            .buttonStyle(.borderedProminent)
            .padding(.horizontal, 40)
            .padding(.top, 8)

            Spacer()
        }
        .frame(maxWidth: .infinity)
        .onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) {
                animate = true
            }
        }
    }
}

// MARK: - TicketFeatureRow

struct TicketFeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.green)
                .frame(width: 24)

            Text(text)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()
        }
    }
}

// MARK: - TicketCardPreview

struct TicketCardPreview: View {
    let ticket: TicketCard
    let isSelected: Bool
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Ticket image
            ZStack(alignment: .topTrailing) {
                if let data = ticket.frontImageData, let uiImage = UIImage(data: data) {
                    Image(uiImage: uiImage)
                        .resizable()
                        .aspectRatio(1.586, contentMode: .fill)
                        .frame(height: 220)
                        .clipped()
                } else {
                    Rectangle()
                        .fill(Color.gray.opacity(colorScheme == .dark ? 0.3 : 0.15))
                        .aspectRatio(1.586, contentMode: .fill)
                        .frame(height: 220)
                        .overlay {
                            VStack(spacing: 12) {
                                Image(systemName: "creditcard")
                                    .font(.system(size: 48))
                                    .foregroundStyle(.secondary)
                                Text("No image")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                }

                // Selected badge
                if isSelected {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark.circle.fill")
                            .font(.subheadline)
                        Text("DEFAULT")
                            .font(.caption2.weight(.bold))
                            .tracking(0.5)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 6)
                    .background(
                        Capsule()
                            .fill(Color.green)
                    )
                    .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
                    .padding(12)
                }
            }

            // Ticket info
            HStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(ticket.name)
                        .font(.title3.weight(.semibold))
                        .foregroundStyle(.primary)
                        .lineLimit(1)

                    HStack(spacing: 6) {
                        Image(systemName: "calendar")
                            .font(.caption2)
                        Text("Added \(ticket.createdAt, style: .date)")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
            }
            .padding(20)
        }
        .background(
            RoundedRectangle(cornerRadius: 20)
                .fill(colorScheme == .dark ? Color(.secondarySystemBackground) : .white)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 20)
                .stroke(
                    isSelected ? Color.green
                        .opacity(0.3) : (colorScheme == .dark ? Color.white.opacity(0.1) : Color.clear),
                    lineWidth: isSelected ? 2 : 1
                )
        )
        .shadow(color: colorScheme == .dark ? .clear : .black.opacity(0.08), radius: 16, y: 6)
    }
}

// MARK: - TicketDetailView

struct TicketDetailView: View {
    let ticket: TicketCard
    let onDelete: (() -> Void)?
    let onSetDefault: (() -> Void)?

    @EnvironmentObject private var settingsManager: SettingsManager
    @Environment(\.dismiss) private var dismiss
    @State private var isFlipped = false
    @State private var showFullscreen = false
    @State private var showDeleteConfirm = false
    @Environment(\.colorScheme) var colorScheme
    private let brightness = UIScreen.main.brightness

    init(ticket: TicketCard, onDelete: (() -> Void)? = nil, onSetDefault: (() -> Void)? = nil) {
        self.ticket = ticket
        self.onDelete = onDelete
        self.onSetDefault = onSetDefault
    }

    var body: some View {
        ScrollView {
            VStack(spacing: 32) {
                // Card preview with flip
                VStack(spacing: 16) {
                    FlipCardView(ticket: ticket, isFlipped: $isFlipped)
                        .onTapGesture {
                            Haptics.impact(.light)
                            withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) {
                                isFlipped.toggle()
                            }
                        }

                    HStack(spacing: 8) {
                        Image(systemName: "hand.tap.fill")
                            .font(.caption2)
                        Text("Tap to flip • \(isFlipped ? "Back" : "Front") side")
                            .font(.caption)
                    }
                    .foregroundStyle(.secondary)
                }
                .padding(.top, 20)

                // Actions
                VStack(spacing: 16) {
                    Button(action: {
                        Haptics.impact(.light)
                        showFullscreen = true
                    }) {
                        Label("View Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.bordered)
                    .tint(.green)

                    Button(action: {
                        Haptics.selection()
                        setAsDefault()
                    }) {
                        Label(
                            settingsManager.appSettings.selectedTicketId == ticket
                                .id ? "Default Ticket" : "Set as Default",
                            systemImage: settingsManager.appSettings.selectedTicketId == ticket
                                .id ? "checkmark.circle.fill" : "circle"
                        )
                        .font(.subheadline.weight(.semibold))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 16)
                    }
                    .buttonStyle(.bordered)
                    .tint(.blue)
                    .disabled(settingsManager.appSettings.selectedTicketId == ticket.id)

                    Button(role: .destructive, action: {
                        Haptics.selection()
                        showDeleteConfirm = true
                    }) {
                        Label("Delete Ticket", systemImage: "trash")
                            .font(.subheadline.weight(.semibold))
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal, 20)

                // Ticket info
                VStack(alignment: .leading, spacing: 12) {
                    InfoRow(
                        icon: "calendar",
                        label: "Added",
                        value: ticket.createdAt.formatted(date: .long, time: .omitted)
                    )
                    InfoRow(
                        icon: "qrcode",
                        label: "Front Image",
                        value: ticket.frontImageData != nil ? "Available" : "Not set"
                    )
                    InfoRow(
                        icon: "qrcode",
                        label: "Back Image",
                        value: ticket.backImageData != nil ? "Available" : "Not set"
                    )
                }
                .padding(20)
                .background(
                    RoundedRectangle(cornerRadius: 16)
                        .fill(colorScheme == .dark ? Color(.secondarySystemBackground) : Color(.systemGray6))
                )
                .padding(.horizontal, 20)
            }
            .padding(.bottom, 20)
        }
        .background(colorScheme == .dark ? Color(.systemBackground) : Color(.systemGroupedBackground))
        .navigationTitle(ticket.name)
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(isPresented: $showFullscreen) {
            FullscreenTicketView(ticket: ticket, isFlipped: $isFlipped, brightness: brightness)
        }
        .confirmationDialog("Delete this ticket?", isPresented: $showDeleteConfirm, titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                Haptics.notification(.warning)
                deleteTicket()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This action cannot be undone.")
        }
    }

    private func setAsDefault() {
        var settings = settingsManager.appSettings
        settings.selectedTicketId = ticket.id
        settingsManager.updateAppSettings(settings)
        onSetDefault?()
    }

    private func deleteTicket() {
        var settings = settingsManager.appSettings
        settings.ticketCards.removeAll { $0.id == ticket.id }
        if settings.selectedTicketId == ticket.id {
            settings.selectedTicketId = settings.ticketCards.first?.id
        }
        settingsManager.updateAppSettings(settings)
        onDelete?()
        dismiss()
    }
}

// MARK: - InfoRow

struct InfoRow: View {
    let icon: String
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon)
                .font(.body)
                .foregroundStyle(.green)
                .frame(width: 24)

            Text(label)
                .font(.subheadline)
                .foregroundStyle(.secondary)

            Spacer()

            Text(value)
                .font(.subheadline.weight(.medium))
                .foregroundStyle(.primary)
        }
    }
}

// MARK: - FlipCardView

struct FlipCardView: View {
    let ticket: TicketCard
    @Binding var isFlipped: Bool

    var body: some View {
        ZStack {
            CardFaceView(imageData: ticket.frontImageData).opacity(isFlipped ? 0 : 1).rotation3DEffect(
                .degrees(isFlipped ? 180 : 0),
                axis: (x: 0, y: 1, z: 0)
            )
            CardFaceView(imageData: ticket.backImageData).opacity(isFlipped ? 1 : 0).rotation3DEffect(
                .degrees(isFlipped ? 0 : -180),
                axis: (x: 0, y: 1, z: 0)
            )
        }.frame(maxWidth: .infinity).aspectRatio(1.586, contentMode: .fit).padding(.horizontal, 16)
    }
}

// MARK: - CardFaceView

struct CardFaceView: View {
    let imageData: Data?
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Group {
            if let data = imageData,
               let uiImage = UIImage(data: data)
            { Image(uiImage: uiImage).resizable().aspectRatio(
                1.586,
                contentMode: .fill
            ) } else {
                Rectangle().fill(colorScheme == .dark ? Color(.secondarySystemBackground) : Color.gray.opacity(0.1))
                    .overlay { Image(systemName: "creditcard").font(.largeTitle).foregroundStyle(.secondary) }
            }
        }.clipShape(RoundedRectangle(cornerRadius: 16)).shadow(color: .black.opacity(0.2), radius: 12, y: 6)
    }
}

// MARK: - FullscreenTicketView

struct FullscreenTicketView: View {
    let ticket: TicketCard
    @Binding var isFlipped: Bool
    var brightness: CGFloat
    @Environment(\.dismiss) private var dismiss
    @State private var scale: CGFloat = 1.0
    @State private var lastScale: CGFloat = 1.0
    @State private var offset: CGSize = .zero
    @State private var lastOffset: CGSize = .zero

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Color.black.ignoresSafeArea()
                Group {
                    if let data = (isFlipped ? ticket.backImageData : ticket.frontImageData),
                       let uiImage = UIImage(data: data)
                    {
                        Image(uiImage: uiImage).resizable().aspectRatio(contentMode: .fit)
                    } else {
                        Rectangle().fill(Color.gray.opacity(0.3)).aspectRatio(1.586, contentMode: .fit)
                            .overlay {
                                Image(systemName: "creditcard").font(.system(size: 60)).foregroundStyle(.secondary)
                            }
                    }
                }
                .rotationEffect(.degrees(90)).frame(width: geo.size.height, height: geo.size.width).scaleEffect(scale)
                .offset(offset).position(
                    x: geo.size.width / 2,
                    y: geo.size.height / 2
                )
                .gesture(MagnificationGesture().onChanged { scale = lastScale * $0 }.onEnded { _ in
                    if scale < 1.0 { withAnimation(.spring(
                        response: 0.3,
                        dampingFraction: 0.7
                    )) { scale = 1.0; lastScale = 1.0; offset = .zero; lastOffset = .zero } } else { lastScale = scale }
                })
                .simultaneousGesture(DragGesture().onChanged { offset = CGSize(
                    width: lastOffset.width + $0.translation.width,
                    height: lastOffset.height + $0.translation.height
                ) }.onEnded { _ in lastOffset = offset })
                .onTapGesture { withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { isFlipped.toggle() } }
                VStack {
                    HStack {
                        Spacer(); Button { dismiss() } label: {
                            Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.8))
                                .padding()
                        }
                    }; Spacer(); Text("Tap to flip · Pinch to zoom").font(.caption)
                        .foregroundStyle(.white.opacity(0.6)).padding(
                            .bottom,
                            20
                        )
                }
            }
        }.onAppear { UIScreen.main.brightness = 1.0 }.onDisappear { UIScreen.main.brightness = brightness }
    }
}

// MARK: - QuickTicketButton

struct QuickTicketButton: View {
    @EnvironmentObject private var settingsManager: SettingsManager

    var body: some View {
        NavigationLink {
            TicketWalletView()
        } label: {
            if !settingsManager.appSettings.ticketCards.isEmpty { Image(systemName: "wallet.pass.fill") }
            else { ZStack { Image(systemName: "wallet.pass"); Image(systemName: "plus.circle.fill").font(.system(
                size: 12,
                weight: .bold
            )).foregroundStyle(.white, .green).offset(x: -4, y: 4) } }
        }
    }
}

// MARK: - TicketScannerView

struct TicketScannerView: View {
    let onTicketAdded: ((String) -> Void)?

    @EnvironmentObject private var settingsManager: SettingsManager
    @Environment(\.dismiss) private var dismiss
    @State private var ticketName = ""
    @State private var frontImage: UIImage?
    @State private var backImage: UIImage?
    @State private var selectedItem: PhotosPickerItem?
    @State private var currentSide: CardSide = .front
    @State private var showFrontSourcePicker = false
    @State private var showBackSourcePicker = false
    @State private var showCamera = false
    @State private var showPhotoPicker = false
    @State private var showWarning = true
    @Environment(\.colorScheme) var colorScheme

    init(onTicketAdded: ((String) -> Void)? = nil) {
        self.onTicketAdded = onTicketAdded
    }

    enum CardSide { case front, back }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 28) {
                    // Warning banner
                    if showWarning {
                        HStack(spacing: 12) {
                            Image(systemName: "exclamationmark.triangle.fill")
                                .foregroundStyle(.orange)
                            Text("No validation is performed. Ensure your ticket is configured correctly.")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                            Spacer()
                            Button {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    showWarning = false
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundStyle(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(16)
                        .background(
                            RoundedRectangle(cornerRadius: 12)
                                .fill(Color.orange.opacity(0.1))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .stroke(Color.orange.opacity(0.3), lineWidth: 1)
                        )
                        .padding(.horizontal, 20)
                    }

                    // Ticket name input
                    VStack(alignment: .leading, spacing: 12) {
                        Label("Ticket Name", systemImage: "tag.fill")
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.secondary)

                        TextField("e.g., Monthly Pass, Student Card", text: $ticketName)
                            .textFieldStyle(.plain)
                            .font(.body)
                            .padding(16)
                            .background(
                                RoundedRectangle(cornerRadius: 12)
                                    .fill(colorScheme == .dark ? Color(.secondarySystemBackground) :
                                        Color(.systemGray6))
                            )
                    }
                    .padding(.horizontal, 20)

                    // Front image
                    VStack(spacing: 16) {
                        Label("Front of Card", systemImage: "creditcard.fill")
                            .font(.headline)
                        ModernCardScanButton(image: frontImage, side: "Front") {
                            currentSide = .front
                            showFrontSourcePicker = true
                        }
                        .confirmationDialog(
                            "Select Image Source",
                            isPresented: $showFrontSourcePicker,
                            titleVisibility: .visible
                        ) {
                            Button {
                                showCamera = true
                            } label: {
                                Label("Take Photo", systemImage: "camera")
                            }
                            Button {
                                showPhotoPicker = true
                            } label: {
                                Label("Choose from Library", systemImage: "photo.on.rectangle")
                            }
                            Button("Cancel", role: .cancel) {}
                        }
                    }

                    // Swap button
                    if frontImage != nil || backImage != nil {
                        Button {
                            Haptics.selection()
                            withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                let temp = frontImage
                                frontImage = backImage
                                backImage = temp
                            }
                        } label: {
                            Label("Swap Front & Back", systemImage: "arrow.up.arrow.down")
                                .font(.subheadline.weight(.semibold))
                        }
                        .buttonStyle(.bordered)
                        .tint(.orange)
                    }

                    // Back image
                    VStack(spacing: 16) {
                        Label("Back of Card", systemImage: "creditcard")
                            .font(.headline)
                        ModernCardScanButton(image: backImage, side: "Back") {
                            currentSide = .back
                            showBackSourcePicker = true
                        }
                        .confirmationDialog(
                            "Select Image Source",
                            isPresented: $showBackSourcePicker,
                            titleVisibility: .visible
                        ) {
                            Button {
                                showCamera = true
                            } label: {
                                Label("Take Photo", systemImage: "camera")
                            }
                            Button {
                                showPhotoPicker = true
                            } label: {
                                Label("Choose from Library", systemImage: "photo.on.rectangle")
                            }
                            Button("Cancel", role: .cancel) {}
                        }
                    }

                    // Save button
                    Button {
                        Haptics.notification(.success)
                        saveTicket()
                    } label: {
                        Label("Save Ticket", systemImage: "checkmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 18)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(ticketName.isEmpty || frontImage == nil)
                    .padding(.horizontal, 20)
                    .padding(.top, 12)
                }
                .padding(.vertical, 24)
            }
            .background(colorScheme == .dark ? Color(.systemBackground) : Color(.systemGroupedBackground))
            .navigationTitle("Add Ticket")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .fullScreenCover(isPresented: $showCamera) {
                CameraCaptureView { image in
                    if currentSide == .front {
                        frontImage = image
                    } else {
                        backImage = image
                    }
                }
            }
            .photosPicker(isPresented: $showPhotoPicker, selection: $selectedItem, matching: .images)
            .onChange(of: selectedItem) { _, newItem in
                Task {
                    if let data = try? await newItem?.loadTransferable(type: Data.self),
                       let image = UIImage(data: data)
                    {
                        if currentSide == .front {
                            frontImage = image
                        } else {
                            backImage = image
                        }
                    }
                    selectedItem = nil
                }
            }
        }
    }

    private func saveTicket() {
        // Use PNG for lossless quality - critical for QR code scanning
        let ticket = TicketCard(
            name: ticketName,
            frontImageData: frontImage?.pngData(),
            backImageData: backImage?.pngData()
        )
        var settings = settingsManager.appSettings
        settings.ticketCards.append(ticket)
        if settings.selectedTicketId == nil {
            settings.selectedTicketId = ticket.id
        }
        settingsManager.updateAppSettings(settings)
        onTicketAdded?(ticketName)
        dismiss()
    }
}

// MARK: - ModernCardScanButton

struct ModernCardScanButton: View {
    let image: UIImage?
    let side: String
    let action: () -> Void
    @Environment(\.colorScheme) var colorScheme

    var body: some View {
        Button(action: action) {
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(1.586, contentMode: .fill)
                    .frame(height: 240)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .overlay(
                        RoundedRectangle(cornerRadius: 16)
                            .stroke(Color.green, lineWidth: 3)
                    )
                    .shadow(color: .black.opacity(0.1), radius: 12, y: 6)
            } else {
                RoundedRectangle(cornerRadius: 16)
                    .strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [12]))
                    .foregroundStyle(Color.accentColor.opacity(0.5))
                    .aspectRatio(1.586, contentMode: .fill)
                    .frame(height: 240)
                    .overlay {
                        VStack(spacing: 16) {
                            ZStack {
                                Circle()
                                    .fill(Color.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.1))
                                    .frame(width: 80, height: 80)
                                Image(systemName: "camera.fill")
                                    .font(.title)
                                    .foregroundStyle(Color.accentColor)
                            }
                            VStack(spacing: 4) {
                                Text("Tap to scan \(side)")
                                    .font(.subheadline.weight(.semibold))
                                Text("or choose from library")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .foregroundStyle(Color.accentColor)
                    }
            }
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 20)
    }
}

// MARK: - CardScanButton

struct CardScanButton: View {
    let image: UIImage?
    let side: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            if let image {
                Image(uiImage: image).resizable().aspectRatio(1.586, contentMode: .fill).frame(height: 200)
                    .clipShape(RoundedRectangle(cornerRadius: 12)).overlay(RoundedRectangle(cornerRadius: 12).stroke(
                        Color.accentColor,
                        lineWidth: 2
                    ))
            } else {
                RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .foregroundStyle(.secondary).aspectRatio(
                        1.586,
                        contentMode: .fill
                    ).frame(height: 200)
                    .overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "camera.fill").font(.title); Text("Tap to scan \(side)")
                                .font(.subheadline)
                        }
                        .foregroundStyle(.secondary)
                    }
            }
        }.buttonStyle(.plain).padding(.horizontal)
    }
}

// MARK: - CameraCaptureView

struct CameraCaptureView: View {
    let onCapture: (UIImage) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = CameraModel()
    @State private var isCapturing = false
    @State private var capturedImage: UIImage?
    @State private var cardWasDetected = false

    var body: some View {
        ZStack {
            if let image = capturedImage {
                // Preview mode - show captured image with retake option
                previewView(image: image)
            } else {
                // Camera mode
                cameraView
            }
        }
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
    }

    private var cameraView: some View {
        ZStack {
            CameraPreviewLayer(session: camera.session).ignoresSafeArea()
            GeometryReader { geo in
                let cardWidth = max(0, geo.size.width - 40)
                let cardHeight = max(0, cardWidth / 1.586)

                CardVignetteOverlay(cardWidth: cardWidth, cardHeight: cardHeight).fill(Color.black.opacity(0.6))
                    .ignoresSafeArea()
                RoundedRectangle(cornerRadius: 12)
                    .stroke(camera.status == .detected ? .green : .white, lineWidth: 3)
                    .frame(width: cardWidth, height: cardHeight)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }
            VStack {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.8))
                            .padding()
                    }
                    Spacer()
                    Button { camera.toggleTorch() } label: {
                        Image(systemName: camera.torchEnabled ? "flashlight.on.fill" : "flashlight.off.fill")
                            .font(.title2)
                            .foregroundStyle(camera.torchEnabled ? .yellow : .white.opacity(0.8))
                            .padding()
                    }
                }
                Spacer()
                Text(camera.status == .detected ? "Card detected" : "Position card within frame")
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 8)
                    .background((camera.status == .detected ? Color.green : Color.white).opacity(0.8), in: Capsule())
                Button {
                    guard !isCapturing else { return }
                    isCapturing = true
                    let wasDetected = camera.status == .detected
                    camera.capturePhoto { image in
                        isCapturing = false
                        guard let image else { dismiss(); return }
                        cardWasDetected = wasDetected
                        withAnimation(.easeInOut(duration: 0.2)) {
                            capturedImage = image
                        }
                    }
                } label: {
                    ZStack {
                        Circle().fill(camera.status == .detected ? .green : .white).frame(width: 70, height: 70)
                        Circle().stroke(Color.white.opacity(0.3), lineWidth: 4).frame(width: 80, height: 80)
                        if isCapturing {
                            ProgressView().tint(.gray)
                        } else if camera.status == .detected {
                            Image(systemName: "checkmark").font(.title.bold()).foregroundStyle(.white)
                        }
                    }
                }
                .disabled(isCapturing)
                .padding(.top, 16)
                Spacer().frame(height: 40)
            }
        }
    }

    private func previewView(image: UIImage) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                // Header
                HStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            capturedImage = nil
                        }
                    } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title)
                            .foregroundStyle(.white.opacity(0.8))
                            .padding()
                    }
                    Spacer()
                }

                Spacer()

                // Image preview
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .clipShape(RoundedRectangle(cornerRadius: 16))
                    .padding(.horizontal, 20)

                Spacer()

                // Warning if card wasn't detected
                if !cardWasDetected {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                        Text("Card not auto-detected. Image may need manual cropping.")
                            .font(.subheadline)
                    }
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                    .background(Color.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 12))
                    .padding(.horizontal, 20)
                    .padding(.bottom, 16)
                }

                // Action buttons
                HStack(spacing: 20) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) {
                            capturedImage = nil
                        }
                    } label: {
                        Label("Retake", systemImage: "arrow.counterclockwise")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.bordered)
                    .tint(.white)

                    Button {
                        onCapture(image)
                        dismiss()
                    } label: {
                        Label("Use Photo", systemImage: "checkmark")
                            .font(.headline)
                            .frame(maxWidth: .infinity)
                            .padding(.vertical, 16)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 40)
            }
        }
    }
}

// MARK: - CardVignetteOverlay

struct CardVignetteOverlay: Shape {
    let cardWidth: CGFloat
    let cardHeight: CGFloat
    func path(in rect: CGRect) -> Path {
        var path = Path(rect)
        path.addRoundedRect(
            in: CGRect(
                x: (rect.width - cardWidth) / 2,
                y: (rect.height - cardHeight) / 2,
                width: cardWidth,
                height: cardHeight
            ),
            cornerSize: CGSize(width: 12, height: 12)
        )
        return path
    }
}

// MARK: - CameraPreviewLayer

struct CameraPreviewLayer: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context)
        -> UIView
    { let view = UIView(); let layer = AVCaptureVideoPreviewLayer(session: session); layer
        .videoGravity = .resizeAspectFill; view.layer.addSublayer(layer); DispatchQueue.main
        .async { layer.frame = view.bounds }; context.coordinator.layer = layer; return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.layer?.frame = uiView.bounds }
    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator { var layer: AVCaptureVideoPreviewLayer? }
}

// MARK: - CameraStatus

enum CameraStatus { case searching, detected }

// MARK: - CameraModel

class CameraModel: NSObject, ObservableObject, AVCapturePhotoCaptureDelegate,
AVCaptureVideoDataOutputSampleBufferDelegate {
    let session = AVCaptureSession()
    private let photoOutput = AVCapturePhotoOutput()
    private let videoOutput = AVCaptureVideoDataOutput()
    private var completion: ((UIImage?) -> Void)?
    private var device: AVCaptureDevice?
    @Published var status: CameraStatus = .searching
    @Published var torchEnabled = false
    private let detectQueue = DispatchQueue(label: "detect", qos: .userInteractive)
    private var frameCount = 0 // For throttling frame processing
    // Simplified CIContext for better performance
    private let ciContext = CIContext(options: [.useSoftwareRenderer: false])

    // Detection stabilization - require consistent detection before changing status
    private var detectionCount = 0
    private let detectionThreshold = 3

    private lazy var rectangleRequest: VNDetectRectanglesRequest = {
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 1.3
        request.maximumAspectRatio = 1.75
        request.minimumSize = 0.2
        request.minimumConfidence = 0.8
        request.maximumObservations = 1
        return request
    }()

    func start() {
        guard session.inputs.isEmpty else { return }
        // Use .photo for maximum quality - critical for QR code scanning
        session.sessionPreset = .photo
        guard let device = AVCaptureDevice.default(.builtInWideAngleCamera, for: .video, position: .back),
              let input = try? AVCaptureDeviceInput(device: device) else { return }
        self.device = device

        // Configure device for optimal card scanning
        try? device.lockForConfiguration()
        if device.isFocusModeSupported(.continuousAutoFocus) { device.focusMode = .continuousAutoFocus }
        if device.isAutoFocusRangeRestrictionSupported { device.autoFocusRangeRestriction = .near }
        if device.isExposureModeSupported(.continuousAutoExposure) { device.exposureMode = .continuousAutoExposure }
        device.unlockForConfiguration()

        if session.canAddInput(input) { session.addInput(input) }

        // Configure photo output for maximum quality (critical for QR code readability)
        if session.canAddOutput(photoOutput) {
            session.addOutput(photoOutput)

            // Use modern maxPhotoDimensions API instead of deprecated isHighResolutionCaptureEnabled
            if #available(iOS 16.0, *) {
                // Use device's maximum supported dimensions for best QR code quality
                photoOutput.maxPhotoDimensions = device.activeFormat.supportedMaxPhotoDimensions.first ?? .init(
                    width: 4032,
                    height: 3024
                )
            } else {
                photoOutput.isHighResolutionCaptureEnabled = true
            }

            // Use quality prioritization for QR codes (need sharp, detailed images)
            photoOutput.maxPhotoQualityPrioritization = .quality
        }

        videoOutput.setSampleBufferDelegate(self, queue: detectQueue)
        videoOutput.alwaysDiscardsLateVideoFrames = true
        if session.canAddOutput(videoOutput) { session.addOutput(videoOutput) }

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.session.startRunning() }
    }

    func stop() {
        setTorch(false)
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in self?.session.stopRunning() }
    }

    func toggleTorch() { setTorch(!torchEnabled) }

    private func setTorch(_ enabled: Bool) {
        guard let device, device.hasTorch, device.isTorchAvailable else { return }
        try? device.lockForConfiguration()
        device.torchMode = enabled ? .on : .off
        device.unlockForConfiguration()
        DispatchQueue.main.async { self.torchEnabled = enabled }
    }

    func capturePhoto(completion: @escaping (UIImage?) -> Void) {
        self.completion = completion

        // Use HEVC for excellent quality with good compression (ideal for QR codes)
        let settings = AVCapturePhotoSettings(format: [AVVideoCodecKey: AVVideoCodecType.hevc])
        settings.flashMode = device?.hasFlash == true && !torchEnabled ? .auto : .off
        // Quality prioritization for sharp QR code capture
        settings.photoQualityPrioritization = .quality
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    func photoOutput(_: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error _: Error?) {
        guard let data = photo.fileDataRepresentation(),
              let image = UIImage(data: data) else { completion?(nil); return }
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let processed = self?.detectAndCorrect(image) ?? image
            DispatchQueue.main.async { self?.completion?(processed) }
        }
    }

    /// Detect rectangle directly on the captured photo and apply perspective correction
    private func detectAndCorrect(_ image: UIImage) -> UIImage {
        guard let cgImage = image.cgImage else { return image }

        // Run detection on the actual captured photo with correct orientation
        let orientation = CGImagePropertyOrientation(image.imageOrientation)
        let handler = VNImageRequestHandler(cgImage: cgImage, orientation: orientation, options: [:])
        let request = VNDetectRectanglesRequest()
        request.minimumAspectRatio = 1.3
        request.maximumAspectRatio = 1.75
        request.minimumSize = 0.15
        request.minimumConfidence = 0.7
        request.maximumObservations = 1

        try? handler.perform([request])
        guard let rect = request.results?.first else { return image }

        // Create CIImage and orient it
        guard let ciImage = CIImage(image: image)?.oriented(orientation) else { return image }
        let w = ciImage.extent.width, h = ciImage.extent.height

        // Convert normalized Vision coordinates to image coordinates
        let topLeft = CGPoint(x: rect.topLeft.x * w, y: rect.topLeft.y * h)
        let topRight = CGPoint(x: rect.topRight.x * w, y: rect.topRight.y * h)
        let bottomLeft = CGPoint(x: rect.bottomLeft.x * w, y: rect.bottomLeft.y * h)
        let bottomRight = CGPoint(x: rect.bottomRight.x * w, y: rect.bottomRight.y * h)

        // Apply perspective correction filter - preserves native resolution for maximum QR clarity
        guard let filter = CIFilter(name: "CIPerspectiveCorrection") else { return image }
        filter.setValue(ciImage, forKey: kCIInputImageKey)
        filter.setValue(CIVector(cgPoint: topLeft), forKey: "inputTopLeft")
        filter.setValue(CIVector(cgPoint: topRight), forKey: "inputTopRight")
        filter.setValue(CIVector(cgPoint: bottomLeft), forKey: "inputBottomLeft")
        filter.setValue(CIVector(cgPoint: bottomRight), forKey: "inputBottomRight")

        guard let corrected = filter.outputImage else { return image }

        // Enhance contrast for better QR code readability (avoid sharpening which adds artifacts)
        let enhanced = corrected.applyingFilter("CIColorControls", parameters: [
            kCIInputContrastKey: 1.05,
            kCIInputSaturationKey: 1.0
        ])

        guard let outputCGImage = ciContext.createCGImage(enhanced, from: enhanced.extent) else { return image }
        return UIImage(cgImage: outputCGImage)
    }

    func captureOutput(_: AVCaptureOutput, didOutput sampleBuffer: CMSampleBuffer, from _: AVCaptureConnection) {
        // Throttle processing to every 3rd frame for better performance
        frameCount += 1
        guard frameCount % 3 == 0 else { return }

        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Tell Vision about the video frame orientation (camera native is landscape right)
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, orientation: .right, options: [:])
        try? handler.perform([rectangleRequest])
        let detected = rectangleRequest.results?.first != nil

        // Stabilize detection to prevent flickering
        if detected {
            detectionCount = min(detectionCount + 1, detectionThreshold + 1)
        } else {
            detectionCount = max(detectionCount - 1, 0)
        }

        let newStatus: CameraStatus = detectionCount >= detectionThreshold ? .detected : .searching
        DispatchQueue.main.async { [weak self] in
            guard let self, status != newStatus else { return }
            status = newStatus
        }
    }
}

private extension CGImagePropertyOrientation {
    init(_ uiOrientation: UIImage.Orientation) {
        switch uiOrientation {
        case .up: self = .up
        case .down: self = .down
        case .left: self = .left
        case .right: self = .right
        case .upMirrored: self = .upMirrored
        case .downMirrored: self = .downMirrored
        case .leftMirrored: self = .leftMirrored
        case .rightMirrored: self = .rightMirrored
        @unknown default: self = .up
        }
    }
}
