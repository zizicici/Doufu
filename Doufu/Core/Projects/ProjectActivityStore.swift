//
//  ProjectActivityStore.swift
//  Doufu
//

import Foundation

@MainActor
final class ProjectActivityStore {

    static let shared = ProjectActivityStore()

    enum State: Equatable {
        case idle
        case building
        case newVersionAvailable
    }

    struct Change: Equatable {
        let projectID: String
        let state: State
    }

    private static let didChangeNotification = Notification.Name("ProjectActivityStore.didChange")
    private static let changeUserInfoKey = "change"

    private var states: [String: State] = [:]

    private init() {}

    func state(for projectID: String) -> State {
        states[projectID] ?? .idle
    }

    func addObserver(using handler: @escaping (Change) -> Void) -> NSObjectProtocol {
        let changeUserInfoKey = Self.changeUserInfoKey
        return NotificationCenter.default.addObserver(
            forName: Self.didChangeNotification,
            object: self,
            queue: .main
        ) { notification in
            guard let change = notification.userInfo?[changeUserInfoKey] as? Change else {
                return
            }
            handler(change)
        }
    }

    func taskDidStart(projectID: String) {
        setState(.building, for: projectID)
    }

    func taskDidComplete(projectID: String, hasNewVersion: Bool) {
        setState(hasNewVersion ? .newVersionAvailable : .idle, for: projectID)
    }

    func taskDidCancel(projectID: String) {
        setState(.idle, for: projectID)
    }

    func taskDidFail(projectID: String) {
        setState(.idle, for: projectID)
    }

    func markProjectViewed(projectID: String) {
        guard state(for: projectID) == .newVersionAvailable else { return }
        setState(.idle, for: projectID)
    }

    func clear(projectID: String) {
        setState(.idle, for: projectID)
    }

    private func setState(_ state: State, for projectID: String) {
        let previousState = states[projectID] ?? .idle
        guard previousState != state else { return }

        if state == .idle {
            states.removeValue(forKey: projectID)
        } else {
            states[projectID] = state
        }

        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [Self.changeUserInfoKey: Change(projectID: projectID, state: state)]
        )
    }
}
