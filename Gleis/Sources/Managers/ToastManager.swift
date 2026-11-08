import Foundation
import SwiftUI

@MainActor
@Observable
final class ToastManager {
    struct Toast: Equatable {
        let message: String
        let type: ToastView.ToastType
        let id = UUID()

        static func == (lhs: Toast, rhs: Toast) -> Bool { lhs.id == rhs.id }
    }

    private(set) var currentToast: Toast?
    private var dismissTask: Task<Void, Never>?

    func show(_ message: String, type: ToastView.ToastType, duration: TimeInterval = 2.5) {
        dismissTask?.cancel()
        currentToast = Toast(message: message, type: type)
        dismissTask = Task {
            try? await Task.sleep(nanoseconds: UInt64(duration * 1_000_000_000))
            guard !Task.isCancelled else { return }
            currentToast = nil
        }
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        currentToast = nil
    }
}

// MARK: - ToastOverlay ViewModifier

struct ToastOverlay: ViewModifier {
    let toast: ToastManager.Toast?
    var edge: Edge = .bottom
    var onDismiss: (() -> Void)? = nil

    private static let dismissDistance: CGFloat = 30

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var dragOffset: CGFloat = 0

    func body(content: Content) -> some View {
        content.overlay(alignment: edge == .bottom ? .bottom : .top) {
            if let toast {
                ToastView(message: toast.message, type: toast.type)
                    .offset(y: dragOffset)
                    .gesture(swipeToDismiss)
                    .accessibilityAction(named: "Dismiss") { onDismiss?() }
                    // A new id per toast, so a replacement transitions in instead of mutating the old one.
                    .id(toast.id)
                    .transition(reduceMotion ? .opacity : .move(edge: edge).combined(with: .opacity))
                    .padding(.horizontal, 16)
                    .padding(edge == .bottom ? .bottom : .top, edge == .bottom ? 20 : 60)
            }
        }
        .animation(reduceMotion ? .easeInOut(duration: 0.2) : .spring(response: 0.3, dampingFraction: 1), value: toast)
        .onChange(of: toast) { _, _ in dragOffset = 0 }
    }

    /// Follows the finger toward the edge the toast came from and dismisses past a short distance.
    private var swipeToDismiss: some Gesture {
        DragGesture(minimumDistance: 8)
            .onChanged { value in
                let towardEdge = edge == .bottom ? max(0, value.translation.height) : min(0, value.translation.height)
                dragOffset = towardEdge
            }
            .onEnded { value in
                let distance = edge == .bottom ? value.translation.height : -value.translation.height
                if distance > Self.dismissDistance, let onDismiss {
                    onDismiss()
                } else {
                    withAnimation(.gleisToggle) { dragOffset = 0 }
                }
            }
    }
}

extension View {
    func toastOverlay(_ manager: ToastManager, edge: Edge = .bottom) -> some View {
        modifier(ToastOverlay(toast: manager.currentToast, edge: edge, onDismiss: { manager.dismiss() }))
    }
}
