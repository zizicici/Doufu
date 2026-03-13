//
//  ModelConfigurationViewController.swift
//  Doufu
//
//  Extracted from ProjectChatViewController.swift
//

import UIKit

@MainActor
final class ModelConfigurationViewController: UITableViewController {
    typealias SelectionState = ModelSelectionDraft

    var onSelectionStateChanged: ((SelectionState) -> SelectionApplyOutcome)?
    var onResetToDefaults: (() -> SelectionState)?

    // MARK: - State

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

    private var diffableDataSource: UITableViewDiffableDataSource<ModelConfigSectionID, ModelConfigItemID>!

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

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .doufuBackground
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProjectModelConfigCell")
        tableView.register(SettingsToggleCell.self, forCellReuseIdentifier: SettingsToggleCell.reuseIdentifier)
        configureDiffableDataSource()
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

    // MARK: - Diffable DataSource Setup

    private func configureDiffableDataSource() {
        diffableDataSource = UITableViewDiffableDataSource<ModelConfigSectionID, ModelConfigItemID>(
            tableView: tableView
        ) { [weak self] tableView, indexPath, itemID in
            guard let self else { return UITableViewCell() }
            return self.cell(for: tableView, indexPath: indexPath, itemID: itemID)
        }
        diffableDataSource.defaultRowAnimation = .none
    }

    private func cell(
        for tableView: UITableView,
        indexPath: IndexPath,
        itemID: ModelConfigItemID
    ) -> UITableViewCell {
        switch itemID {
        case .inheritToggle:
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
                self.applySnapshot()
            }
            cell.isUserInteractionEnabled = true
            return cell

        case .provider(let providerID, let inherited):
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectModelConfigCell", for: indexPath)
            guard let provider = providers.first(where: { $0.id == providerID }) else {
                if inherited {
                    var configuration = cell.defaultContentConfiguration()
                    if !providerID.isEmpty {
                        configuration.text = providerID
                        configuration.secondaryText = String(
                            localized: "chat.model_selection.invalid.generic",
                            defaultValue: "Invalid Model Selection"
                        )
                    } else {
                        configuration.text = String(
                            localized: "chat.model_selection.missing.short",
                            defaultValue: "Missing Model Selection"
                        )
                    }
                    configuration.textProperties.color = .tertiaryLabel
                    configuration.secondaryTextProperties.color = .tertiaryLabel
                    cell.contentConfiguration = configuration
                    cell.accessoryType = .none
                }
                return cell
            }
            var configuration = cell.defaultContentConfiguration()
            configuration.text = providerTitle(for: provider)
            if inherited {
                configuration.secondaryText = provider.kind.displayName
                configuration.textProperties.color = .tertiaryLabel
                configuration.secondaryTextProperties.color = .tertiaryLabel
                cell.accessoryType = .none
            } else {
                configuration.secondaryText = providerSubtitle(for: provider)
                configuration.secondaryTextProperties.color = .secondaryLabel
                cell.accessoryType = provider.id == state.selectedProviderID ? .checkmark : .none
            }
            cell.contentConfiguration = configuration
            return cell

        case .model(let modelRecordID, let inherited):
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectModelConfigCell", for: indexPath)
            let currentSelection = inherited ? (inheritedState ?? .empty) : state
            guard let selectedProvider = providerRecord(for: currentSelection) else {
                return cell
            }
            let models = availableModels(for: selectedProvider)
            guard let model = models.first(where: {
                inherited
                    ? $0.normalizedID == modelRecordID.lowercased()
                    : $0.id == modelRecordID
            }) else {
                if inherited {
                    var configuration = cell.defaultContentConfiguration()
                    configuration.text = modelRecordID.isEmpty
                        ? String(localized: "chat.model_selection.missing.short", defaultValue: "Missing Model Selection")
                        : modelRecordID
                    configuration.textProperties.color = .tertiaryLabel
                    cell.contentConfiguration = configuration
                    cell.accessoryType = .none
                }
                return cell
            }
            var configuration = cell.defaultContentConfiguration()
            configuration.text = model.effectiveDisplayName
            if inherited {
                configuration.textProperties.color = .tertiaryLabel
                cell.accessoryType = .none
            } else {
                let modelID = model.modelID
                let usageText = usedTokenCountText(
                    modelTokenUsage(providerID: selectedProvider.id, modelID: modelID)
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
                cell.accessoryType = model.id.caseInsensitiveCompare(selectedModelRecordID(for: selectedProvider)) == .orderedSame
                    ? .checkmark
                    : .none
            }
            cell.contentConfiguration = configuration
            return cell

        case .reasoningEffort(let effortRawValue, let inherited):
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectModelConfigCell", for: indexPath)
            let currentSelection = inherited ? (inheritedState ?? .empty) : state
            guard let selectedProvider = providerRecord(for: currentSelection),
                  let selectedModel = selectedModelRecord(for: selectedProvider, selection: currentSelection) else {
                return cell
            }
            let currentEffort = resolvedReasoningEffort(
                for: selectedProvider,
                modelID: selectedModel.id,
                reasoningEffort: currentSelection.selectedReasoningEffort
            )
            var configuration = cell.defaultContentConfiguration()
            if inherited {
                configuration.text = currentEffort.displayName
                configuration.textProperties.color = .tertiaryLabel
                cell.accessoryType = .none
            } else {
                let profile = reasoningProfile(for: selectedProvider, modelID: selectedModel.id)
                guard let effort = profile?.supported.first(where: { $0.rawValue == effortRawValue }) else {
                    return cell
                }
                configuration.text = effort.displayName
                cell.accessoryType = effort == currentEffort ? .checkmark : .none
            }
            cell.contentConfiguration = configuration
            return cell

        case .thinkingToggle(let inherited):
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: SettingsToggleCell.reuseIdentifier,
                for: indexPath
            ) as? SettingsToggleCell else {
                return UITableViewCell()
            }
            let currentSelection = inherited ? (inheritedState ?? .empty) : state
            guard let selectedProvider = providerRecord(for: currentSelection),
                  let selectedModel = selectedModelRecord(for: selectedProvider, selection: currentSelection) else {
                return cell
            }
            let selectedModelRecordID = selectedModel.id
            let capabilities = resolveModelProfile(for: selectedProvider, modelID: selectedModelRecordID)
            let isOn = resolvedThinkingEnabled(
                for: selectedProvider,
                modelID: selectedModelRecordID,
                thinkingEnabled: currentSelection.selectedThinkingEnabled
            )
            let canInteract = !inherited && capabilities.thinkingCanDisable
            cell.configure(
                title: capabilities.thinkingCanDisable
                    ? String(localized: "chat.menu.thinking")
                    : String(localized: "model_config.thinking_required"),
                isOn: isOn
            ) { [weak self] value in
                guard let self else { return }
                guard !inherited else { return }
                guard value != isOn else { return }
                self.applyThinkingEnabled(value, for: selectedProvider, modelID: selectedModelRecordID)
                self.notifySelectionChanged()
            }
            if var config = cell.contentConfiguration as? UIListContentConfiguration {
                config.textProperties.color = inherited ? .tertiaryLabel : .label
                cell.contentConfiguration = config
            }
            cell.isUserInteractionEnabled = canInteract
            return cell

        case .manageUseDefault:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectModelConfigCell", for: indexPath)
            var configuration = cell.defaultContentConfiguration()
            configuration.text = String(localized: "project_settings.chat.tool_permission.use_default")
            configuration.secondaryText = nil
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.accessoryType = .none
            return cell

        case .manageProviders:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectModelConfigCell", for: indexPath)
            var configuration = cell.defaultContentConfiguration()
            configuration.text = String(localized: "settings.providers.title")
            configuration.secondaryText = String(
                localized: "chat.model_selection.manage_provider",
                defaultValue: "Fix provider credentials or add providers."
            )
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.accessoryType = .disclosureIndicator
            return cell

        case .manageRefreshModels(let isRefreshing):
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectModelConfigCell", for: indexPath)
            var configuration = cell.defaultContentConfiguration()
            configuration.text = isRefreshing
                ? String(localized: "model_config.manage.refreshing_models")
                : String(localized: "model_config.manage.refresh_models")
            configuration.secondaryText = String(localized: "model_config.manage.refresh_models_subtitle")
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.accessoryType = .none
            return cell

        case .manageAddCustomModel:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectModelConfigCell", for: indexPath)
            var configuration = cell.defaultContentConfiguration()
            configuration.text = String(localized: "model_config.manage.add_custom_model")
            configuration.secondaryText = String(localized: "model_config.manage.add_custom_model_subtitle")
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }

    // MARK: - Snapshot

    private func buildSnapshot() -> NSDiffableDataSourceSnapshot<ModelConfigSectionID, ModelConfigItemID> {
        var snapshot = NSDiffableDataSourceSnapshot<ModelConfigSectionID, ModelConfigItemID>()

        // Inherit section
        if hasInheritedSelectionSource {
            snapshot.appendSections([.inherit])
            snapshot.appendItems([.inheritToggle], toSection: .inherit)
        }

        // Provider section
        snapshot.appendSections([.provider])
        if isFollowingParent {
            let inherited = inheritedState ?? .empty
            let providerID = trimmedProviderID(in: inherited)
            snapshot.appendItems([.provider(id: providerID, inherited: true)], toSection: .provider)
        } else {
            snapshot.appendItems(providers.map { .provider(id: $0.id, inherited: false) }, toSection: .provider)
        }

        // Model section
        snapshot.appendSections([.model])
        if isFollowingParent {
            let inherited = inheritedState ?? .empty
            let modelRecordID = trimmedModelRecordID(in: inherited)
            snapshot.appendItems([.model(id: modelRecordID, inherited: true)], toSection: .model)
        } else if let provider = selectedProviderRecord() {
            let models = availableModels(for: provider)
            snapshot.appendItems(models.map { .model(id: $0.id, inherited: false) }, toSection: .model)
        }

        // Parameter section
        snapshot.appendSections([.parameter])
        let currentSelection = isFollowingParent ? (inheritedState ?? .empty) : state
        if let selectedProvider = providerRecord(for: currentSelection),
           let selectedModel = selectedModelRecord(for: selectedProvider, selection: currentSelection) {
            switch selectedProvider.kind {
            case .openAICompatible:
                if isFollowingParent {
                    let effort = resolvedReasoningEffort(
                        for: selectedProvider,
                        modelID: selectedModel.id,
                        reasoningEffort: currentSelection.selectedReasoningEffort
                    )
                    if reasoningProfile(for: selectedProvider, modelID: selectedModel.id) != nil {
                        snapshot.appendItems([.reasoningEffort(effort.rawValue, inherited: true)], toSection: .parameter)
                    }
                } else if let profile = reasoningProfile(for: selectedProvider, modelID: selectedModel.id) {
                    snapshot.appendItems(
                        profile.supported.map { .reasoningEffort($0.rawValue, inherited: false) },
                        toSection: .parameter
                    )
                }
            case .anthropic, .googleGemini:
                if resolveModelProfile(for: selectedProvider, modelID: selectedModel.id).thinkingSupported {
                    snapshot.appendItems([.thinkingToggle(inherited: isFollowingParent)], toSection: .parameter)
                }
            }
        }

        // Manage section
        snapshot.appendSections([.manage])
        if !isFollowingParent {
            var manageItems: [ModelConfigItemID] = []
            if showsResetToDefaults && !hasInheritedSelectionSource {
                manageItems.append(.manageUseDefault)
            }
            manageItems.append(.manageProviders)
            if selectedProviderRecord() != nil {
                manageItems.append(.manageRefreshModels(isRefreshing: isRefreshingModels))
                manageItems.append(.manageAddCustomModel)
            }
            snapshot.appendItems(manageItems, toSection: .manage)
        }

        return snapshot
    }

    private func applySnapshot(animatingDifferences: Bool = false) {
        var snapshot = buildSnapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        diffableDataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    // MARK: - Section Headers & Footers

    override func tableView(_ tableView: UITableView, titleForHeaderInSection sectionIndex: Int) -> String? {
        guard let sectionID = diffableDataSource.sectionIdentifier(for: sectionIndex) else {
            return nil
        }
        switch sectionID {
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
        guard let sectionID = diffableDataSource.sectionIdentifier(for: sectionIndex) else {
            return nil
        }
        switch sectionID {
        case .model:
            if isFollowingParent { return nil }
            let models = providerRecord(for: state).flatMap { availableModels(for: $0) } ?? []
            return models.isEmpty ? nil : String(localized: "model_config.section.model.footer")
        default:
            return nil
        }
    }

    // MARK: - Selection

    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath) else {
            return nil
        }
        switch itemID {
        case .inheritToggle, .thinkingToggle:
            return nil
        case .provider(_, let inherited), .model(_, let inherited), .reasoningEffort(_, let inherited):
            return inherited ? nil : indexPath
        case .manageUseDefault, .manageProviders, .manageRefreshModels, .manageAddCustomModel:
            return isFollowingParent ? nil : indexPath
        }
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath),
              case .model(let modelRecordID, false) = itemID,
              let selectedProvider = selectedProviderRecord()
        else { return nil }
        let models = availableModels(for: selectedProvider)
        guard let model = models.first(where: { $0.id == modelRecordID }) else { return nil }
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
        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath) else {
            return
        }
        switch itemID {
        case .inheritToggle, .thinkingToggle:
            return

        case .provider(_, true), .model(_, true), .reasoningEffort(_, true):
            return

        case .provider(let providerID, _):
            guard let selectedProvider = providers.first(where: { $0.id == providerID }) else {
                return
            }
            guard selectedProvider.id != state.selectedProviderID else {
                return
            }
            state.selectedProviderID = selectedProvider.id
            state.selectedModelRecordID = availableModels(for: selectedProvider).first?.id ?? ""
            state.selectedReasoningEffort = nil
            state.selectedThinkingEnabled = nil
            notifySelectionChanged()
            applySnapshot()

        case .model(let modelRecordID, _):
            guard let selectedProvider = selectedProviderRecord() else {
                return
            }
            guard modelRecordID.caseInsensitiveCompare(selectedModelRecordID(for: selectedProvider)) != .orderedSame else {
                return
            }
            state.selectedModelRecordID = modelRecordID
            state.selectedReasoningEffort = nil
            state.selectedThinkingEnabled = nil
            notifySelectionChanged()
            applySnapshot()

        case .reasoningEffort(let effortRawValue, _):
            guard let selectedProvider = selectedProviderRecord(),
                  let selectedModel = selectedModelRecord(for: selectedProvider),
                  let profile = reasoningProfile(for: selectedProvider, modelID: selectedModel.id),
                  let selectedEffort = profile.supported.first(where: { $0.rawValue == effortRawValue })
            else {
                return
            }
            guard selectedEffort != resolvedReasoningEffort(
                for: selectedProvider,
                modelID: selectedModel.id,
                reasoningEffort: state.selectedReasoningEffort
            ) else {
                return
            }
            applyReasoningEffort(selectedEffort, for: selectedProvider, modelID: selectedModel.id)
            notifySelectionChanged()
            applySnapshot()

        case .manageUseDefault:
            guard let resetState = onResetToDefaults?() else {
                return
            }
            state = resetState
            showsResetToDefaults = false
            isFollowingParent = hasInheritedSelectionSource
            refreshNavigationTitle()
            applySnapshot()

        case .manageProviders:
            let controller = ManageProvidersViewController()
            navigationController?.pushViewController(controller, animated: true)

        case .manageRefreshModels:
            guard !isRefreshingModels, let selectedProvider = selectedProviderRecord() else {
                return
            }
            refreshOfficialModels(for: selectedProvider)

        case .manageAddCustomModel:
            guard let selectedProvider = selectedProviderRecord() else {
                return
            }
            presentModelEditor(provider: selectedProvider, existingModel: nil)
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
            applySnapshot()
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
        applySnapshot()
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
        applySnapshot()
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
        applySnapshot()
        modelRefreshTask?.cancel()
        modelRefreshTask = Task { [weak self] in
            guard let self else {
                return
            }
            defer {
                Task { @MainActor [weak self] in
                    self?.isRefreshingModels = false
                    self?.applySnapshot()
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
                self.applySnapshot()
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
