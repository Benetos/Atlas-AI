import Foundation

enum ExternalSourceKind: String, Equatable, Sendable, Hashable {
    case liveAtlas
    case web
}

struct SourcePolicySnapshot: Equatable, Sendable {
    var liveAtlasCapabilityEnabled: Bool
    var webSearchCapabilityEnabled: Bool
    var packAvailable: Bool

    init(
        liveAtlasCapabilityEnabled: Bool,
        webSearchCapabilityEnabled: Bool,
        packAvailable: Bool
    ) {
        self.liveAtlasCapabilityEnabled = liveAtlasCapabilityEnabled
        self.webSearchCapabilityEnabled = webSearchCapabilityEnabled
        self.packAvailable = packAvailable
    }

    init(settings: AppSettings, packAvailable: Bool) {
        self.init(
            liveAtlasCapabilityEnabled: settings.liveAtlasEnabled,
            webSearchCapabilityEnabled: settings.webSearchEnabled,
            packAvailable: packAvailable
        )
    }
}

struct ExternalConsentReceipt: Equatable, Sendable, Hashable {
    var id: String
    var source: ExternalSourceKind
    var normalizedOutboundQuery: String
    var originatingTurnID: String
    var issuedAt: Date
    var expiresAt: Date
    var consumed: Bool

    func authorizes(
        source: ExternalSourceKind,
        query: String,
        turnID: String,
        now: Date
    ) -> Bool {
        !consumed
            && self.source == source
            && normalizedOutboundQuery == query
            && originatingTurnID == turnID
            && now >= issuedAt
            && now <= expiresAt
    }

    mutating func consume() {
        consumed = true
    }
}

enum OutboundQuery: Sendable {
    static func derive(from plan: AtlasQueryPlan) throws -> String {
        try ConversationBounds.normalizeQuery(plan.externalQuery)
    }

    static func matchesUserDerived(_ proposed: String, plan: AtlasQueryPlan) -> Bool {
        let derived = (try? derive(from: plan)) ?? ""
        let incoming = ConversationBounds.collapsedWhitespace(proposed)
        return !derived.isEmpty && incoming == derived
    }
}

struct SourcePolicyDecision: Equatable, Sendable {
    var allowsLocal: Bool
    var liveCapabilityEnabled: Bool
    var webCapabilityEnabled: Bool
    var authorizesLive: Bool
    var authorizesWeb: Bool
    var requiresLiveConsent: Bool
    var requiresWebConsent: Bool
    var capabilityBundleID: String
    var outboundQuery: String?

    var requiresExternalConsent: Bool { requiresLiveConsent || requiresWebConsent }

    static func decide(
        plan: AtlasQueryPlan,
        snapshot: SourcePolicySnapshot,
        receipts: [ExternalConsentReceipt],
        turnID: String,
        now: Date
    ) -> SourcePolicyDecision {
        let outbound = try? OutboundQuery.derive(from: plan)
        let liveRequested = plan.requestsLive
        let webRequested = plan.requestsWeb
        let liveReceipt = receipts.first {
            $0.authorizes(source: .liveAtlas, query: outbound ?? "", turnID: turnID, now: now)
        }
        let webReceipt = receipts.first {
            $0.authorizes(source: .web, query: outbound ?? "", turnID: turnID, now: now)
        }

        // A global setting enables the capability. It never authorizes a request.
        let authorizesLive = liveRequested
            && snapshot.liveAtlasCapabilityEnabled
            && liveReceipt != nil
        let authorizesWeb = webRequested
            && snapshot.webSearchCapabilityEnabled
            && webReceipt != nil

        return SourcePolicyDecision(
            allowsLocal: snapshot.packAvailable,
            liveCapabilityEnabled: snapshot.liveAtlasCapabilityEnabled,
            webCapabilityEnabled: snapshot.webSearchCapabilityEnabled,
            authorizesLive: authorizesLive,
            authorizesWeb: authorizesWeb,
            requiresLiveConsent: liveRequested
                && snapshot.liveAtlasCapabilityEnabled
                && liveReceipt == nil,
            requiresWebConsent: webRequested
                && snapshot.webSearchCapabilityEnabled
                && webReceipt == nil,
            capabilityBundleID: bundleID(
                live: snapshot.liveAtlasCapabilityEnabled,
                web: snapshot.webSearchCapabilityEnabled
            ),
            outboundQuery: outbound
        )
    }

    static func bundleID(live: Bool, web: Bool) -> String {
        var parts = ["core"]
        if live { parts.append("live") }
        if web { parts.append("web") }
        return parts.joined(separator: "+")
    }
}

struct ExternalEvidenceInput: Equatable, Sendable {
    var liveEntities: [Entity]
    var webHits: [WebHit]
    var proposedOutboundQuery: String?

    static let empty = ExternalEvidenceInput(liveEntities: [], webHits: [], proposedOutboundQuery: nil)
}
