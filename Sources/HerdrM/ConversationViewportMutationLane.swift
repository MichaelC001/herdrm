import Foundation

/// Source viewport acknowledgements must settle before later navigation.
/// Canceling a Swift task cannot undo a mutation already sent to the daemon.
@MainActor
final class ConversationViewportMutationLane {
    enum Kind { case snap, jump, live }
    private struct Operation {
        let kind: Kind
        let key: String
        let run: @MainActor () async -> Void
    }
    private var pending: [Operation] = []
    private var runner: Task<Void, Never>?
    var isRunning: Bool { runner != nil }
    var pendingCount: Int { pending.count }

    func submit(kind: Kind, key: String, operation: @escaping @MainActor () async -> Void) {
        let next = Operation(kind: kind, key: key, run: operation)
        // Only supersede work that has not been dispatched. Selection snaps
        // and return-to-live remain ordered barriers between jump requests.
        if let last = pending.last, last.kind == kind, last.key == key {
            pending[pending.count - 1] = next
        } else { pending.append(next) }
        if pending.count > 64 { pending.removeFirst(pending.count - 64) }
        guard runner == nil else { return }
        runner = Task { [weak self] in
            guard let self else { return }
            while !self.pending.isEmpty {
                let next = self.pending.removeFirst()
                await next.run()
            }
            self.runner = nil
        }
    }

    func discardPending() { pending.removeAll() }
}
