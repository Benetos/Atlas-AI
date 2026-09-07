import Foundation

enum LoadState<Value: Sendable>: Sendable {
    case idle
    case loading
    case loaded(Value)
    case notFound
    case failed(String)

    var isLoading: Bool {
        if case .loading = self { return true }
        return false
    }
}
