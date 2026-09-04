import Foundation

enum ConversationBoundError: Error, Equatable, LocalizedError, Sendable {
    case queryTooLong(Int)
    case tooManyDomainTools(Int)
    case tooManyToolCalls(Int)
    case searchLimitExceeded(Int)
    case detailPayloadTooLarge(Int)
    case quantityOutOfRange(Int)
    case quantityOverflow
    case recipeExpansionExceeded(String)

    var errorDescription: String? {
        switch self {
        case .queryTooLong(let count):
            return "Query length \(count) exceeds \(ConversationBounds.maxQueryUnicodeScalars) Unicode scalars."
        case .tooManyDomainTools(let count):
            return "Domain tool count \(count) exceeds \(ConversationBounds.maxDomainToolsPerTurn)."
        case .tooManyToolCalls(let count):
            return "Tool call count \(count) exceeds \(ConversationBounds.maxToolCallsPerTurn)."
        case .searchLimitExceeded(let count):
            return "Search limit \(count) exceeds \(ConversationBounds.maxSearchResults)."
        case .detailPayloadTooLarge(let count):
            return "Detail payload \(count) bytes exceeds \(ConversationBounds.maxDetailPayloadBytes)."
        case .quantityOutOfRange(let value):
            return "Quantity \(value) is outside \(ConversationBounds.minQuantity)...\(ConversationBounds.maxQuantity)."
        case .quantityOverflow:
            return "Quantity arithmetic overflowed the allowed range."
        case .recipeExpansionExceeded(let reason):
            return "Recipe expansion exceeded bounds: \(reason)."
        }
    }
}

enum ConversationBounds: Sendable {
    static let maxQueryUnicodeScalars = 256
    static let maxDomainToolsPerTurn = 4
    static let maxToolCallsPerTurn = 8
    static let maxSearchResults = 25
    static let maxDetailPayloadBytes = 16 * 1024
    static let minQuantity = 1
    static let maxQuantity = 999_999
    static let recipeExpansionDepth = 12
    static let recipeAlternativesPerNode = 5
    static let recipeMaxVisitedNodes = 500
    static let recipeCalculationBudgetMilliseconds = 750
    static let pendingActionTTL: TimeInterval = 5 * 60
    static let consentTTL: TimeInterval = 2 * 60
    static let maxRecentTurns = 8
    static let answerEntityLimit = 8
    static let answerRecipeLimit = 6
    static let answerContentLimit = 5

    static var quantityRange: ClosedRange<Int> { minQuantity...maxQuantity }

    static func collapsedWhitespace(_ value: String) -> String {
        value.components(separatedBy: .whitespacesAndNewlines)
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func normalizeQuery(_ raw: String) throws -> String {
        let collapsed = collapsedWhitespace(raw)
        let count = collapsed.unicodeScalars.count
        guard count <= maxQueryUnicodeScalars else {
            throw ConversationBoundError.queryTooLong(count)
        }
        return collapsed
    }

    static func clampSearchLimit(_ requested: Int?) throws -> Int {
        let value = requested ?? maxSearchResults
        guard value >= 0 else { throw ConversationBoundError.searchLimitExceeded(value) }
        guard value <= maxSearchResults else {
            throw ConversationBoundError.searchLimitExceeded(value)
        }
        return value
    }

    static func rejectOversizedDetail(_ payload: String) throws {
        let bytes = payload.utf8.count
        guard bytes <= maxDetailPayloadBytes else {
            throw ConversationBoundError.detailPayloadTooLarge(bytes)
        }
    }
}

enum Quantity: Sendable {
    static func checked(_ value: Int) throws -> Int {
        guard ConversationBounds.quantityRange.contains(value) else {
            throw ConversationBoundError.quantityOutOfRange(value)
        }
        return value
    }

    static func parse(_ raw: String) throws -> Int {
        guard let value = Int(raw.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ConversationBoundError.quantityOutOfRange(0)
        }
        return try checked(value)
    }

    static func product(_ lhs: Int, _ rhs: Int) throws -> Int {
        let a = try checked(lhs)
        let b = try checked(rhs)
        let (result, overflow) = a.multipliedReportingOverflow(by: b)
        guard !overflow else { throw ConversationBoundError.quantityOverflow }
        return try checked(result)
    }

    static func sum(_ lhs: Int, _ rhs: Int) throws -> Int {
        let a = try checked(lhs)
        let b = try checked(rhs)
        let (result, overflow) = a.addingReportingOverflow(b)
        guard !overflow else { throw ConversationBoundError.quantityOverflow }
        return try checked(result)
    }
}

struct RecipeExpansionBounds: Equatable, Sendable, Hashable, Codable {
    var depth: Int
    var alternativesPerNode: Int
    var maxVisitedNodes: Int
    var budgetMilliseconds: Int

    static let current = RecipeExpansionBounds(
        depth: ConversationBounds.recipeExpansionDepth,
        alternativesPerNode: ConversationBounds.recipeAlternativesPerNode,
        maxVisitedNodes: ConversationBounds.recipeMaxVisitedNodes,
        budgetMilliseconds: ConversationBounds.recipeCalculationBudgetMilliseconds
    )

    func rejectIfExceeded(depth visitedDepth: Int, nodes: Int, elapsedMilliseconds: Int) throws {
        if visitedDepth > depth {
            throw ConversationBoundError.recipeExpansionExceeded("depth \(visitedDepth)")
        }
        if nodes > maxVisitedNodes {
            throw ConversationBoundError.recipeExpansionExceeded("nodes \(nodes)")
        }
        if elapsedMilliseconds > budgetMilliseconds {
            throw ConversationBoundError.recipeExpansionExceeded("budget \(elapsedMilliseconds)ms")
        }
    }
}

struct GenerativeRoutingFlags: Equatable, Sendable {
    var modelProposedPlansEnabled: Bool
    var generatedActionsEnabled: Bool

    static let disabled = GenerativeRoutingFlags(
        modelProposedPlansEnabled: false,
        generatedActionsEnabled: false
    )

    static let enabled = GenerativeRoutingFlags(
        modelProposedPlansEnabled: true,
        generatedActionsEnabled: true
    )
}
