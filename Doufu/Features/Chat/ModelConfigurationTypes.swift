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
    case modelSearchBar
}

nonisolated enum ModelConfigCellData: Sendable {
    case inheritToggle(title: String, isOn: Bool)
    case provider(title: String, subtitle: String, isSelected: Bool, inherited: Bool)
    case model(displayName: String, subtitle: String, isSelected: Bool, inherited: Bool)
    case reasoningEffort(displayName: String, isSelected: Bool, inherited: Bool)
    case thinkingToggle(title: String, isOn: Bool, canInteract: Bool, inherited: Bool)
    case modelSearchBar(filterText: String)
    case manage(title: String, subtitle: String?, hasDisclosure: Bool)
}
