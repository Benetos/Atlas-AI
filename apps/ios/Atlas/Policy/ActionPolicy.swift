import Foundation

struct GeneratedActionProposal: Equatable, Sendable, Hashable {
    var kind: String
    var payload: [String: String]

    static func open(_ key: RecordKey) -> GeneratedActionProposal {
        GeneratedActionProposal(kind: "open", payload: Self.payload(for: key))
    }

    static func plan(type: String, id: String, quantity: Int) -> GeneratedActionProposal {
        GeneratedActionProposal(
            kind: "plan",
            payload: ["record": "entity", "type": type, "id": id, "quantity": String(quantity)]
        )
    }

    static func save(_ key: RecordKey) -> GeneratedActionProposal {
        GeneratedActionProposal(kind: "save", payload: Self.payload(for: key))
    }

    static func requestExternal(from plan: AtlasQueryPlan) -> GeneratedActionProposal {
        GeneratedActionProposal(
            kind: "request-external-source",
            payload: [
                "source": plan.requestsLive ? ExternalSourceKind.liveAtlas.rawValue : ExternalSourceKind.web.rawValue,
                "query": plan.externalQuery,
            ]
        )
    }

    private static func payload(for key: RecordKey) -> [String: String] {
        switch key {
        case .entity(let type, let id):
            return ["record": "entity", "type": type, "id": id]
        case .recipe(let id):
            return ["record": "recipe", "id": id]
        case .content(let dataset, let id, let ordinal):
            return ["record": "content", "dataset": dataset, "id": id, "ordinal": String(ordinal)]
        case .web(let url):
            return ["record": "web", "url": url]
        case .derived(let id):
            return ["record": "derived", "id": id]
        }
    }
}

enum AtlasAction: Equatable, Sendable, Hashable {
    case open(AppDestination)
    case filter(AppDestination)
    case compare(keys: [RecordKey])
    case plan(type: String, id: String, quantity: Int)
    case guide(id: String)
    case configure(kind: String)
    case save(RecordKey)
    case export(artifactID: String)
    case requestExternalSource(ExternalSourceKind, query: String)

    var requiresConfirmation: Bool {
        switch self {
        case .open, .filter, .plan:
            return false
        case .compare, .guide, .configure, .save, .export, .requestExternalSource:
            return true
        }
    }

    var isWrite: Bool {
        switch self {
        case .save, .export, .configure, .guide:
            return true
        case .open, .filter, .compare, .plan, .requestExternalSource:
            return false
        }
    }
}

struct ResolvedAction: Equatable, Sendable, Hashable {
    var action: AtlasAction
    var evidenceIDs: [String]
    var evidenceDigest: String
    var packReleaseID: String
    var recordKeys: [RecordKey]
}

enum ActionPolicyVerdict: Equatable, Sendable {
    case allow
    case deny(String)
    case confirm
}

enum ActionResolutionError: Error, Equatable, LocalizedError, Sendable {
    case unknownKind(String)
    case missingIdentifier
    case unknownRecord
    case staleEvidence
    case quantityInvalid
    case injectedOutboundQuery
    case capabilityUnavailable
    case destinationForbidden

    var errorDescription: String? {
        switch self {
        case .unknownKind(let kind):
            return "Unknown action kind \(kind)."
        case .missingIdentifier:
            return "The action is missing a trusted record identifier."
        case .unknownRecord:
            return "The action referenced a record that is not in evidence."
        case .staleEvidence:
            return "The action referenced stale evidence."
        case .quantityInvalid:
            return "The action quantity is outside allowed bounds."
        case .injectedOutboundQuery:
            return "Outbound query is not derived from the user prompt."
        case .capabilityUnavailable:
            return "The requested capability is not in the current bundle."
        case .destinationForbidden:
            return "The action tried to open an untrusted destination."
        }
    }
}

struct ActionResolver: Sendable {
    func resolve(
        proposal: GeneratedActionProposal,
        ledger: EvidenceLedger,
        packReleaseID: String,
        queryPlan: AtlasQueryPlan,
        capabilityBundleID: String
    ) throws -> ResolvedAction {
        switch proposal.kind {
        case "open", "filter":
            let key = try recordKey(from: proposal.payload)
            try ensureKnown(key, ledger: ledger)
            guard let destination = key.destination else {
                throw ActionResolutionError.destinationForbidden
            }
            let action: AtlasAction = proposal.kind == "filter"
                ? .filter(destination)
                : .open(destination)
            return make(action, keys: [key], ledger: ledger, packReleaseID: packReleaseID)

        case "save":
            let key = try recordKey(from: proposal.payload)
            try ensureKnown(key, ledger: ledger)
            return make(.save(key), keys: [key], ledger: ledger, packReleaseID: packReleaseID)

        case "compare":
            let raw = proposal.payload["keys"] ?? ""
            let keys = raw.split(separator: ",").compactMap { parseKey(String($0)) }
            guard (2...4).contains(keys.count) else {
                throw ActionResolutionError.missingIdentifier
            }
            for key in keys { try ensureKnown(key, ledger: ledger) }
            return make(.compare(keys: keys), keys: keys, ledger: ledger, packReleaseID: packReleaseID)

        case "plan":
            let quantity = try Quantity.parse(proposal.payload["quantity"] ?? "1")
            if let type = proposal.payload["type"], let id = proposal.payload["id"], !type.isEmpty, !id.isEmpty {
                let key = RecordKey.entity(type: type, id: id)
                try ensureKnown(key, ledger: ledger)
                return make(
                    .plan(type: type, id: id, quantity: quantity),
                    keys: [key],
                    ledger: ledger,
                    packReleaseID: packReleaseID
                )
            }
            guard let recipeID = proposal.payload["recipeID"], !recipeID.isEmpty else {
                throw ActionResolutionError.missingIdentifier
            }
            let key = RecordKey.recipe(id: recipeID)
            try ensureKnown(key, ledger: ledger)
            let bundle = ledger.bundle(turnID: "lookup")
            guard let record = bundle.records.first(where: { $0.recordKey == key }),
                  case .recipe(let recipe) = record.payload
            else {
                throw ActionResolutionError.unknownRecord
            }
            return make(
                .plan(type: recipe.outputEntityType, id: recipe.outputGameID, quantity: quantity),
                keys: [key],
                ledger: ledger,
                packReleaseID: packReleaseID
            )

        case "guide":
            guard let id = proposal.payload["id"], !id.isEmpty else {
                throw ActionResolutionError.missingIdentifier
            }
            return make(.guide(id: id), keys: [], ledger: ledger, packReleaseID: packReleaseID)

        case "configure":
            guard let kind = proposal.payload["kind"], !kind.isEmpty else {
                throw ActionResolutionError.missingIdentifier
            }
            return make(.configure(kind: kind), keys: [], ledger: ledger, packReleaseID: packReleaseID)

        case "export":
            guard let artifactID = proposal.payload["artifactID"], !artifactID.isEmpty else {
                throw ActionResolutionError.missingIdentifier
            }
            return make(
                .export(artifactID: artifactID),
                keys: [],
                ledger: ledger,
                packReleaseID: packReleaseID
            )

        case "request-external-source":
            guard let source = ExternalSourceKind(rawValue: proposal.payload["source"] ?? "") else {
                throw ActionResolutionError.unknownKind(proposal.kind)
            }
            let query = proposal.payload["query"] ?? ""
            guard OutboundQuery.matchesUserDerived(query, plan: queryPlan) else {
                throw ActionResolutionError.injectedOutboundQuery
            }
            let liveAllowed = capabilityBundleID.contains("live")
            let webAllowed = capabilityBundleID.contains("web")
            if source == .liveAtlas && !liveAllowed {
                throw ActionResolutionError.capabilityUnavailable
            }
            if source == .web && !webAllowed {
                throw ActionResolutionError.capabilityUnavailable
            }
            return make(
                .requestExternalSource(source, query: query),
                keys: [],
                ledger: ledger,
                packReleaseID: packReleaseID
            )

        default:
            throw ActionResolutionError.unknownKind(proposal.kind)
        }
    }

    private func make(
        _ action: AtlasAction,
        keys: [RecordKey],
        ledger: EvidenceLedger,
        packReleaseID: String
    ) -> ResolvedAction {
        let bundle = ledger.bundle(turnID: "action")
        return ResolvedAction(
            action: action,
            evidenceIDs: bundle.evidenceIDs,
            evidenceDigest: bundle.digest,
            packReleaseID: packReleaseID,
            recordKeys: keys
        )
    }

    private func ensureKnown(_ key: RecordKey, ledger: EvidenceLedger) throws {
        let bundle = ledger.bundle(turnID: "lookup")
        guard bundle.records.contains(where: { $0.recordKey == key }) else {
            throw ActionResolutionError.unknownRecord
        }
    }

    private func recordKey(from payload: [String: String]) throws -> RecordKey {
        guard let parsed = parseKeyPayload(payload) else {
            throw ActionResolutionError.missingIdentifier
        }
        return parsed
    }

    private func parseKeyPayload(_ payload: [String: String]) -> RecordKey? {
        switch payload["record"] {
        case "entity":
            guard let type = payload["type"], let id = payload["id"] else { return nil }
            return .entity(type: type, id: id)
        case "recipe":
            guard let id = payload["id"] else { return nil }
            return .recipe(id: id)
        case "content":
            guard let dataset = payload["dataset"],
                  let id = payload["id"],
                  let ordinal = payload["ordinal"].flatMap(Int.init)
            else { return nil }
            return .content(dataset: dataset, id: id, sourceOrdinal: ordinal)
        default:
            return nil
        }
    }

    private func parseKey(_ raw: String) -> RecordKey? {
        let parts = raw.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard let kind = parts.first else { return nil }
        switch kind {
        case "entity" where parts.count >= 3:
            return .entity(type: parts[1], id: parts.dropFirst(2).joined(separator: ":"))
        case "recipe" where parts.count >= 2:
            return .recipe(id: parts.dropFirst().joined(separator: ":"))
        default:
            return nil
        }
    }
}

struct ActionPolicy: Sendable {
    func decide(_ resolved: ResolvedAction) -> ActionPolicyVerdict {
        if resolved.action.requiresConfirmation {
            return .confirm
        }
        return .allow
    }
}

struct PendingAction: Equatable, Sendable, Hashable, Identifiable {
    var id: String
    var resolved: ResolvedAction
    var originatingTurnID: String
    var evidenceIDs: [String]
    var evidenceDigest: String
    var packReleaseID: String
    var issuedAt: Date
    var expiresAt: Date
    var requiresConfirmation: Bool
    var nonce: String
    var consumed: Bool
    var declined: Bool
    var cancelled: Bool

    var exactEffectDescription: String {
        switch resolved.action {
        case .open(let destination):
            return "Open \(Self.label(destination))"
        case .filter(let destination):
            return "Filter \(Self.label(destination))"
        case .compare(let keys):
            return "Compare \(keys.map(\.canonical).joined(separator: ", "))"
        case .plan(let type, let id, let quantity):
            return "Plan \(quantity)× \(type) \(id)"
        case .guide(let id):
            return "Open guide \(id)"
        case .configure(let kind):
            return "Configure \(kind)"
        case .save(let key):
            return "Save \(key.canonical)"
        case .export(let artifactID):
            return "Export \(artifactID)"
        case .requestExternalSource(let source, let query):
            return "Request \(source.rawValue) for \(query)"
        }
    }

    private static func label(_ destination: AppDestination) -> String {
        switch destination {
        case .entity(let type, let id):
            return "\(type) \(id)"
        case .recipe(let id):
            return id
        case .content(let dataset, let id, _):
            return "\(dataset) \(id)"
        case .savedArtifact(let id):
            return id
        case .recipePlan(let type, let id, let quantity, _):
            return "\(quantity)× \(type) \(id)"
        case .unavailable(let unavailable):
            return unavailable.title
        }
    }
}

enum PendingActionExecutionError: Error, Equatable, LocalizedError, Sendable {
    case unknownNonce
    case expired
    case alreadyConsumed
    case declined
    case cancelled
    case packMismatch
    case digestMismatch
    case notConfirmed

    var errorDescription: String? {
        switch self {
        case .unknownNonce:
            return "This confirmation is no longer valid."
        case .expired:
            return "This confirmation expired."
        case .alreadyConsumed:
            return "This confirmation was already used."
        case .declined:
            return "This action was declined."
        case .cancelled:
            return "This action was cancelled."
        case .packMismatch:
            return "Refresh required. The installed pack changed."
        case .digestMismatch:
            return "The evidence for this action changed."
        case .notConfirmed:
            return "This action still requires confirmation."
        }
    }
}

actor PendingActionStore {
    private var actions: [String: PendingAction] = [:]

    func issue(_ action: PendingAction) {
        actions[action.nonce] = action
    }

    func pending(nonce: String) -> PendingAction? {
        actions[nonce]
    }

    func decline(nonce: String) throws {
        guard var action = actions[nonce] else { throw PendingActionExecutionError.unknownNonce }
        action.declined = true
        action.consumed = true
        actions[nonce] = action
    }

    func cancelAll() {
        for key in actions.keys {
            actions[key]?.cancelled = true
            actions[key]?.consumed = true
        }
    }

    func resetForPackChange() {
        actions.removeAll()
    }

    func confirmAndExecute(
        nonce: String,
        packReleaseID: String,
        evidenceDigest: String,
        now: Date
    ) throws -> AtlasAction {
        guard var action = actions[nonce] else {
            throw PendingActionExecutionError.unknownNonce
        }
        if action.cancelled { throw PendingActionExecutionError.cancelled }
        if action.declined { throw PendingActionExecutionError.declined }
        if action.consumed { throw PendingActionExecutionError.alreadyConsumed }
        if now > action.expiresAt { throw PendingActionExecutionError.expired }
        if action.packReleaseID != packReleaseID {
            throw PendingActionExecutionError.packMismatch
        }
        if action.evidenceDigest != evidenceDigest {
            throw PendingActionExecutionError.digestMismatch
        }
        if action.requiresConfirmation == false {
            // Immediate toolbar-style actions can execute without a second tap.
        }
        action.consumed = true
        actions[nonce] = action
        return action.resolved.action
    }
}

extension PendingAction {
    static func make(
        resolved: ResolvedAction,
        turnID: String,
        identifiers: any IdentifierSource,
        clock: any Clock,
        ttl: TimeInterval = ConversationBounds.pendingActionTTL
    ) -> PendingAction {
        let now = clock.now()
        let policy = ActionPolicy().decide(resolved)
        return PendingAction(
            id: identifiers.makeID(),
            resolved: resolved,
            originatingTurnID: turnID,
            evidenceIDs: resolved.evidenceIDs,
            evidenceDigest: resolved.evidenceDigest,
            packReleaseID: resolved.packReleaseID,
            issuedAt: now,
            expiresAt: now.addingTimeInterval(ttl),
            requiresConfirmation: policy == .confirm,
            nonce: identifiers.makeID(),
            consumed: false,
            declined: false,
            cancelled: false
        )
    }
}
