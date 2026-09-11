import SwiftUI
import UIKit

private struct PackDirectoryKey: EnvironmentKey {
    static let defaultValue: URL? = nil
}

extension EnvironmentValues {
    var packDirectory: URL? {
        get { self[PackDirectoryKey.self] }
        set { self[PackDirectoryKey.self] = newValue }
    }
}

struct PackedIcon: View {
    var sourcePath: String?
    var fallbackEntityType: String
    var colorR: String? = nil
    var colorG: String? = nil
    var colorB: String? = nil

    @Environment(\.packDirectory) private var packDirectory

    var body: some View {
        if let image = loadedImage {
            Image(uiImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: 44, height: 44)
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .accessibilityHidden(true)
        } else {
            PlaceholderIcon(
                entityType: fallbackEntityType,
                colorR: colorR,
                colorG: colorG,
                colorB: colorB
            )
        }
    }

    private var loadedImage: UIImage? {
        guard let url = PackedIconLocator.fileURL(
            sourcePath: sourcePath,
            packDirectory: packDirectory
        ) else { return nil }
        return UIImage(contentsOfFile: url.path)
    }
}
