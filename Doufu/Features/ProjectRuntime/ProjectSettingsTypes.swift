//
//  ProjectSettingsTypes.swift
//  Doufu
//

import Foundation

nonisolated enum ProjectSettingsSectionID: Hashable, Sendable {
    case project
    case chat
    case capabilities
    case codeScan
    case checkpoints
    case storage
    case dangerZone

    var header: String? {
        switch self {
        case .project: return String(localized: "project_settings.section.project")
        case .chat: return String(localized: "project_settings.section.chat")
        case .capabilities: return String(localized: "project_settings.section.capabilities")
        case .codeScan: return String(localized: "project_settings.section.code_scan", defaultValue: "Security")
        case .checkpoints: return String(localized: "project_settings.section.checkpoints")
        case .storage: return String(localized: "project_settings.section.storage", defaultValue: "Storage")
        case .dangerZone: return nil
        }
    }

    var footer: String? {
        switch self {
        case .project: return String(localized: "project_settings.footer.project_name_usage")
        case .chat: return String(localized: "project_settings.footer.tool_permission")
        case .checkpoints: return String(localized: "project_settings.footer.checkpoints")
        case .storage: return String(localized: "project_settings.footer.storage", defaultValue: "Clearing storage will reload the web page.")
        case .capabilities, .codeScan, .dangerZone: return nil
        }
    }
}

nonisolated enum ProjectSettingsItemID: Hashable, Sendable {
    case projectName
    case projectDescription
    case defaultModel
    case toolPermission
    case capability(type: String, isAllowed: Bool)
    case capabilityActivityLog
    case codeScan
    case checkpointHistory
    case clearLocalStorage
    case clearIndexedDB
    case deleteProject
}

// MARK: - Checkpoint History

nonisolated enum CheckpointSectionID: Hashable, Sendable {
    case checkpoints
}

nonisolated enum CheckpointItemID: Hashable, Sendable {
    case empty
    case checkpoint(id: String, isCurrent: Bool)
}
