//
//  ModelConfigurationTypes.swift
//  Doufu
//

nonisolated enum ModelConfigSectionID: Hashable, Sendable {
    case inherit
    case provider
    case model
    case parameter
    case manage
}

nonisolated enum ModelConfigItemID: Hashable, Sendable {
    case inheritToggle
    case provider(id: String, inherited: Bool)
    case model(id: String, inherited: Bool)
    case reasoningEffort(String, inherited: Bool)
    case thinkingToggle(inherited: Bool)
    case manageUseDefault
    case manageProviders
    case manageRefreshModels(isRefreshing: Bool)
    case manageAddCustomModel
}
