import Foundation
import SwiftUI

@Observable
@MainActor
final class AtlasRouter {
    var selectedSection: AppSection = .atlas
    var atlasPath: [AppDestination] = []
    var libraryPath: [AppDestination] = []
    var savedPath: [AppDestination] = []
    var infoPath: [AppDestination] = []

    func path(for section: AppSection) -> [AppDestination] {
        switch section {
        case .atlas: atlasPath
        case .library: libraryPath
        case .saved: savedPath
        case .info: infoPath
        }
    }

    func setPath(_ path: [AppDestination], for section: AppSection) {
        switch section {
        case .atlas: atlasPath = path
        case .library: libraryPath = path
        case .saved: savedPath = path
        case .info: infoPath = path
        }
    }

    func open(_ destination: AppDestination, in section: AppSection) {
        if selectedSection != section {
            selectedSection = section
        }
        var path = path(for: section)
        path.append(destination)
        setPath(path, for: section)
    }

    func pop(in section: AppSection) {
        var path = path(for: section)
        guard !path.isEmpty else { return }
        path.removeLast()
        setPath(path, for: section)
    }

    func pathBinding(_ section: AppSection) -> Binding<[AppDestination]> {
        Binding(
            get: { self.path(for: section) },
            set: { self.setPath($0, for: section) }
        )
    }
}
