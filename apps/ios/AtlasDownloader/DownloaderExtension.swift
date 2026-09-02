import BackgroundAssets
import ExtensionFoundation
import StoreKit

/// Apple-hosted Managed Background Assets downloader for the Atlas database pack.
@main
struct AtlasDownloaderExtension: StoreDownloaderExtension {
    func shouldDownload(_ assetPack: AssetPack) -> Bool {
        assetPack.id == "nms-reference"
    }
}
