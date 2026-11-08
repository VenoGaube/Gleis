import Foundation

/// Runs submitted async work one item at a time, in submission order.
///
/// An `actor` alone is not enough for this: actors are reentrant, so a second call
/// can interleave with the first at any `await`. Work that must not overlap — such
/// as "cancel every notification, then reschedule from scratch" — needs the calls
/// chained explicitly, which is what this does.
actor SerialQueue {
    private var tail: Task<Void, Never>?

    /// Suspends until all previously submitted work has finished and then this has run.
    func run(_ operation: @escaping @Sendable () async -> Void) async {
        let previous = tail
        let task = Task {
            await previous?.value
            await operation()
        }
        tail = task
        await task.value
    }
}
