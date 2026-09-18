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

    @Environment(\.packDirectory) private var environmentPackDirectory
    @Environment(AppModel.self) private var model

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

    private var packDirectory: URL? {
        model.packDirectory ?? environmentPackDirectory
    }

    private var loadedImage: UIImage? {
        guard let url = PackedIconLocator.fileURL(
            sourcePath: sourcePath,
            packDirectory: packDirectory
        ) else { return nil }
        // Prefer Data→UIImage so sealed bundle paths still decode on device.
        if let data = try? Data(contentsOf: url), let image = UIImage(data: data) {
            return image
        }
        return UIImage(contentsOfFile: url.path)
    }
}
