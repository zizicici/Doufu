//
//  SerialWriteQueue.swift
//  Doufu
//

import Foundation

/// A serial queue for async operations on the main actor.
/// Ensures enqueued blocks execute one at a time, in FIFO order,
/// preventing write races on shared resources like JSON files.
///
/// All callers (`ChatDataService`, etc.) are `@MainActor`, so using
/// `@MainActor` isolation here guarantees that `enqueue` appends happen
/// synchronously in call order — no Task-scheduling reorder possible.
@MainActor
final class SerialWriteQueue {

    private var pendingWork: [@Sendable () async -> Void] = []
    private var isRunning = false

    /// Enqueue a fire-and-forget async operation.
    /// The append happens synchronously on the main actor, so call
    /// order is preserved even when multiple `enqueue` calls happen
    /// before the queue starts draining.
    func enqueue(_ work: @escaping @Sendable () async -> Void) {
        pendingWork.append(work)
        if !isRunning {
            isRunning = true
            Task { await drainQueue() }
        }
    }

    /// Enqueue an async operation and wait for it to complete.
    /// Useful when the caller needs to ensure all prior writes have
    /// finished (e.g., before switching threads).
    func enqueueAndWait(_ work: @escaping @Sendable () async -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            enqueue {
                await work()
                continuation.resume()
            }
        }
    }

    private func drainQueue() async {
        while !pendingWork.isEmpty {
            let work = pendingWork.removeFirst()
            await work()
        }
        isRunning = false
    }
}
