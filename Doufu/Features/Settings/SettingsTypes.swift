//
//  SettingsTypes.swift
//  Doufu
//

import Foundation

nonisolated enum SettingsSectionID: Hashable, Sendable {
    case general
    case permissions
    case llmProviders
    case project
    case contact
    case appjun
    case about

    var header: String? {
        switch self {
        case .general:
            return String(localized: "settings.section.general")
        case .permissions:
            return String(localized: "settings.section.permissions")
        case .llmProviders:
            return String(localized: "settings.section.llm_providers")
        case .project:
            return String(localized: "settings.section.project")
        case .contact:
            return String(localized: "settings.section.contact")
        case .appjun:
            return String(localized: "settings.section.appjun")
        case .about:
            return String(localized: "settings.section.about")
        }
    }

    var footer: String? {
        switch self {
        case .permissions:
            return String(localized: "settings.section.permissions.footer")
        case .llmProviders:
            return String(localized: "settings.section.llm_providers.footer")
        case .general, .project, .contact, .appjun, .about:
            return nil
        }
    }
}

nonisolated enum SettingsItemID: Hashable, Sendable {
    // General
    case language(secondaryText: String)

    // Permissions
    case cameraPermission(secondaryText: String)
    case microphonePermission(secondaryText: String)
    case locationPermission(secondaryText: String)
    case photoSavePermission(secondaryText: String)

    // LLM Providers
    case manageProviders(secondaryText: String)
    case defaultModel(secondaryText: String)
    case tokenUsage

    // Project
    case toolPermission(secondaryText: String)
    case pipProgress(secondaryText: String)

    // Contact
    case email
    case xiaohongshu
    case bilibili

    // App Jun
    case app(storeId: String)
    case moreApps

    // About
    case specifications
    case share
    case review
    case eula
    case privacyPolicy
}
