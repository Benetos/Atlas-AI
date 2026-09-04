import SwiftUI

struct AppShellView: View {
    @Environment(AtlasRouter.self) private var router
    @Environment(\.horizontalSizeClass) private var sizeClass

    var body: some View {
        Group {
            if sizeClass == .regular {
                regularShell
            } else {
                compactShell
            }
        }
    }

    private var compactShell: some View {
        TabView(selection: tabSelectionBinding) {
            sectionStack(.atlas) { AtlasView() }
                .tabItem { Label(AppSection.atlas.title, systemImage: AppSection.atlas.systemImage) }
                .tag(AppSection.atlas)
            sectionStack(.library) { LibraryView() }
                .tabItem { Label(AppSection.library.title, systemImage: AppSection.library.systemImage) }
                .tag(AppSection.library)
            sectionStack(.saved) { SavedView() }
                .tabItem { Label(AppSection.saved.title, systemImage: AppSection.saved.systemImage) }
                .tag(AppSection.saved)
            sectionStack(.info) { InfoView() }
                .tabItem { Label(AppSection.info.title, systemImage: AppSection.info.systemImage) }
                .tag(AppSection.info)
        }
    }

    private var regularShell: some View {
        NavigationSplitView {
            List(selection: selectedSectionBinding) {
                ForEach(AppSection.allCases) { section in
                    Label(section.title, systemImage: section.systemImage)
                        .tag(section)
                }
            }
            .navigationTitle("Atlas")
        } content: {
            sectionRoot(router.selectedSection)
        } detail: {
            regularDetail(for: router.selectedSection)
        }
    }

    private var tabSelectionBinding: Binding<AppSection> {
        Binding(
            get: { router.selectedSection },
            set: { router.selectedSection = $0 }
        )
    }

    private var selectedSectionBinding: Binding<AppSection?> {
        Binding(
            get: { router.selectedSection },
            set: { newValue in
                if let newValue {
                    router.selectedSection = newValue
                }
            }
        )
    }

    private func sectionStack<Content: View>(
        _ section: AppSection,
        @ViewBuilder root: () -> Content
    ) -> some View {
        NavigationStack(path: router.pathBinding(section)) {
            root()
                .navigationDestination(for: AppDestination.self) { destination in
                    DestinationView(destination: destination)
                }
        }
    }

    @ViewBuilder
    private func sectionRoot(_ section: AppSection) -> some View {
        switch section {
        case .atlas: AtlasView()
        case .library: LibraryView()
        case .saved: SavedView()
        case .info: InfoView()
        }
    }

    @ViewBuilder
    private func regularDetail(for section: AppSection) -> some View {
        let path = router.path(for: section)
        if let first = path.first {
            NavigationStack(
                path: Binding(
                    get: { Array(router.path(for: section).dropFirst()) },
                    set: { newValue in
                        let current = router.path(for: section)
                        let root = current.first ?? first
                        router.setPath([root] + newValue, for: section)
                    }
                )
            ) {
                DestinationView(destination: first)
                    .navigationDestination(for: AppDestination.self) { destination in
                        DestinationView(destination: destination)
                    }
            }
        } else {
            ContentUnavailableView(
                "Select an item",
                systemImage: "square.stack",
                description: Text("Choose a result to open its specialist view.")
            )
        }
    }
}
