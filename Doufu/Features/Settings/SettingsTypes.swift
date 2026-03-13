//
//  SettingsTypes.swift
//  Doufu
//

nonisolated enum SettingsSectionID: Hashable, Sendable {
    case general
    case llmProviders
    case project
    case contact
    case appjun
    case about
}

nonisolated enum SettingsItemID: Hashable, Sendable {
    // General
    case language(secondaryText: String)

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
