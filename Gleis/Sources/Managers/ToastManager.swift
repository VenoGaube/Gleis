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

}

// MARK: - ToastOverlay ViewModifier

struct ToastOverlay: ViewModifier {
    let toast: ToastManager.Toast?
    var edge: Edge = .bottom

    func body(content: Content) -> some View {
        content.overlay(alignment: edge == .bottom ? .bottom : .top) {
            if let toast {
                ToastView(message: toast.message, type: toast.type)
                    .transition(.move(edge: edge).combined(with: .opacity))
                    .padding(edge == .bottom ? .bottom : .top, edge == .bottom ? 20 : 60)
            }
        }
        .animation(.spring(response: 0.3), value: toast)
    }
}

extension View {
    func toastOverlay(_ manager: ToastManager, edge: Edge = .bottom) -> some View {
        modifier(ToastOverlay(toast: manager.currentToast, edge: edge))
    }
}
