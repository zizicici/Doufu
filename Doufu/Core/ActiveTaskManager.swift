//
//  ActiveTaskManager.swift
//  Doufu
//

import UIKit

/// Manages system-level side effects tied to the lifecycle of an active LLM task,
/// independent of any specific UI (PiP, chat view, etc.).
@MainActor
final class ActiveTaskManager {

    static let shared = ActiveTaskManager()

    private(set) var isRunning = false

    private init() {}

    func taskDidStart() {
        isRunning = true
        UIApplication.shared.isIdleTimerDisabled = true
    }

    func taskDidEnd() {
        isRunning = false
        UIApplication.shared.isIdleTimerDisabled = false
    }
}
