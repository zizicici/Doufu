//
//  ProjectSettingsTypes.swift
//  Doufu
//

nonisolated enum ProjectSettingsSectionID: Hashable, Sendable {
    case project
    case chat
    case checkpoints
    case storage
}

nonisolated enum ProjectSettingsItemID: Hashable, Sendable {
    case projectName
    case projectDescription
    case defaultModel
    case toolPermission
    case checkpointHistory
    case clearLocalStorage
    case clearIndexedDB
}

// MARK: - Checkpoint History

nonisolated enum CheckpointSectionID: Hashable, Sendable {
    case checkpoints
}

nonisolated enum CheckpointItemID: Hashable, Sendable {
    case empty
    case checkpoint(id: String, isCurrent: Bool)
}
