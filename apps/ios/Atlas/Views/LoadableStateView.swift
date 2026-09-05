import SwiftUI

struct LoadableStateView<Value, Content: View>: View {
    var state: LoadState<Value>
    var loadingTitle: String
    var notFoundTitle: String
    var notFoundSystemImage: String
    var failedTitle: String
    var onRefresh: (() -> Void)?
    var onDeleteReference: (() -> Void)?
    @ViewBuilder var content: (Value) -> Content

    @Environment(AtlasRouter.self) private var router

    var body: some View {
        switch state {
        case .idle, .loading:
            ProgressView(loadingTitle)
        case .loaded(let value):
            content(value)
        case .notFound:
            unavailable(
                title: notFoundTitle,
                systemImage: notFoundSystemImage,
                description: "This record is not in the active snapshot."
            )
        case .failed(let message):
            unavailable(
                title: failedTitle,
                systemImage: "exclamationmark.triangle",
                description: message
            )
        }
    }

    private func unavailable(title: String, systemImage: String, description: String) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: systemImage)
        } description: {
            Text(description)
        } actions: {
            Button("Back", action: { router.pop(in: router.selectedSection) })
            if let onRefresh {
                Button("Refresh", action: onRefresh)
            }
            if let onDeleteReference {
                Button("Delete Stale Reference", role: .destructive, action: onDeleteReference)
            }
        }
    }
}
