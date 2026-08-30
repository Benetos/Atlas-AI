import SwiftUI

struct RootView: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        switch model.packStatus {
        case .locating:
            PreparingAtlasView(message: "Preparing Atlas…")
        case .missing(let detail):
            PreparingAtlasView(
                message: "Atlas data is not on this device yet.",
                detail: detail
            )
        case .ready:
            TabView {
                AtlasView()
                    .tabItem { Label("Atlas", systemImage: "sparkles") }
                LibraryView()
                    .tabItem { Label("Library", systemImage: "books.vertical") }
                SavedView()
                    .tabItem { Label("Saved", systemImage: "bookmark") }
                InfoView()
                    .tabItem { Label("Info", systemImage: "info.circle") }
            }
        }
    }
}

struct PreparingAtlasView: View {
    var message: String
    var detail: String?

    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text(message)
                .font(.headline)
            if let detail {
                Text(detail)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
            }
        }
        .padding()
    }
}
