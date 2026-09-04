import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.packStatus {
        case .locating:
            PreparingAtlasView(message: "Preparing Atlas…")
        case .downloading(let progress):
            PreparingAtlasView(
                message: "Downloading Atlas for offline use…",
                detail: "The full reference database stays on this device.",
                progress: progress
            )
        case .verifying:
            PreparingAtlasView(
                message: "Verifying Atlas…",
                detail: "Checking the database before it becomes active."
            )
        case .activating:
            PreparingAtlasView(message: "Finishing the offline database…")
        case .missing(let detail):
            PreparingAtlasView(
                message: "Atlas data is not on this device yet.",
                detail: detail,
                retry: {
                    Task { await model.bootstrap() }
                }
            )
        case .ready:
            AppShellView()
        }
    }
}

struct PreparingAtlasView: View {
    var message: String
    var detail: String?
    var progress: Double?
    var retry: (() -> Void)?

    init(
        message: String,
        detail: String? = nil,
        progress: Double? = nil,
        retry: (() -> Void)? = nil
    ) {
        self.message = message
        self.detail = detail
        self.progress = progress
        self.retry = retry
    }

    var body: some View {
        VStack(spacing: 16) {
            if let progress {
                ProgressView(value: progress)
                    .frame(maxWidth: 240)
            } else {
                ProgressView()
            }
            Text(message)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
            if let retry {
                Button("Try Again", action: retry)
                    .buttonStyle(.borderedProminent)
                    .frame(minWidth: 44, minHeight: 44)
            }
        }
        .padding()
    }
}
