import SwiftUI

enum AppToastStyle: Equatable {
    case information
    case success
    case error

    var icon: String {
        switch self {
        case .information: "info.circle.fill"
        case .success: "checkmark.circle.fill"
        case .error: "exclamationmark.triangle.fill"
        }
    }

    var color: Color {
        switch self {
        case .information: .accentColor
        case .success: .green
        case .error: .red
        }
    }
}

struct AppToast: Identifiable, Equatable {
    let id: UUID
    var title: String
    var message: String?
    var style: AppToastStyle
    var showsActivity: Bool
    var isDismissible: Bool
}

struct ToastStackView: View {
    let toasts: [AppToast]
    let dismiss: (UUID) -> Void

    var body: some View {
        VStack(alignment: .trailing, spacing: 10) {
            ForEach(toasts) { toast in
                ToastView(toast: toast) { dismiss(toast.id) }
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
        }
        .frame(maxWidth: 380, alignment: .trailing)
        .animation(.snappy(duration: 0.25), value: toasts)
    }
}

private struct ToastView: View {
    let toast: AppToast
    let dismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Group {
                if toast.showsActivity {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: toast.style.icon)
                        .foregroundStyle(toast.style.color)
                }
            }
            .frame(width: 18, height: 20)

            VStack(alignment: .leading, spacing: 3) {
                Text(toast.title)
                    .font(.callout.weight(.semibold))
                    .lineLimit(2)
                if let message = toast.message, !message.isEmpty {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(3)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if toast.isDismissible {
                Button(action: dismiss) {
                    Image(systemName: "xmark")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 20, height: 20)
                }
                .buttonStyle(.plain)
                .help("Dismiss")
                .accessibilityLabel("Dismiss notification")
            }
        }
        .padding(14)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay(alignment: .leading) {
            RoundedRectangle(cornerRadius: 2)
                .fill(toast.style.color)
                .frame(width: 4)
                .padding(.vertical, 6)
        }
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator.opacity(0.45), lineWidth: 1)
        }
        .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        .accessibilityElement(children: .combine)
    }
}
