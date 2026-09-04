import Foundation

protocol Clock: Sendable {
    func now() -> Date
}

struct SystemClock: Clock {
    func now() -> Date { Date() }
}

struct FixedClock: Clock {
    var date: Date
    func now() -> Date { date }
}

protocol IdentifierSource: Sendable {
    func makeID() -> String
}

struct UUIDIdentifierSource: IdentifierSource {
    func makeID() -> String { UUID().uuidString }
}

protocol ModelAvailabilityProviding: Sendable {
    var current: FoundationModelAvailability { get }
}

struct SystemModelAvailability: ModelAvailabilityProviding {
    var current: FoundationModelAvailability { FoundationModelAvailability.current }
}

struct FixedModelAvailability: ModelAvailabilityProviding {
    var current: FoundationModelAvailability
}

protocol ModelPlanning: Sendable {
    func plan(prompt: String) async -> AtlasQueryPlan
}

struct DeterministicModelPlanner: ModelPlanning {
    func plan(prompt: String) async -> AtlasQueryPlan {
        AtlasQueryPlan(prompt: prompt)
    }
}

struct FixedModelPlanner: ModelPlanning {
    var plan: AtlasQueryPlan

    func plan(prompt: String) async -> AtlasQueryPlan {
        plan
    }
}

final class NetworkActivityRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [String] = []

    func record(_ label: String) {
        lock.lock()
        events.append(label)
        lock.unlock()
    }

    var requestCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return events.count
    }

    var recordedEvents: [String] {
        lock.lock()
        defer { lock.unlock() }
        return events
    }
}

struct AppServices {
    var clock: any Clock
    var identifiers: any IdentifierSource
    var network: NetworkActivityRecorder
    var modelAvailability: any ModelAvailabilityProviding
    var planner: any ModelPlanning
    var savedDirectory: URL
    var userDefaults: UserDefaults
    var catalog: (any NMSCatalog)?
    var packIdentity: PackIdentity?

    static var live: AppServices {
        let support = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!.appendingPathComponent("Atlas", isDirectory: true)
        return AppServices(
            clock: SystemClock(),
            identifiers: UUIDIdentifierSource(),
            network: NetworkActivityRecorder(),
            modelAvailability: SystemModelAvailability(),
            planner: DeterministicModelPlanner(),
            savedDirectory: support.appendingPathComponent("SavedArtifacts", isDirectory: true),
            userDefaults: .standard,
            catalog: nil,
            packIdentity: nil
        )
    }

    static func isolated(
        root: URL,
        defaults: UserDefaults,
        clock: any Clock = SystemClock(),
        modelAvailability: FoundationModelAvailability = .unavailable,
        planner: (any ModelPlanning)? = nil,
        catalog: (any NMSCatalog)? = nil,
        packIdentity: PackIdentity? = nil
    ) -> AppServices {
        AppServices(
            clock: clock,
            identifiers: UUIDIdentifierSource(),
            network: NetworkActivityRecorder(),
            modelAvailability: FixedModelAvailability(current: modelAvailability),
            planner: planner ?? DeterministicModelPlanner(),
            savedDirectory: root.appendingPathComponent("SavedArtifacts", isDirectory: true),
            userDefaults: defaults,
            catalog: catalog,
            packIdentity: packIdentity
        )
    }
}
