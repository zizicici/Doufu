//
//  ActiveTaskManager.swift
//  Doufu
//

import UIKit

/// Manages system-level side effects tied to the lifecycle of active LLM tasks.
/// Supports multiple concurrent sessions via `sessionID`.
@MainActor
final class ActiveTaskManager {

    static let shared = ActiveTaskManager()

    private var activeSessions: Set<String> = []

    var isRunning: Bool { !activeSessions.isEmpty }

    private init() {}

    func taskDidStart(sessionID: String) {
        activeSessions.insert(sessionID)
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func taskDidEnd(sessionID: String) {
        activeSessions.remove(sessionID)
        if activeSessions.isEmpty {
            UIApplication.shared.isIdleTimerDisabled = false
        }
    }

    // MARK: - Legacy (no sessionID)

    func taskDidStart() {
        taskDidStart(sessionID: "_legacy")
    }

    func taskDidEnd() {
        taskDidEnd(sessionID: "_legacy")
    }
}
