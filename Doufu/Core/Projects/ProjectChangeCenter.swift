//
//  ProjectChangeCenter.swift
//  Doufu
//

import Foundation

@MainActor
final class ProjectChangeCenter {

    static let shared = ProjectChangeCenter()

    enum Kind: Equatable {
        case filesChanged
        case checkpointRestored
        case renamed
        case descriptionChanged
        case toolPermissionChanged
        case modelSelectionChanged
    }

    struct Change: Equatable {
        let projectID: String
        let kind: Kind
    }

    private static let didChangeNotification = Notification.Name("ProjectChangeCenter.didChange")
    private static let changeUserInfoKey = "change"

    private init() {}

    func addObserver(
        projectID: String? = nil,
        using handler: @escaping (Change) -> Void
    ) -> NSObjectProtocol {
        let changeUserInfoKey = Self.changeUserInfoKey
        return NotificationCenter.default.addObserver(
            forName: Self.didChangeNotification,
            object: self,
            queue: .main
        ) { notification in
            guard let change = notification.userInfo?[changeUserInfoKey] as? Change else {
                return
            }
            if let projectID, change.projectID != projectID {
                return
            }
            handler(change)
        }
    }

    func notifyFilesChanged(projectID: String) {
        AppProjectStore.shared.touchProjectUpdatedAt(projectID: projectID)
        post(.init(projectID: projectID, kind: .filesChanged))
    }

    func notifyCheckpointRestored(projectID: String) {
        AppProjectStore.shared.touchProjectUpdatedAt(projectID: projectID)
        post(.init(projectID: projectID, kind: .checkpointRestored))
    }

    func notifyProjectRenamed(projectID: String) {
        post(.init(projectID: projectID, kind: .renamed))
    }

    func notifyProjectDescriptionChanged(projectID: String) {
        post(.init(projectID: projectID, kind: .descriptionChanged))
    }

    func notifyToolPermissionChanged(projectID: String) {
        post(.init(projectID: projectID, kind: .toolPermissionChanged))
    }

    func notifyProjectModelSelectionChanged(projectID: String) {
        post(.init(projectID: projectID, kind: .modelSelectionChanged))
    }

    private func post(_ change: Change) {
        NotificationCenter.default.post(
            name: Self.didChangeNotification,
            object: self,
            userInfo: [Self.changeUserInfoKey: change]
        )
    }
}
