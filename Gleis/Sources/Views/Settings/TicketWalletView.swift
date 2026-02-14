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
        scrollContent
            .background(backgroundColor)
            .navigationTitle("Ticket Wallet")
            .toolbar { toolbarContent }
            .sheet(isPresented: $showAddTicket) { scannerSheet }
            .overlay(alignment: .top) { toastOverlay }
    }

    private var scrollContent: some View {
        ScrollView {
            if tickets.isEmpty {
                TicketWalletEmptyState { showAddTicket = true }
            } else {
                VStack(spacing: 20) {
                    headerStats
                    ticketsGrid
                }.padding(.vertical, 12)
            }
        }
    }

    private var backgroundColor: Color {
        colorScheme == .dark ? Color(.systemBackground) : Color(.systemGroupedBackground)
    }

    private var headerStats: some View {
        HStack(spacing: 12) {
            StatCard(
                icon: "wallet.pass.fill", value: "\(tickets.count)",
                label: tickets.count == 1 ? "Ticket" : "Tickets", color: .green
            ).fixedSize(horizontal: true, vertical: false)

            if let selectedId = settingsManager.appSettings.selectedTicketId,
               let selected = tickets.first(where: { $0.id == selectedId })
            {
                StatCard(
                    icon: "checkmark.circle.fill", value: selected.name, label: "Default", color: .blue
                ).frame(maxWidth: .infinity)
            }
        }.padding(.horizontal, 20).padding(.top, 8)
    }

    private var ticketsGrid: some View {
        LazyVStack(spacing: 20) {
            ForEach(tickets) { ticket in
                NavigationLink {
                    TicketDetailView(
                        ticket: ticket, onDelete: { displayToast("Ticket deleted", type: .info) },
                        onSetDefault: { displayToast("Set as default ticket", type: .success) }
                    )
                } label: {
                    TicketCardPreview(
                        ticket: ticket,
                        isSelected: settingsManager.appSettings.selectedTicketId == ticket.id
                    )
                }.buttonStyle(.plain)
            }
        }.padding(.horizontal, 20)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .primaryAction) {
            Button {
                showAddTicket = true
            } label: {
                Image(systemName: "plus").fontWeight(.semibold)
            }
        }
    }

    private var scannerSheet: some View {
        TicketScannerView { ticketName in
            displayToast(
                tickets.count == 1 ? "🎉 First ticket added!" : "Ticket '\(ticketName)' added", type: .success
            )
        }
    }

    @ViewBuilder
    private var toastOverlay: some View {
        if showToast {
            ToastView(message: toastMessage, type: toastType)
                .padding(.top, 60)
                .transition(.move(edge: .top).combined(with: .opacity))
                .onAppear {
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) { withAnimation { showToast = false } }
                }
        }
    }

    private func displayToast(_ message: String, type: ToastView.ToastType = .info) {
        toastMessage = message
        toastType = type
        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { showToast = true }
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
            Image(systemName: icon).font(.title2).foregroundStyle(color).frame(width: 40, height: 40).background(
                Circle().fill(color.opacity(colorScheme == .dark ? 0.2 : 0.1)))

            VStack(alignment: .leading, spacing: 2) {
                Text(value).font(.title3.weight(.bold)).foregroundStyle(.primary).lineLimit(1).minimumScaleFactor(0.7)

                Text(label).font(.caption).foregroundStyle(.secondary)
            }

            Spacer(minLength: 0)
        }.padding(16).background(
            RoundedRectangle(cornerRadius: 16).fill(colorScheme == .dark ? Color(.secondarySystemBackground) : .white)
        ).overlay(RoundedRectangle(cornerRadius: 16).stroke(color.opacity(0.2), lineWidth: 1)).shadow(
            color: colorScheme == .dark ? .clear : .black.opacity(0.05), radius: 8, y: 4
        )
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
                Circle().fill(Color.green.opacity(colorScheme == .dark ? 0.15 : 0.1)).frame(width: 140, height: 140)
                    .scaleEffect(animate ? 1.1 : 1.0)

                Image(systemName: "wallet.pass.fill").font(.system(size: 60)).foregroundStyle(Color.green).offset(
                    y: animate ? -3 : 3)
            }

            // Content
            VStack(spacing: 12) {
                Text("Your Ticket Wallet").font(.title2.weight(.bold))

                Text("Store your train tickets digitally and access them anytime you need").font(.subheadline)
                    .foregroundStyle(.secondary).multilineTextAlignment(.center).padding(.horizontal, 40)
            }

            // Features
            VStack(spacing: 16) {
                TicketFeatureRow(icon: "qrcode.viewfinder", text: "Scan your physical tickets")
                TicketFeatureRow(icon: "checkmark.circle.fill", text: "Set your default ticket")
                TicketFeatureRow(icon: "arrow.up.left.and.arrow.down.right", text: "View in fullscreen with zoom")
            }.padding(.horizontal, 40)

            // CTA
            Button(action: onAddTicket) {
                Label("Add Your First Ticket", systemImage: "plus").font(.headline).frame(maxWidth: .infinity).padding(
                    .vertical, 16
                )
            }.buttonStyle(.borderedProminent).padding(.horizontal, 40).padding(.top, 8)

            Spacer()
        }.frame(maxWidth: .infinity).onAppear {
            withAnimation(.easeInOut(duration: 2).repeatForever(autoreverses: true)) { animate = true }
        }
    }
}

// MARK: - TicketFeatureRow

struct TicketFeatureRow: View {
    let icon: String
    let text: String

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.body).foregroundStyle(.green).frame(width: 24)

            Text(text).font(.subheadline).foregroundStyle(.secondary)

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
            ticketImageSection
            ticketInfoSection
        }
        .background(cardBackground)
        .overlay(cardBorder)
        .shadow(color: shadowColor, radius: 16, y: 6)
    }

    // MARK: - Subviews

    private var ticketImageSection: some View {
        ZStack(alignment: .topTrailing) {
            ticketImage
            if isSelected { selectedBadge }
        }
    }

    @ViewBuilder
    private var ticketImage: some View {
        if let data = ticket.frontImageData, let uiImage = UIImage(data: data) {
            Image(uiImage: uiImage)
                .resizable()
                .aspectRatio(1.586, contentMode: .fill)
                .frame(height: 220)
                .clipped()
        } else {
            placeholderImage
        }
    }

    private var placeholderImage: some View {
        let fillOpacity: Double = colorScheme == .dark ? 0.3 : 0.15
        return Rectangle()
            .fill(Color.gray.opacity(fillOpacity))
            .aspectRatio(1.586, contentMode: .fill)
            .frame(height: 220)
            .overlay {
                VStack(spacing: 12) {
                    Image(systemName: "creditcard").font(.system(size: 48)).foregroundStyle(.secondary)
                    Text("No image").font(.caption).foregroundStyle(.secondary)
                }
            }
    }

    private var selectedBadge: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill").font(.subheadline)
            Text("DEFAULT").font(.caption2.weight(.bold)).tracking(0.5)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Capsule().fill(Color.green))
        .shadow(color: .black.opacity(0.2), radius: 4, y: 2)
        .padding(12)
    }

    private var ticketInfoSection: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ticket.name)
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                HStack(spacing: 6) {
                    Image(systemName: "calendar").font(.caption2)
                    Text("Added \(ticket.createdAt, style: .date)").font(.caption)
                }
                .foregroundStyle(.secondary)
            }
            Spacer()
            Image(systemName: "chevron.right").font(.caption).foregroundStyle(.tertiary)
        }
        .padding(20)
    }

    private var cardBackground: some View {
        let fillColor: Color = colorScheme == .dark ? Color(.secondarySystemBackground) : .white
        return RoundedRectangle(cornerRadius: 20).fill(fillColor)
    }

    private var cardBorder: some View {
        let strokeColor: Color = isSelected
            ? Color.green.opacity(0.3)
            : (colorScheme == .dark ? Color.white.opacity(0.1) : Color.clear)
        let lineWidth: CGFloat = isSelected ? 2 : 1
        return RoundedRectangle(cornerRadius: 20).stroke(strokeColor, lineWidth: lineWidth)
    }

    private var shadowColor: Color {
        colorScheme == .dark ? .clear : .black.opacity(0.08)
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
        scrollContent
            .background(detailBackgroundColor)
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

    private var scrollContent: some View {
        ScrollView {
            VStack(spacing: 32) {
                cardPreviewSection
                actionsSection
                ticketInfoSection
            }.padding(.bottom, 20)
        }
    }

    private var detailBackgroundColor: Color {
        colorScheme == .dark ? Color(.systemBackground) : Color(.systemGroupedBackground)
    }

    private var cardPreviewSection: some View {
        VStack(spacing: 16) {
            FlipCardView(ticket: ticket, isFlipped: $isFlipped).onTapGesture {
                Haptics.impact(.light)
                withAnimation(.spring(response: 0.6, dampingFraction: 0.8)) { isFlipped.toggle() }
            }

            HStack(spacing: 8) {
                Image(systemName: "hand.tap.fill").font(.caption2)
                Text("Tap to flip • \(isFlipped ? "Back" : "Front") side").font(.caption)
            }.foregroundStyle(.secondary)
        }.padding(.top, 20)
    }

    private var actionsSection: some View {
        VStack(spacing: 16) {
            fullscreenButton
            setDefaultButton
            deleteButton
        }.padding(.horizontal, 20)
    }

    private var fullscreenButton: some View {
        Button(action: {
            Haptics.impact(.light)
            showFullscreen = true
        }) {
            Label("View Fullscreen", systemImage: "arrow.up.left.and.arrow.down.right")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }.buttonStyle(.bordered).tint(.green)
    }

    private var setDefaultButton: some View {
        let isDefault = settingsManager.appSettings.selectedTicketId == ticket.id
        return Button(action: {
            Haptics.selection()
            setAsDefault()
        }) {
            Label(
                isDefault ? "Default Ticket" : "Set as Default",
                systemImage: isDefault ? "checkmark.circle.fill" : "circle"
            )
            .font(.subheadline.weight(.semibold))
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
        }.buttonStyle(.bordered).tint(.blue).disabled(isDefault)
    }

    private var deleteButton: some View {
        Button(role: .destructive, action: {
            Haptics.selection()
            showDeleteConfirm = true
        }) {
            Label("Delete Ticket", systemImage: "trash")
                .font(.subheadline.weight(.semibold))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 16)
        }.buttonStyle(.bordered)
    }

    private var ticketInfoSection: some View {
        let infoBackgroundColor = colorScheme == .dark ? Color(.secondarySystemBackground) : Color(.systemGray6)
        return VStack(alignment: .leading, spacing: 12) {
            InfoRow(
                icon: "calendar", label: "Added", value: ticket.createdAt.formatted(date: .long, time: .omitted)
            )
            InfoRow(
                icon: "qrcode", label: "Front Image",
                value: ticket.frontImageData != nil ? "Available" : "Not set"
            )
            InfoRow(
                icon: "qrcode", label: "Back Image",
                value: ticket.backImageData != nil ? "Available" : "Not set"
            )
        }
        .padding(20)
        .background(RoundedRectangle(cornerRadius: 16).fill(infoBackgroundColor))
        .padding(.horizontal, 20)
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
        if settings.selectedTicketId == ticket.id { settings.selectedTicketId = settings.ticketCards.first?.id }
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
            Image(systemName: icon).font(.body).foregroundStyle(.green).frame(width: 24)

            Text(label).font(.subheadline).foregroundStyle(.secondary)

            Spacer()

            Text(value).font(.subheadline.weight(.medium)).foregroundStyle(.primary)
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
                .degrees(isFlipped ? 180 : 0), axis: (x: 0, y: 1, z: 0)
            )
            CardFaceView(imageData: ticket.backImageData).opacity(isFlipped ? 1 : 0).rotation3DEffect(
                .degrees(isFlipped ? 0 : -180), axis: (x: 0, y: 1, z: 0)
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
            if let data = imageData, let uiImage = UIImage(data: data) {
                Image(uiImage: uiImage).resizable().aspectRatio(1.586, contentMode: .fill)
            } else {
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
                        Rectangle().fill(Color.gray.opacity(0.3)).aspectRatio(1.586, contentMode: .fit).overlay {
                            Image(systemName: "creditcard").font(.system(size: 60)).foregroundStyle(.secondary)
                        }
                    }
                }.rotationEffect(.degrees(90)).frame(width: geo.size.height, height: geo.size.width).scaleEffect(scale)
                    .offset(offset).position(x: geo.size.width / 2, y: geo.size.height / 2).gesture(
                        MagnificationGesture().onChanged { scale = lastScale * $0 }.onEnded { _ in
                            if scale < 1.0 {
                                withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) {
                                    scale = 1.0
                                    lastScale = 1.0
                                    offset = .zero
                                    lastOffset = .zero
                                }
                            } else {
                                lastScale = scale
                            }
                        }
                    ).simultaneousGesture(
                        DragGesture().onChanged {
                            offset = CGSize(
                                width: lastOffset.width + $0.translation.width,
                                height: lastOffset.height + $0.translation.height
                            )
                        }.onEnded { _ in lastOffset = offset }
                    ).onTapGesture {
                        withAnimation(.spring(response: 0.4, dampingFraction: 0.8)) { isFlipped.toggle() }
                    }
                VStack {
                    HStack {
                        Spacer()
                        Button {
                            dismiss()
                        } label: {
                            Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.8))
                                .padding()
                        }
                    }
                    Spacer()
                    Text("Tap to flip · Pinch to zoom").font(.caption).foregroundStyle(.white.opacity(0.6)).padding(
                        .bottom, 20
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
            if !settingsManager.appSettings.ticketCards.isEmpty {
                Image(systemName: "wallet.pass.fill")
            } else {
                ZStack {
                    Image(systemName: "wallet.pass")
                    Image(systemName: "plus.circle.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(
                        .white, .green
                    ).offset(x: -4, y: 4)
                }
            }
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

    init(onTicketAdded: ((String) -> Void)? = nil) { self.onTicketAdded = onTicketAdded }

    enum CardSide { case front, back }

    var body: some View {
        NavigationStack {
            scannerContent
                .background(backgroundStyle)
                .navigationTitle("Add Ticket")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar { toolbarContent }
                .fullScreenCover(isPresented: $showCamera) { cameraSheet }
                .photosPicker(isPresented: $showPhotoPicker, selection: $selectedItem, matching: .images)
                .onChange(of: selectedItem) { _, newItem in handlePhotoSelection(newItem) }
        }
    }

    // MARK: - Extracted Views

    private var backgroundStyle: Color {
        colorScheme == .dark ? Color(.systemBackground) : Color(.systemGroupedBackground)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        ToolbarItem(placement: .cancellationAction) {
            Button("Cancel") { dismiss() }
        }
    }

    private var cameraSheet: some View {
        CameraCaptureView { image in
            if currentSide == .front { frontImage = image } else { backImage = image }
        }
    }

    private var scannerContent: some View {
        ScrollView {
            VStack(spacing: 28) {
                warningBanner
                ticketNameInput
                frontImageSection
                swapButton
                backImageSection
                saveButton
            }
            .padding(.vertical, 24)
        }
    }

    @ViewBuilder
    private var warningBanner: some View {
        if showWarning {
            HStack(spacing: 12) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                Text("No validation is performed. Ensure your ticket is configured correctly.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    withAnimation(.spring(response: 0.3, dampingFraction: 0.7)) { showWarning = false }
                } label: {
                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 12).fill(Color.orange.opacity(0.1)))
            .overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.orange.opacity(0.3), lineWidth: 1))
            .padding(.horizontal, 20)
        }
    }

    private var ticketNameInput: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Ticket Name", systemImage: "tag.fill")
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(.secondary)

            let inputBackground: Color = colorScheme == .dark ? Color(.secondarySystemBackground) : Color(.systemGray6)
            TextField("e.g., Monthly Pass, Student Card", text: $ticketName)
                .textFieldStyle(.plain)
                .font(.body)
                .padding(16)
                .background(RoundedRectangle(cornerRadius: 12).fill(inputBackground))
        }
        .padding(.horizontal, 20)
    }

    private var frontImageSection: some View {
        VStack(spacing: 16) {
            Label("Front of Card", systemImage: "creditcard.fill").font(.headline)
            ModernCardScanButton(image: frontImage, side: "Front") {
                currentSide = .front
                showFrontSourcePicker = true
            }
            .confirmationDialog("Select Image Source", isPresented: $showFrontSourcePicker, titleVisibility: .visible) {
                imageSourceButtons
            }
        }
    }

    @ViewBuilder
    private var swapButton: some View {
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
    }

    private var backImageSection: some View {
        VStack(spacing: 16) {
            Label("Back of Card", systemImage: "creditcard").font(.headline)
            ModernCardScanButton(image: backImage, side: "Back") {
                currentSide = .back
                showBackSourcePicker = true
            }
            .confirmationDialog("Select Image Source", isPresented: $showBackSourcePicker, titleVisibility: .visible) {
                imageSourceButtons
            }
        }
    }

    @ViewBuilder
    private var imageSourceButtons: some View {
        Button { showCamera = true } label: {
            Label("Take Photo", systemImage: "camera")
        }
        Button { showPhotoPicker = true } label: {
            Label("Choose from Library", systemImage: "photo.on.rectangle")
        }
        Button("Cancel", role: .cancel) {}
    }

    private var saveButton: some View {
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

    private func handlePhotoSelection(_ newItem: PhotosPickerItem?) {
        Task {
            if let data = try? await newItem?.loadTransferable(type: Data.self),
               let image = UIImage(data: data)
            {
                if currentSide == .front { frontImage = image } else { backImage = image }
            }
            selectedItem = nil
        }
    }

    private func saveTicket() {
        // Use PNG for lossless quality - critical for QR code scanning
        let ticket = TicketCard(
            name: ticketName, frontImageData: frontImage?.pngData(), backImageData: backImage?.pngData()
        )
        var settings = settingsManager.appSettings
        settings.ticketCards.append(ticket)
        if settings.selectedTicketId == nil { settings.selectedTicketId = ticket.id }
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
                Image(uiImage: image).resizable().aspectRatio(1.586, contentMode: .fill).frame(height: 240).clipShape(
                    RoundedRectangle(cornerRadius: 16)
                ).overlay(RoundedRectangle(cornerRadius: 16).stroke(Color.green, lineWidth: 3)).shadow(
                    color: .black.opacity(0.1), radius: 12, y: 6
                )
            } else {
                RoundedRectangle(cornerRadius: 16).strokeBorder(style: StrokeStyle(lineWidth: 3, dash: [12]))
                    .foregroundStyle(Color.accentColor.opacity(0.5)).aspectRatio(1.586, contentMode: .fill).frame(
                        height: 240
                    ).overlay {
                        VStack(spacing: 16) {
                            ZStack {
                                Circle().fill(Color.accentColor.opacity(colorScheme == .dark ? 0.2 : 0.1)).frame(
                                    width: 80, height: 80
                                )
                                Image(systemName: "camera.fill").font(.title).foregroundStyle(Color.accentColor)
                            }
                            VStack(spacing: 4) {
                                Text("Tap to scan \(side)").font(.subheadline.weight(.semibold))
                                Text("or choose from library").font(.caption).foregroundStyle(.secondary)
                            }
                        }.foregroundStyle(Color.accentColor)
                    }
            }
        }.buttonStyle(.plain).padding(.horizontal, 20)
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
                Image(uiImage: image).resizable().aspectRatio(1.586, contentMode: .fill).frame(height: 200).clipShape(
                    RoundedRectangle(cornerRadius: 12)
                ).overlay(RoundedRectangle(cornerRadius: 12).stroke(Color.accentColor, lineWidth: 2))
            } else {
                RoundedRectangle(cornerRadius: 12).strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [8]))
                    .foregroundStyle(.secondary).aspectRatio(1.586, contentMode: .fill).frame(height: 200).overlay {
                        VStack(spacing: 8) {
                            Image(systemName: "camera.fill").font(.title)
                            Text("Tap to scan \(side)").font(.subheadline)
                        }.foregroundStyle(.secondary)
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
    @State private var capturedImage: UIImage?
    @State private var cardWasDetected = false

    var body: some View {
        ZStack {
            if let image = capturedImage {
                previewView(image: image)
            } else {
                cameraView
            }
        }.onAppear { camera.start() }.onDisappear { camera.stop() }
    }

    private var cameraView: some View {
        ZStack {
            // Camera preview container - ensures frozen frame matches live preview exactly
            GeometryReader { geo in
                ZStack {
                    if camera.isProcessing, let frozenImage = camera.frozenPreviewImage {
                        Image(uiImage: frozenImage)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: geo.size.width, height: geo.size.height)
                            .clipped()
                    } else {
                        CameraPreviewLayer(session: camera.session)
                    }
                }
            }
            .ignoresSafeArea()

            GeometryReader { geo in
                let cardWidth = max(0, geo.size.width - 40)
                let cardHeight = max(0, cardWidth / 1.586)

                CardVignetteOverlay(cardWidth: cardWidth, cardHeight: cardHeight).fill(Color.black.opacity(0.6))
                    .ignoresSafeArea()
                RoundedRectangle(cornerRadius: 12)
                    .stroke(
                        camera.isProcessing ? .blue : (camera.status == .detected ? .green : .white),
                        lineWidth: 3
                    )
                    .frame(width: cardWidth, height: cardHeight)
                    .position(x: geo.size.width / 2, y: geo.size.height / 2)
            }

            // Processing indicator overlay
            if camera.isProcessing {
                processingOverlay
            }

            VStack {
                HStack {
                    Button {
                        dismiss()
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.8))
                            .padding()
                    }
                    Spacer()
                    Button {
                        camera.toggleTorch()
                    } label: {
                        Image(systemName: camera.torchEnabled ? "flashlight.on.fill" : "flashlight.off.fill").font(
                            .title2
                        ).foregroundStyle(camera.torchEnabled ? .yellow : .white.opacity(0.8)).padding()
                    }
                }.opacity(camera.isProcessing ? 0.3 : 1)
                Spacer()
                if camera.isProcessing {
                    Text("Processing image...")
                        .font(.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(Color.blue.opacity(0.8), in: Capsule())
                } else {
                    Text(camera.status == .detected ? "Card detected" : "Position card within frame")
                        .font(.headline)
                        .foregroundStyle(camera.status == .detected ? .white : .white)
                        .padding(.horizontal, 16)
                        .padding(.vertical, 8)
                        .background(
                            (camera.status == .detected ? Color.green : Color.white).opacity(0.8),
                            in: Capsule()
                        )
                }
                Button {
                    guard !camera.isProcessing else { return }
                    let wasDetected = camera.status == .detected
                    camera.capturePhoto { image in
                        guard let image else {
                            dismiss()
                            return
                        }
                        cardWasDetected = wasDetected
                        withAnimation(.easeInOut(duration: 0.2)) { capturedImage = image }
                    }
                } label: {
                    ZStack {
                        Circle().fill(camera.status == .detected ? .green : .white).frame(width: 70, height: 70)
                        Circle().stroke(Color.white.opacity(0.3), lineWidth: 4).frame(width: 80, height: 80)
                        if camera.isProcessing {
                            ProgressView().tint(.gray)
                        } else if camera.status == .detected {
                            Image(systemName: "checkmark").font(.title.bold()).foregroundStyle(.white)
                        }
                    }
                }.disabled(camera.isProcessing).padding(.top, 16).opacity(camera.isProcessing ? 0.5 : 1)
                Spacer().frame(height: 40)
            }
        }
    }

    private var processingOverlay: some View {
        VStack(spacing: 12) {
            ProgressView()
                .scaleEffect(1.2)
                .tint(.white)
            Text("Detecting card edges...")
                .font(.caption.weight(.medium))
                .foregroundStyle(.white.opacity(0.9))
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
    }

    private func previewView(image: UIImage) -> some View {
        ZStack {
            Color.black.ignoresSafeArea()

            VStack(spacing: 0) {
                HStack {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { capturedImage = nil }
                    } label: {
                        Image(systemName: "xmark.circle.fill").font(.title).foregroundStyle(.white.opacity(0.8))
                            .padding()
                    }
                    Spacer()
                }

                Spacer()

                Image(uiImage: image).resizable().aspectRatio(contentMode: .fit).clipShape(
                    RoundedRectangle(cornerRadius: 16)
                ).padding(.horizontal, 20)

                Spacer()

                if !cardWasDetected {
                    HStack(spacing: 8) {
                        Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                        Text("Card not auto-detected. Image may need manual cropping.").font(.subheadline)
                    }.foregroundStyle(.white).padding(.horizontal, 20).padding(.vertical, 12).background(
                        Color.orange.opacity(0.2), in: RoundedRectangle(cornerRadius: 12)
                    ).padding(.horizontal, 20).padding(.bottom, 16)
                }

                HStack(spacing: 20) {
                    Button {
                        withAnimation(.easeInOut(duration: 0.2)) { capturedImage = nil }
                    } label: {
                        Label("Retake", systemImage: "arrow.counterclockwise").font(.headline).frame(
                            maxWidth: .infinity
                        ).padding(.vertical, 16)
                    }.buttonStyle(.bordered).tint(.white)

                    Button {
                        onCapture(image)
                        dismiss()
                    } label: {
                        Label("Use Photo", systemImage: "checkmark").font(.headline).frame(maxWidth: .infinity).padding(
                            .vertical, 16
                        )
                    }.buttonStyle(.borderedProminent).tint(.green)
                }.padding(.horizontal, 20).padding(.bottom, 40)
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
                x: (rect.width - cardWidth) / 2, y: (rect.height - cardHeight) / 2, width: cardWidth, height: cardHeight
            ), cornerSize: CGSize(width: 12, height: 12)
        )
        return path
    }
}

// MARK: - CameraPreviewLayer

struct CameraPreviewLayer: UIViewRepresentable {
    let session: AVCaptureSession
    func makeUIView(context: Context) -> UIView {
        let view = UIView()
        let layer = AVCaptureVideoPreviewLayer(session: session)
        layer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(layer)
        DispatchQueue.main.async { layer.frame = view.bounds }
        context.coordinator.layer = layer
        return view
    }

    func updateUIView(_ uiView: UIView, context: Context) { context.coordinator.layer?.frame = uiView.bounds }
    func makeCoordinator() -> Coordinator { Coordinator() }
    class Coordinator { var layer: AVCaptureVideoPreviewLayer? }
}
