//
//  ModelConfigurationViewController.swift
//  Doufu
//
//  Extracted from ProjectChatViewController.swift
//

import UIKit

@MainActor
final class ModelConfigurationViewController: UITableViewController {
    struct SelectionState: Equatable {
        var selectedProviderID: String
        var selectedModelRecordID: String
        var selectedReasoningEffort: ProjectChatService.ReasoningEffort?
        var selectedThinkingEnabled: Bool?

        static let empty = SelectionState(
            selectedProviderID: "",
            selectedModelRecordID: "",
            selectedReasoningEffort: nil,
            selectedThinkingEnabled: nil
        )
    }

    var onSelectionStateChanged: ((SelectionState) -> SelectionApplyOutcome)?
    var onResetToDefaults: (() -> SelectionState)?

    private enum Section: Int, CaseIterable {
        case inherit
        case provider
        case model
        case parameter
        case manage
    }

    private enum ManageRow: Int, CaseIterable {
        case useDefault
        case manageProviders
        case refreshOfficialModels
        case addCustomModel
    }

    private var providers: [LLMProviderRecord] = []
    private var availableProviderIDs: Set<String> = []
    private var state: SelectionState
    private let projectUsageIdentifier: String
    private let usageStore = LLMTokenUsageStore.shared
    private let providerStore = LLMProviderSettingsStore.shared
    private let modelDiscoveryService = LLMProviderModelDiscoveryService()
    private var showsResetToDefaults: Bool
    private var inheritedState: SelectionState?
    private let inheritedStateProvider: (() -> SelectionState?)?
    private let inheritTitle: String?
    private var isFollowingParent: Bool
    private var usageRecords: [LLMTokenUsageRecord] = []
    private var usageByProviderID: [String: Int64] = [:]
    private var usageByProviderModel: [String: Int64] = [:]
    private var isRefreshingModels = false
    private var modelRefreshTask: Task<Void, Never>?

    private let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    init(
        initialState: SelectionState,
        showsResetToDefaults: Bool,
        projectUsageIdentifier: String,
        inheritedState: SelectionState? = nil,
        inheritedStateProvider: (() -> SelectionState?)? = nil,
        inheritTitle: String? = nil
    ) {
        state = initialState
        self.showsResetToDefaults = showsResetToDefaults
        self.projectUsageIdentifier = projectUsageIdentifier
        self.inheritedStateProvider = inheritedStateProvider
        self.inheritedState = inheritedStateProvider?() ?? inheritedState
        self.inheritTitle = inheritTitle
        self.isFollowingParent = (inheritedStateProvider != nil || inheritedState != nil) && !showsResetToDefaults
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Visible Sections

    private var visibleSections: [Section] {
        Section.allCases.filter { section in
            switch section {
            case .inherit:
                return hasInheritedSelectionSource
            default:
                return true
            }
        }
    }

    private func section(for indexPath: IndexPath) -> Section? {
        let sections = visibleSections
        guard sections.indices.contains(indexPath.section) else { return nil }
        return sections[indexPath.section]
    }

    private func sectionIndex(for section: Section) -> Int? {
        visibleSections.firstIndex(of: section)
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProjectModelConfigCell")
        tableView.register(SettingsToggleCell.self, forCellReuseIdentifier: SettingsToggleCell.reuseIdentifier)
        reloadProviderContext()
        reloadUsageData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadProviderContext()
        reloadUsageData()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if view.window == nil {
            modelRefreshTask?.cancel()
        }
    }

    // MARK: - DataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        visibleSections.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection sectionIndex: Int) -> Int {
        guard let section = visibleSections[safe: sectionIndex] else {
            return 0
        }
        switch section {
        case .inherit:
            return 1
        case .provider:
            if isFollowingParent {
                // Show only the inherited provider (1 row)
                return 1
            }
            return providers.count
        case .model:
            if isFollowingParent {
                // Show only the inherited model (1 row)
                return 1
            }
            guard let selectedProvider = selectedProviderRecord() else {
                return 0
            }
            return availableModels(for: selectedProvider).count
        case .parameter:
            let currentSelection = isFollowingParent ? (inheritedState ?? .empty) : state
            guard let selectedProvider = providerRecord(for: currentSelection) else {
                return 0
            }
            guard let selectedModel = selectedModelRecord(for: selectedProvider, selection: currentSelection) else {
                return 0
            }
            if isFollowingParent {
                switch selectedProvider.kind {
                case .openAICompatible:
                    return reasoningProfile(for: selectedProvider, modelID: selectedModel.id) != nil ? 1 : 0
                case .anthropic, .googleGemini:
                        return resolveModelProfile(for: selectedProvider, modelID: selectedModel.id).thinkingSupported ? 1 : 0
                }
            }
            switch selectedProvider.kind {
            case .openAICompatible:
                return reasoningProfile(for: selectedProvider, modelID: selectedModel.id)?
                    .supported.count ?? 0
            case .anthropic, .googleGemini:
                return resolveModelProfile(for: selectedProvider, modelID: selectedModel.id).thinkingSupported ? 1 : 0
            }
        case .manage:
            if isFollowingParent { return 0 }
            return visibleManageRows.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection sectionIndex: Int) -> String? {
        guard let section = visibleSections[safe: sectionIndex] else {
            return nil
        }
        switch section {
        case .inherit:
            return nil
        case .provider:
            return String(localized: "chat.menu.provider")
        case .model:
            return String(localized: "chat.menu.model")
        case .parameter:
            let currentSelection = isFollowingParent ? (inheritedState ?? .empty) : state
            guard let selectedProvider = providerRecord(for: currentSelection) else {
                return nil
            }
            guard selectedModelRecord(for: selectedProvider, selection: currentSelection) != nil else {
                return nil
            }
            switch selectedProvider.kind {
            case .openAICompatible:
                return String(localized: "chat.menu.reasoning")
            case .anthropic, .googleGemini:
                return String(localized: "chat.menu.thinking")
            }
        case .manage:
            if isFollowingParent { return nil }
            return String(localized: "model_config.section.manage_models")
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection sectionIndex: Int) -> String? {
        guard let section = visibleSections[safe: sectionIndex] else {
            return nil
        }
        switch section {
        case .model:
            if isFollowingParent { return nil }
            let models = providerRecord(for: state).flatMap { availableModels(for: $0) } ?? []
            return models.isEmpty ? nil : String(localized: "model_config.section.model.footer")
        default:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let section = section(for: indexPath) else {
            return UITableViewCell()
        }

        switch section {
        case .inherit:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: SettingsToggleCell.reuseIdentifier,
                for: indexPath
            ) as? SettingsToggleCell else {
                return UITableViewCell()
            }
            cell.configure(
                title: inheritTitle ?? String(localized: "project_settings.chat.tool_permission.use_default"),
                isOn: isFollowingParent
            ) { [weak self] value in
                guard let self else { return }
                if value {
                    self.isFollowingParent = true
                    if let resetState = self.onResetToDefaults?() {
                        self.state = resetState
                    }
                    self.showsResetToDefaults = false
                    self.refreshNavigationTitle()
                } else {
                    self.isFollowingParent = false
                    self.notifySelectionChanged()
                }
                self.tableView.reloadData()
            }
            cell.isUserInteractionEnabled = true
            return cell

        case .provider:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectModelConfigCell", for: indexPath)
            if isFollowingParent {
                // Show inherited provider as read-only
                var configuration = cell.defaultContentConfiguration()
                let inherited = inheritedState ?? .empty
                if let provider = providerRecord(for: inherited) {
                    configuration.text = providerTitle(for: provider)
                    configuration.secondaryText = provider.kind.displayName
                } else if !trimmedProviderID(in: inherited).isEmpty {
                    configuration.text = trimmedProviderID(in: inherited)
                    configuration.secondaryText = String(
                        localized: "chat.model_selection.invalid.generic",
                        defaultValue: "Invalid Model Selection"
                    )
                } else {
                    configuration.text = String(
                        localized: "chat.model_selection.missing.short",
                        defaultValue: "Missing Model Selection"
                    )
                    configuration.secondaryText = nil
                }
                configuration.textProperties.color = .tertiaryLabel
                configuration.secondaryTextProperties.color = .tertiaryLabel
                cell.contentConfiguration = configuration
                cell.accessoryType = .none
                return cell
            }
            guard providers.indices.contains(indexPath.row) else {
                return cell
            }
            let provider = providers[indexPath.row]
            var configuration = cell.defaultContentConfiguration()
            configuration.text = providerTitle(for: provider)
            configuration.secondaryText = providerSubtitle(for: provider)
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.accessoryType = provider.id == state.selectedProviderID ? .checkmark : .none
            return cell

        case .model:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectModelConfigCell", for: indexPath)
            if isFollowingParent {
                // Show inherited model as read-only
                var configuration = cell.defaultContentConfiguration()
                let inherited = inheritedState ?? .empty
                if let provider = providerRecord(for: inherited),
                   let model = selectedModelRecord(for: provider, selection: inherited) {
                    configuration.text = model.effectiveDisplayName
                } else if !trimmedModelRecordID(in: inherited).isEmpty {
                    configuration.text = trimmedModelRecordID(in: inherited)
                } else {
                    configuration.text = String(
                        localized: "chat.model_selection.missing.short",
                        defaultValue: "Missing Model Selection"
                    )
                }
                configuration.textProperties.color = .tertiaryLabel
                cell.contentConfiguration = configuration
                cell.accessoryType = .none
                return cell
            }
            guard let selectedProvider = selectedProviderRecord() else {
                return cell
            }
            let models = availableModels(for: selectedProvider)
            guard models.indices.contains(indexPath.row) else {
                return cell
            }
            let model = models[indexPath.row]
            let modelID = model.modelID
            var configuration = cell.defaultContentConfiguration()
            configuration.text = model.effectiveDisplayName
            let usageText = usedTokenCountText(
                modelTokenUsage(
                    providerID: selectedProvider.id,
                    modelID: modelID
                )
            )
            let sourceText: String
            switch model.source {
            case .official:
                sourceText = String(localized: "model_config.source.official")
            case .custom:
                sourceText = String(localized: "model_config.source.custom")
            }
            configuration.secondaryText = sourceText + " · " + usageText
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.accessoryType = model.id.caseInsensitiveCompare(selectedModelRecordID(for: selectedProvider)) == .orderedSame
                ? .checkmark
                : .none
            return cell

        case .parameter:
            let currentSelection = isFollowingParent ? (inheritedState ?? .empty) : state
            guard let selectedProvider = providerRecord(for: currentSelection) else {
                return UITableViewCell()
            }
            guard let selectedModel = selectedModelRecord(for: selectedProvider, selection: currentSelection) else {
                return UITableViewCell()
            }
            let selectedModelRecordID = selectedModel.id
            switch selectedProvider.kind {
            case .openAICompatible:
                let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectModelConfigCell", for: indexPath)
                let currentEffort = resolvedReasoningEffort(
                    for: selectedProvider,
                    modelID: selectedModelRecordID,
                    reasoningEffort: currentSelection.selectedReasoningEffort
                )
                if isFollowingParent {
                    var configuration = cell.defaultContentConfiguration()
                    configuration.text = currentEffort.displayName
                    configuration.textProperties.color = .tertiaryLabel
                    cell.contentConfiguration = configuration
                    cell.accessoryType = .none
                    return cell
                }
                let profile = reasoningProfile(for: selectedProvider, modelID: selectedModelRecordID)
                let efforts = profile?.supported ?? []
                guard efforts.indices.contains(indexPath.row) else {
                    return cell
                }
                let effort = efforts[indexPath.row]
                var configuration = cell.defaultContentConfiguration()
                configuration.text = effort.displayName
                cell.accessoryType = effort == currentEffort ? .checkmark : .none
                cell.contentConfiguration = configuration
                return cell

            case .anthropic, .googleGemini:
                guard
                    let cell = tableView.dequeueReusableCell(
                        withIdentifier: SettingsToggleCell.reuseIdentifier,
                        for: indexPath
                    ) as? SettingsToggleCell
                else {
                    return UITableViewCell()
                }
                let capabilities = resolveModelProfile(for: selectedProvider, modelID: selectedModelRecordID)
                let isOn = resolvedThinkingEnabled(
                    for: selectedProvider,
                    modelID: selectedModelRecordID,
                    thinkingEnabled: currentSelection.selectedThinkingEnabled
                )
                let canInteract = !isFollowingParent && capabilities.thinkingCanDisable
                cell.configure(
                    title: capabilities.thinkingCanDisable
                        ? String(localized: "chat.menu.thinking")
                        : String(localized: "model_config.thinking_required"),
                    isOn: isOn
                ) { [weak self] value in
                    guard let self else { return }
                    guard !self.isFollowingParent else { return }
                    guard value != isOn else { return }
                    self.applyThinkingEnabled(value, for: selectedProvider, modelID: selectedModelRecordID)
                    self.notifySelectionChanged()
                }
                cell.isUserInteractionEnabled = canInteract
                return cell
            }
        case .manage:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectModelConfigCell", for: indexPath)
            let rows = visibleManageRows
            guard rows.indices.contains(indexPath.row) else {
                return cell
            }
            let row = rows[indexPath.row]
            var configuration = cell.defaultContentConfiguration()
            switch row {
            case .useDefault:
                configuration.text = String(localized: "project_settings.chat.tool_permission.use_default")
                configuration.secondaryText = nil
                cell.accessoryType = .none
            case .manageProviders:
                configuration.text = String(localized: "settings.providers.title")
                configuration.secondaryText = String(
                    localized: "chat.model_selection.manage_provider",
                    defaultValue: "Fix provider credentials or add providers."
                )
                cell.accessoryType = .disclosureIndicator
            case .refreshOfficialModels:
                configuration.text = isRefreshingModels
                    ? String(localized: "model_config.manage.refreshing_models")
                    : String(localized: "model_config.manage.refresh_models")
                configuration.secondaryText = String(localized: "model_config.manage.refresh_models_subtitle")
                cell.accessoryType = .none
            case .addCustomModel:
                configuration.text = String(localized: "model_config.manage.add_custom_model")
                configuration.secondaryText = String(localized: "model_config.manage.add_custom_model_subtitle")
                cell.accessoryType = .disclosureIndicator
            }
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            return cell
        }
    }

    // MARK: - Selection

    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard let section = section(for: indexPath) else {
            return nil
        }
        switch section {
        case .inherit:
            return nil
        case .provider, .model:
            return isFollowingParent ? nil : indexPath
        case .parameter:
            if isFollowingParent { return nil }
            guard let selectedProvider = selectedProviderRecord() else {
                return nil
            }
            switch selectedProvider.kind {
            case .openAICompatible:
                return indexPath
            case .anthropic, .googleGemini:
                return nil
            }
        case .manage:
            return isFollowingParent ? nil : indexPath
        }
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        if isFollowingParent { return nil }
        guard section(for: indexPath) == .model,
              let selectedProvider = selectedProviderRecord()
        else { return nil }
        let models = availableModels(for: selectedProvider)
        guard models.indices.contains(indexPath.row) else { return nil }
        let model = models[indexPath.row]
        let actionTitle = model.source == .official
            ? String(localized: "model_config.action.detail")
            : String(localized: "common.action.edit")
        let action = UIContextualAction(style: .normal, title: actionTitle) { [weak self] _, _, completion in
            guard let self else { completion(false); return }
            if model.source == .official {
                self.presentModelDetail(provider: selectedProvider, model: model)
            } else {
                self.presentModelEditor(provider: selectedProvider, existingModel: model)
            }
            completion(true)
        }
        action.backgroundColor = .systemBlue
        return UISwipeActionsConfiguration(actions: [action])
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard let section = section(for: indexPath) else {
            return
        }
        switch section {
        case .inherit:
            // Handled by SettingsToggleCell callback
            return

        case .provider:
            guard providers.indices.contains(indexPath.row) else {
                return
            }
            let selectedProvider = providers[indexPath.row]
            guard selectedProvider.id != state.selectedProviderID else {
                return
            }
            state.selectedProviderID = selectedProvider.id
            state.selectedModelRecordID = availableModels(for: selectedProvider).first?.id ?? ""
            state.selectedReasoningEffort = nil
            state.selectedThinkingEnabled = nil
            notifySelectionChanged()
            tableView.reloadData()

        case .model:
            guard let selectedProvider = selectedProviderRecord() else {
                return
            }
            let models = availableModels(for: selectedProvider)
            guard models.indices.contains(indexPath.row) else {
                return
            }
            let modelID = models[indexPath.row].id
            guard modelID.caseInsensitiveCompare(selectedModelRecordID(for: selectedProvider)) != .orderedSame else {
                return
            }
            state.selectedModelRecordID = modelID
            state.selectedReasoningEffort = nil
            state.selectedThinkingEnabled = nil
            notifySelectionChanged()
            tableView.reloadData()

        case .parameter:
            guard let selectedProvider = selectedProviderRecord() else {
                return
            }
            guard let selectedModel = selectedModelRecord(for: selectedProvider) else {
                return
            }
            let selectedModelRecordID = selectedModel.id
            switch selectedProvider.kind {
            case .openAICompatible:
                guard
                    let profile = reasoningProfile(for: selectedProvider, modelID: selectedModelRecordID),
                    profile.supported.indices.contains(indexPath.row)
                else {
                    return
                }
                let selectedEffort = profile.supported[indexPath.row]
                guard selectedEffort != resolvedReasoningEffort(
                    for: selectedProvider,
                    modelID: selectedModelRecordID,
                    reasoningEffort: state.selectedReasoningEffort
                ) else {
                    return
                }
                applyReasoningEffort(selectedEffort, for: selectedProvider, modelID: selectedModelRecordID)
                notifySelectionChanged()
                if let paramIndex = sectionIndex(for: .parameter) {
                    tableView.reloadSections(IndexSet(integer: paramIndex), with: .none)
                }
            case .anthropic, .googleGemini:
                return
            }
        case .manage:
            guard visibleManageRows.indices.contains(indexPath.row) else {
                return
            }
            let row = visibleManageRows[indexPath.row]
            switch row {
            case .useDefault:
                guard let resetState = onResetToDefaults?() else {
                    return
                }
                state = resetState
                showsResetToDefaults = false
                isFollowingParent = hasInheritedSelectionSource
                refreshNavigationTitle()
                tableView.reloadData()
            case .manageProviders:
                let controller = ManageProvidersViewController()
                navigationController?.pushViewController(controller, animated: true)
            case .refreshOfficialModels:
                guard let selectedProvider = selectedProviderRecord() else {
                    return
                }
                refreshOfficialModels(for: selectedProvider)
            case .addCustomModel:
                guard let selectedProvider = selectedProviderRecord() else {
                    return
                }
                presentModelEditor(provider: selectedProvider, existingModel: nil)
            }
        }
    }

    // MARK: - Helpers

    private var hasInheritedSelectionSource: Bool {
        inheritedStateProvider != nil || inheritedState != nil
    }

    private func refreshInheritedState() {
        if let inheritedStateProvider {
            inheritedState = inheritedStateProvider()
        }
    }

    private func trimmedProviderID(in selection: SelectionState) -> String {
        selection.selectedProviderID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func trimmedModelRecordID(in selection: SelectionState) -> String {
        selection.selectedModelRecordID.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func providerRecord(for selection: SelectionState) -> LLMProviderRecord? {
        let providerID = trimmedProviderID(in: selection)
        guard !providerID.isEmpty else {
            return nil
        }
        return providers.first(where: { $0.id == providerID })
    }

    private func selectedProviderRecord() -> LLMProviderRecord? {
        providerRecord(for: state)
    }

    private func selectedModelRecordID(
        for provider: LLMProviderRecord,
        selection: SelectionState? = nil
    ) -> String {
        let effectiveSelection = selection ?? state
        if trimmedProviderID(in: effectiveSelection) == provider.id {
            return trimmedModelRecordID(in: effectiveSelection)
        }
        return availableModels(for: provider).first?.id ?? ""
    }

    private func selectedModelRecord(
        for provider: LLMProviderRecord,
        selection: SelectionState? = nil
    ) -> LLMProviderModelRecord? {
        let selectedRecordID = selectedModelRecordID(for: provider, selection: selection)
        guard !selectedRecordID.isEmpty else {
            return nil
        }
        return availableModels(for: provider).first(where: {
            $0.normalizedID == selectedRecordID.lowercased()
        })
    }

    private func availableModels(for provider: LLMProviderRecord) -> [LLMProviderModelRecord] {
        providerStore.availableModels(forProviderID: provider.id)
    }

    private func providerTitle(for provider: LLMProviderRecord) -> String {
        let normalizedLabel = provider.label.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedLabel.isEmpty ? provider.kind.displayName : normalizedLabel
    }

    private func resolveModelProfile(
        for provider: LLMProviderRecord,
        modelID: String
    ) -> ResolvedModelProfile {
        let record = providerStore.modelRecord(providerID: provider.id, modelID: modelID)
            ?? availableModels(for: provider).first(where: { $0.normalizedModelID == normalizedModelID(modelID) })
        return LLMModelRegistry.resolve(
            providerKind: provider.kind,
            modelID: record?.modelID ?? modelID,
            modelRecord: record
        )
    }

    private func reasoningProfile(
        for provider: LLMProviderRecord,
        modelID: String
    ) -> (supported: [ProjectChatService.ReasoningEffort], defaultEffort: ProjectChatService.ReasoningEffort)? {
        guard provider.kind == .openAICompatible else {
            return nil
        }
        let supported = resolveModelProfile(for: provider, modelID: modelID).reasoningEfforts
        guard !supported.isEmpty else {
            return nil
        }
        let defaultEffort: ProjectChatService.ReasoningEffort = supported.contains(.high)
            ? .high
            : (supported.first ?? .medium)
        return (supported: supported, defaultEffort: defaultEffort)
    }

    private func resolvedReasoningEffort(
        for provider: LLMProviderRecord,
        modelID: String,
        reasoningEffort: ProjectChatService.ReasoningEffort?
    ) -> ProjectChatService.ReasoningEffort {
        guard let profile = reasoningProfile(for: provider, modelID: modelID) else {
            return .high
        }
        if let selected = reasoningEffort, profile.supported.contains(selected) {
            return selected
        }
        return profile.defaultEffort
    }

    private func applyReasoningEffort(
        _ effort: ProjectChatService.ReasoningEffort,
        for provider: LLMProviderRecord,
        modelID: String
    ) {
        guard let profile = reasoningProfile(for: provider, modelID: modelID) else {
            state.selectedReasoningEffort = nil
            return
        }
        guard profile.supported.contains(effort), effort != profile.defaultEffort else {
            state.selectedReasoningEffort = nil
            return
        }
        state.selectedReasoningEffort = effort
    }

    private func resolvedThinkingEnabled(
        for provider: LLMProviderRecord,
        modelID: String,
        thinkingEnabled: Bool?
    ) -> Bool {
        let capabilities = resolveModelProfile(for: provider, modelID: modelID)
        guard capabilities.thinkingSupported else {
            return false
        }
        guard capabilities.thinkingCanDisable else {
            return true
        }
        return thinkingEnabled ?? true
    }

    private func applyThinkingEnabled(
        _ value: Bool,
        for provider: LLMProviderRecord,
        modelID: String
    ) {
        let capabilities = resolveModelProfile(for: provider, modelID: modelID)
        guard capabilities.thinkingSupported else {
            state.selectedThinkingEnabled = nil
            return
        }
        guard capabilities.thinkingCanDisable else {
            state.selectedThinkingEnabled = nil
            return
        }
        if value {
            state.selectedThinkingEnabled = nil
        } else {
            state.selectedThinkingEnabled = false
        }
    }

    private func normalizedModelID(_ modelID: String) -> String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func reloadProviderContext() {
        providers = providerStore.loadProviders()
        availableProviderIDs = Set(
            ProviderCredentialResolver.resolveAvailableCredentials(providerStore: providerStore)
                .map(\.providerID)
        )
        refreshInheritedState()

        guard !isFollowingParent else {
            refreshNavigationTitle()
            tableView.reloadData()
            return
        }

        let selectedProviderID = trimmedProviderID(in: state)
        let selectedModelRecordID = trimmedModelRecordID(in: state)
        if let selectedProvider = providers.first(where: { $0.id == selectedProviderID }) {
            if selectedModelRecordID.isEmpty || !availableModels(for: selectedProvider).contains(where: {
                $0.normalizedID == selectedModelRecordID.lowercased()
            }) {
                state.selectedReasoningEffort = nil
                state.selectedThinkingEnabled = nil
            }
        } else if selectedProviderID.isEmpty, let fallbackProvider = providers.first {
            state.selectedProviderID = fallbackProvider.id
            state.selectedModelRecordID = availableModels(for: fallbackProvider).first?.id ?? ""
            state.selectedReasoningEffort = nil
            state.selectedThinkingEnabled = nil
        } else if selectedProviderID.isEmpty {
            state = .empty
        } else {
            state.selectedReasoningEffort = nil
            state.selectedThinkingEnabled = nil
        }

        refreshNavigationTitle()
        tableView.reloadData()
    }

    private func reloadUsageData() {
        usageRecords = usageStore.loadRecords(projectIdentifier: projectUsageIdentifier)
        usageByProviderID = Dictionary(
            grouping: usageRecords,
            by: { $0.providerID }
        ).mapValues { records in
            records.reduce(Int64(0)) { $0 + $1.totalTokens }
        }
        usageByProviderModel = Dictionary(
            uniqueKeysWithValues: usageRecords.map { record in
                (providerModelUsageKey(providerID: record.providerID, modelID: record.model), record.totalTokens)
            }
        )
        tableView.reloadData()
    }

    private func providerModelUsageKey(providerID: String, modelID: String) -> String {
        providerID.lowercased() + "|" + normalizedModelID(modelID)
    }

    private func providerTokenUsage(for providerID: String) -> Int64 {
        usageByProviderID[providerID] ?? 0
    }

    private func modelTokenUsage(providerID: String, modelID: String) -> Int64 {
        usageByProviderModel[providerModelUsageKey(providerID: providerID, modelID: modelID)] ?? 0
    }

    private func providerSubtitle(for provider: LLMProviderRecord) -> String {
        let providerKindName = provider.kind.displayName
        let usageText = usedTokenCountText(providerTokenUsage(for: provider.id))
        if availableProviderIDs.contains(provider.id) {
            return String(
                format: String(localized: "providers.usage.detail.section.model_format"),
                providerKindName,
                usageText
            )
        }
        return providerKindName + " · " + String(
            localized: "chat.model_selection.provider_unavailable",
            defaultValue: "Credential unavailable"
        )
    }

    private func usedTokenCountText(_ value: Int64) -> String {
        let tokenCountText = formattedTokenCount(value)
        return String(format: String(localized: "providers.usage.used_tokens_format"), tokenCountText)
    }

    private func formattedTokenCount(_ value: Int64) -> String {
        let number = NSNumber(value: value)
        let formatted = numberFormatter.string(from: number) ?? "\(value)"
        return String(format: String(localized: "providers.usage.tokens_format"), formatted)
    }

    private func refreshOfficialModels(for provider: LLMProviderRecord) {
        isRefreshingModels = true
        if let manageIndex = sectionIndex(for: .manage) {
            tableView.reloadSections(IndexSet(integer: manageIndex), with: .none)
        }
        modelRefreshTask?.cancel()
        modelRefreshTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                Task { @MainActor [weak self] in
                    self?.isRefreshingModels = false
                    self?.tableView.reloadData()
                }
            }

            let token = (try? self.providerStore.loadBearerToken(for: provider))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !token.isEmpty else {
                let alert = UIAlertController(
                    title: String(localized: "model_config.alert.refresh_failed"),
                    message: String(
                        localized: "chat.model_selection.provider_unavailable.fix_hint",
                        defaultValue: "Configure this provider before refreshing models."
                    ),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
                self.present(alert, animated: true)
                return
            }

            do {
                let models = try await self.modelDiscoveryService.fetchModels(for: provider, bearerToken: token)
                _ = try self.providerStore.replaceOfficialModels(providerID: provider.id, models: models)
            } catch {
                let alert = UIAlertController(
                    title: String(localized: "model_config.alert.refresh_failed"),
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
                self.present(alert, animated: true)
            }
        }
    }

    private func editorCredential(for provider: LLMProviderRecord) -> ProjectChatService.ProviderCredential {
        let modelID = provider.modelID ?? provider.kind.defaultModelID
        let baseURL = URL(string: provider.effectiveBaseURLString)
            ?? URL(string: provider.kind.defaultBaseURLString)!
        let bearerToken = (try? providerStore.loadBearerToken(for: provider)) ?? ""
        let modelRecord = provider.availableModels.first(where: {
            $0.normalizedModelID == normalizedModelID(modelID)
        })
        let profile = LLMModelRegistry.resolve(
            providerKind: provider.kind,
            modelID: modelRecord?.modelID ?? modelID,
            modelRecord: modelRecord
        )
        return ProjectChatService.ProviderCredential(
            providerID: provider.id,
            providerLabel: provider.label,
            providerKind: provider.kind,
            authMode: provider.authMode,
            modelID: profile.modelID,
            baseURL: baseURL,
            bearerToken: bearerToken,
            chatGPTAccountID: provider.chatGPTAccountID,
            profile: profile
        )
    }

    private func presentModelDetail(
        provider: LLMProviderRecord,
        model: LLMProviderModelRecord
    ) {
        let controller = ProviderModelEditorViewController(
            provider: editorCredential(for: provider),
            existingModel: model,
            readOnly: true
        )
        navigationController?.pushViewController(controller, animated: true)
    }

    private func presentModelEditor(
        provider: LLMProviderRecord,
        existingModel: LLMProviderModelRecord?
    ) {
        let controller = ProviderModelEditorViewController(
            provider: editorCredential(for: provider),
            existingModel: existingModel
        )
        controller.onSave = { [weak self] payload in
            guard let self else {
                return
            }
            do {
                _ = try self.providerStore.saveCustomModel(
                    providerID: provider.id,
                    modelID: payload.modelID,
                    displayName: payload.displayName,
                    capabilities: payload.capabilities,
                    existingRecordID: existingModel?.id
                )
                self.tableView.reloadData()
            } catch {
                let alert = UIAlertController(
                    title: String(localized: "model_config.alert.save_failed"),
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
                self.present(alert, animated: true)
            }
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    private func notifySelectionChanged() {
        showsResetToDefaults = onSelectionStateChanged?(state).hasExplicitSelection ?? true
        refreshNavigationTitle()
    }

    private var visibleManageRows: [ManageRow] {
        ManageRow.allCases.filter { row in
            switch row {
            case .useDefault:
                return showsResetToDefaults && !hasInheritedSelectionSource
            case .manageProviders:
                return true
            case .refreshOfficialModels, .addCustomModel:
                return selectedProviderRecord() != nil
            }
        }
    }

    private func refreshNavigationTitle() {
        let selection = isFollowingParent ? inheritedState : state
        guard let selection else {
            title = String(localized: "chat.menu.model")
            navigationItem.prompt = nil
            return
        }
        if let provider = providerRecord(for: selection) {
            let selectedRecordID = selectedModelRecordID(for: provider, selection: selection)
            let selectedTitle = selectedModelRecord(for: provider, selection: selection)?.effectiveDisplayName ?? selectedRecordID
            title = selectedTitle.isEmpty ? providerTitle(for: provider) : providerTitle(for: provider) + "-" + selectedTitle
        } else {
            let providerID = trimmedProviderID(in: selection)
            let modelID = trimmedModelRecordID(in: selection)
            if !providerID.isEmpty {
                title = modelID.isEmpty ? providerID : providerID + "-" + modelID
            } else {
                title = String(localized: "chat.menu.model")
            }
        }
        navigationItem.prompt = statusPrompt(for: selection)
    }

    private func statusPrompt(for selection: SelectionState) -> String? {
        if trimmedProviderID(in: selection).isEmpty && trimmedModelRecordID(in: selection).isEmpty {
            return String(
                localized: "chat.model_selection.missing.short",
                defaultValue: "Missing Model Selection"
            )
        }
        guard let provider = providerRecord(for: selection) else {
            return String(
                localized: "chat.model_selection.invalid.generic",
                defaultValue: "Invalid Model Selection"
            )
        }
        guard selectedModelRecord(for: provider, selection: selection) != nil else {
            return String(
                localized: "chat.model_selection.invalid.generic",
                defaultValue: "Invalid Model Selection"
            )
        }
        return nil
    }
}

private extension Array {
    subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
