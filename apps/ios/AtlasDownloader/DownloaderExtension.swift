#if canImport(BackgroundAssets)
import BackgroundAssets
import Foundation

/// Release builds should add Xcode's Managed Background Assets downloader
/// extension target and use this type as its entry. Debug loads the bundled
/// preview SQLite instead.
struct AtlasDownloaderExtension: StoreDownloaderExtension {
    func shouldDownload(_: AssetPack) -> Bool {
        true
    }
}
#endif
