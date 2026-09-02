import Foundation

@Observable
final class AppSettings {
    static let liveAtlasKey = "liveAtlasEnabled"
    static let webSearchKey = "webSearchEnabled"
    static let webSearchConfirmedKey = "webSearchConfirmed"

    var liveAtlasEnabled: Bool {
        didSet { UserDefaults.standard.set(liveAtlasEnabled, forKey: Self.liveAtlasKey) }
    }

    var webSearchEnabled: Bool {
        didSet { UserDefaults.standard.set(webSearchEnabled, forKey: Self.webSearchKey) }
    }

    var webSearchConfirmed: Bool {
        didSet { UserDefaults.standard.set(webSearchConfirmed, forKey: Self.webSearchConfirmedKey) }
    }

    init() {
        liveAtlasEnabled = UserDefaults.standard.bool(forKey: Self.liveAtlasKey)
        webSearchEnabled = UserDefaults.standard.bool(forKey: Self.webSearchKey)
        webSearchConfirmed = UserDefaults.standard.bool(forKey: Self.webSearchConfirmedKey)
    }

    var supabaseURL: URL? {
        let candidates = [
            Bundle.main.object(forInfoDictionaryKey: "SUPABASE_URL") as? String,
            ProcessInfo.processInfo.environment["SUPABASE_URL"],
            "https://amgezynqenbgopnnpxso.supabase.co",
        ]
        guard let value = candidates.compactMap({ candidate in
            candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
        }).first(where: { !$0.isEmpty }),
              let url = URL(string: value),
              url.scheme == "https",
              url.host != nil
        else { return nil }
        return url
    }

    var supabaseAnonKey: String {
        let candidates = [
            Bundle.main.object(forInfoDictionaryKey: "SUPABASE_ANON_KEY") as? String,
            ProcessInfo.processInfo.environment["SUPABASE_ANON_KEY"],
        ]
        return candidates.compactMap { candidate in
            candidate?.trimmingCharacters(in: .whitespacesAndNewlines)
        }.first(where: { !$0.isEmpty }) ?? ""
    }

    var liveAtlasConfigured: Bool {
        supabaseURL != nil && !supabaseAnonKey.isEmpty
    }
}
