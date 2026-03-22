//
//  ModelConfigurationViewController.swift
//  Doufu
//
//  Extracted from ProjectChatViewController.swift
//

import UIKit

@MainActor
final class ModelConfigurationViewController: UIViewController, UITableViewDelegate {
    typealias SelectionState = ModelSelectionDraft

    var onSelectionStateChanged: ((SelectionState) -> SelectionApplyOutcome)?
    var onResetToDefaults: (() -> SelectionState)?

    // MARK: - State

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var providers: [LLMProviderRecord] = []
    private var availableProviderIDs: Set<String> = []
    private var state: SelectionState
    private let projectUsageIdentifier: String?
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
    private var modelFilterText: String = ""

    private let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    private var cellDataMap: [ModelConfigItemID: ModelConfigCellData] = [:]
    private var diffableDataSource: ModelConfigDataSource!

    init(
        initialState: SelectionState,
        showsResetToDefaults: Bool,
        projectUsageIdentifier: String?,
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
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .doufuBackground
        tableView.backgroundColor = .doufuBackground
        tableView.delegate = self
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProjectModelConfigCell")
        tableView.register(SettingsToggleCell.self, forCellReuseIdentifier: SettingsToggleCell.reuseIdentifier)
        tableView.register(ModelSearchBarCell.self, forCellReuseIdentifier: ModelSearchBarCell.reuseIdentifier)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
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
        diffableDataSource = ModelConfigDataSource(
            tableView: tableView
        ) { [weak self] tableView, indexPath, itemID in
            guard let self else { return UITableViewCell() }
            return self.cell(for: tableView, indexPath: indexPath, itemID: itemID)
        }
        diffableDataSource.headerProvider = { [weak self] sectionID in
            self?.sectionHeader(for: sectionID)
        }
        diffableDataSource.footerProvider = { [weak self] sectionID in
            self?.sectionFooter(for: sectionID)
        }
        diffableDataSource.defaultRowAnimation = .none
    }

    private func cell(
        for tableView: UITableView,
        indexPath: IndexPath,
        itemID: ModelConfigItemID
    ) -> UITableViewCell {
        switch itemID {
        case .modelSearchBar:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: ModelSearchBarCell.reuseIdentifier,
                for: indexPath
            ) as? ModelSearchBarCell else {
                return UITableViewCell()
            }
            if case .modelSearchBar(let filterText) = cellDataMap[itemID] {
                cell.configure(text: filterText)
            }
            cell.onTextChanged = { [weak self] text in
                guard let self else { return }
                self.modelFilterText = text
                self.applySnapshot()
            }
            return cell

        case .inheritToggle:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: SettingsToggleCell.reuseIdentifier,
                for: indexPath
            ) as? SettingsToggleCell else {
                return UITableViewCell()
            }
            let title: String
            let isOn: Bool
            if case .inheritToggle(let t, let on) = cellDataMap[itemID] {
                title = t
                isOn = on
            } else {
                title = ""
                isOn = false
            }
            cell.configure(title: title, isOn: isOn) { [weak self] value in
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

        case .provider:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectModelConfigCell", for: indexPath)
            var configuration = cell.defaultContentConfiguration()
            if case .provider(let title, let subtitle, let isSelected, let inherited) = cellDataMap[itemID] {
                configuration.text = title
                configuration.secondaryText = subtitle.isEmpty ? nil : subtitle
                if inherited {
                    configuration.textProperties.color = .tertiaryLabel
                    configuration.secondaryTextProperties.color = .tertiaryLabel
                } else {
                    configuration.secondaryTextProperties.color = .secondaryLabel
                }
                cell.accessoryType = isSelected ? .checkmark : .none
            } else {
                cell.accessoryType = .none
            }
            cell.contentConfiguration = configuration
            return cell

        case .model:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectModelConfigCell", for: indexPath)
            var configuration = cell.defaultContentConfiguration()
            if case .model(let displayName, let subtitle, let isSelected, let inherited) = cellDataMap[itemID] {
                configuration.text = displayName
                if inherited {
                    configuration.textProperties.color = .tertiaryLabel
                } else {
                    configuration.secondaryText = subtitle
                    configuration.secondaryTextProperties.color = .secondaryLabel
                }
                cell.accessoryType = isSelected ? .checkmark : .none
            } else {
                cell.accessoryType = .none
            }
            cell.contentConfiguration = configuration
            return cell

        case .reasoningEffort:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectModelConfigCell", for: indexPath)
            var configuration = cell.defaultContentConfiguration()
            if case .reasoningEffort(let displayName, let isSelected, let inherited) = cellDataMap[itemID] {
                configuration.text = displayName
                if inherited {
                    configuration.textProperties.color = .tertiaryLabel
                }
                cell.accessoryType = isSelected ? .checkmark : .none
            } else {
                cell.accessoryType = .none
            }
            cell.contentConfiguration = configuration
            return cell

        case .thinkingToggle:
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: SettingsToggleCell.reuseIdentifier,
                for: indexPath
            ) as? SettingsToggleCell else {
                return UITableViewCell()
            }
            let title: String
            let isOn: Bool
            let canInteract: Bool
            let inherited: Bool
            if case .thinkingToggle(let t, let on, let interact, let inh) = cellDataMap[itemID] {
                title = t
                isOn = on
                canInteract = interact
                inherited = inh
            } else {
                title = ""
                isOn = false
                canInteract = false
                inherited = true
            }
            cell.configure(title: title, isOn: isOn) { [weak self] value in
                guard let self else { return }
                guard !inherited else { return }
                guard value != isOn else { return }
                let currentSelection = self.state
                guard let selectedProvider = self.providerRecord(for: currentSelection),
                      let selectedModel = self.selectedModelRecord(for: selectedProvider) else {
                    return
                }
                self.applyThinkingEnabled(value, for: selectedProvider, modelID: selectedModel.id)
                self.notifySelectionChanged()
            }
            if var config = cell.contentConfiguration as? UIListContentConfiguration {
                config.textProperties.color = inherited ? .tertiaryLabel : .label
                cell.contentConfiguration = config
            }
            cell.isUserInteractionEnabled = canInteract
            return cell

        case .manageUseDefault, .manageProviders, .manageRefreshModels, .manageAddCustomModel:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectModelConfigCell", for: indexPath)
            var configuration = cell.defaultContentConfiguration()
            if case .manage(let title, let subtitle, let hasDisclosure) = cellDataMap[itemID] {
                configuration.text = title
                configuration.secondaryText = subtitle
                configuration.secondaryTextProperties.color = .secondaryLabel
                cell.accessoryType = hasDisclosure ? .disclosureIndicator : .none
            } else {
                cell.accessoryType = .none
            }
            cell.contentConfiguration = configuration
            return cell
        }
    }

    // MARK: - Snapshot

    private func buildSnapshot() -> NSDiffableDataSourceSnapshot<ModelConfigSectionID, ModelConfigItemID> {
        var snapshot = NSDiffableDataSourceSnapshot<ModelConfigSectionID, ModelConfigItemID>()
        var dataMap: [ModelConfigItemID: ModelConfigCellData] = [:]

        // Inherit section
        if hasInheritedSelectionSource {
            snapshot.appendSections([.inherit])
            let item = ModelConfigItemID.inheritToggle
            snapshot.appendItems([item], toSection: .inherit)
            dataMap[item] = .inheritToggle(
                title: inheritTitle ?? String(localized: "project_settings.chat.tool_permission.use_default"),
                isOn: isFollowingParent
            )
        }

        // Provider section
        snapshot.appendSections([.provider])
        if isFollowingParent {
            let inherited = inheritedState ?? .empty
            let providerID = trimmedProviderID(in: inherited)
            let item = ModelConfigItemID.provider(id: providerID, inherited: true)
            snapshot.appendItems([item], toSection: .provider)
            let provider = providers.first(where: { $0.id == providerID })
            let title: String
            let subtitle: String
            if let provider {
                title = providerTitle(for: provider)
                subtitle = provider.kind.displayName
            } else if !providerID.isEmpty {
                title = providerID
                subtitle = String(
                    localized: "chat.model_selection.invalid.generic",
                    defaultValue: "Invalid Model Selection"
                )
            } else {
                title = String(localized: "chat.model_selection.missing.short", defaultValue: "Missing Model Selection")
                subtitle = ""
            }
            dataMap[item] = .provider(
                title: title,
                subtitle: subtitle,
                isSelected: false,
                inherited: true
            )
        } else {
            for provider in providers {
                let item = ModelConfigItemID.provider(id: provider.id, inherited: false)
                snapshot.appendItems([item], toSection: .provider)
                dataMap[item] = .provider(
                    title: providerTitle(for: provider),
                    subtitle: providerSubtitle(for: provider),
                    isSelected: provider.id == state.selectedProviderID,
                    inherited: false
                )
            }
        }

        // Model section
        snapshot.appendSections([.model])
        if isFollowingParent {
            let inherited = inheritedState ?? .empty
            let modelRecordID = trimmedModelRecordID(in: inherited)
            let item = ModelConfigItemID.model(id: modelRecordID, inherited: true)
            snapshot.appendItems([item], toSection: .model)
            let provider = providerRecord(for: inherited)
            let model = provider.flatMap { p in
                availableModels(for: p).first(where: { $0.normalizedID == modelRecordID.lowercased() })
            }
            dataMap[item] = .model(
                displayName: model?.effectiveDisplayName ?? (modelRecordID.isEmpty
                    ? String(localized: "chat.model_selection.missing.short", defaultValue: "Missing Model Selection")
                    : modelRecordID),
                subtitle: "",
                isSelected: false,
                inherited: true
            )
        } else if let provider = selectedProviderRecord() {
            let allModels = availableModels(for: provider)
            if allModels.count >= 10 {
                let searchItem = ModelConfigItemID.modelSearchBar
                snapshot.appendItems([searchItem], toSection: .model)
                dataMap[searchItem] = .modelSearchBar(filterText: modelFilterText)
            }
            let models: [LLMProviderModelRecord]
            if modelFilterText.isEmpty {
                models = allModels
            } else {
                let query = modelFilterText.lowercased()
                models = allModels.filter {
                    $0.effectiveDisplayName.lowercased().contains(query)
                        || $0.modelID.lowercased().contains(query)
                }
            }
            let currentModelRecordID = selectedModelRecordID(for: provider)
            for model in models {
                let item = ModelConfigItemID.model(id: model.id, inherited: false)
                snapshot.appendItems([item], toSection: .model)
                let modelID = model.modelID
                let usageText = usedTokenCountText(
                    modelTokenUsage(providerID: provider.id, modelID: modelID)
                )
                let sourceText: String
                switch model.source {
                case .official:
                    sourceText = String(localized: "model_config.source.official")
                case .custom:
                    sourceText = String(localized: "model_config.source.custom")
                }
                dataMap[item] = .model(
                    displayName: model.effectiveDisplayName,
                    subtitle: sourceText + " · " + usageText,
                    isSelected: model.id.caseInsensitiveCompare(currentModelRecordID) == .orderedSame,
                    inherited: false
                )
            }
        }

        // Parameter section
        snapshot.appendSections([.parameter])
        let currentSelection = isFollowingParent ? (inheritedState ?? .empty) : state
        if let selectedProvider = providerRecord(for: currentSelection),
           let selectedModel = selectedModelRecord(for: selectedProvider, selection: currentSelection) {
            switch selectedProvider.kind {
            case .openAIResponses, .openAIChatCompletions, .openRouter:
                let currentEffort = resolvedReasoningEffort(
                    for: selectedProvider,
                    modelID: selectedModel.id,
                    reasoningEffort: currentSelection.selectedReasoningEffort
                )
                if isFollowingParent {
                    if reasoningProfile(for: selectedProvider, modelID: selectedModel.id) != nil {
                        let item = ModelConfigItemID.reasoningEffort(currentEffort.rawValue, inherited: true)
                        snapshot.appendItems([item], toSection: .parameter)
                        dataMap[item] = .reasoningEffort(
                            displayName: currentEffort.displayName,
                            isSelected: false,
                            inherited: true
                        )
                    }
                } else if let profile = reasoningProfile(for: selectedProvider, modelID: selectedModel.id) {
                    for effort in profile.supported {
                        let item = ModelConfigItemID.reasoningEffort(effort.rawValue, inherited: false)
                        snapshot.appendItems([item], toSection: .parameter)
                        dataMap[item] = .reasoningEffort(
                            displayName: effort.displayName,
                            isSelected: effort == currentEffort,
                            inherited: false
                        )
                    }
                }
            case .anthropic, .googleGemini, .xiaomiMiMo:
                let capabilities = resolveModelProfile(for: selectedProvider, modelID: selectedModel.id)
                if capabilities.thinkingSupported {
                    let item = ModelConfigItemID.thinkingToggle(inherited: isFollowingParent)
                    snapshot.appendItems([item], toSection: .parameter)
                    let isOn = resolvedThinkingEnabled(
                        for: selectedProvider,
                        modelID: selectedModel.id,
                        thinkingEnabled: currentSelection.selectedThinkingEnabled
                    )
                    dataMap[item] = .thinkingToggle(
                        title: capabilities.thinkingCanDisable
                            ? String(localized: "chat.menu.thinking")
                            : String(localized: "model_config.thinking_required"),
                        isOn: isOn,
                        canInteract: !isFollowingParent && capabilities.thinkingCanDisable,
                        inherited: isFollowingParent
                    )
                }
            }
        }

        // Manage section
        snapshot.appendSections([.manage])
        if !isFollowingParent {
            if showsResetToDefaults && !hasInheritedSelectionSource {
                let item = ModelConfigItemID.manageUseDefault
                snapshot.appendItems([item], toSection: .manage)
                dataMap[item] = .manage(
                    title: String(localized: "project_settings.chat.tool_permission.use_default"),
                    subtitle: nil,
                    hasDisclosure: false
                )
            }
            let providersItem = ModelConfigItemID.manageProviders
            snapshot.appendItems([providersItem], toSection: .manage)
            dataMap[providersItem] = .manage(
                title: String(localized: "settings.providers.title"),
                subtitle: String(
                    localized: "chat.model_selection.manage_provider",
                    defaultValue: "Fix provider credentials or add providers."
                ),
                hasDisclosure: true
            )
            if selectedProviderRecord() != nil {
                let refreshItem = ModelConfigItemID.manageRefreshModels(isRefreshing: isRefreshingModels)
                snapshot.appendItems([refreshItem], toSection: .manage)
                dataMap[refreshItem] = .manage(
                    title: isRefreshingModels
                        ? String(localized: "model_config.manage.refreshing_models")
                        : String(localized: "model_config.manage.refresh_models"),
                    subtitle: String(localized: "model_config.manage.refresh_models_subtitle"),
                    hasDisclosure: false
                )
                let addItem = ModelConfigItemID.manageAddCustomModel
                snapshot.appendItems([addItem], toSection: .manage)
                dataMap[addItem] = .manage(
                    title: String(localized: "model_config.manage.add_custom_model"),
                    subtitle: String(localized: "model_config.manage.add_custom_model_subtitle"),
                    hasDisclosure: true
                )
            }
        }

        cellDataMap = dataMap
        return snapshot
    }

    private func applySnapshot(animatingDifferences: Bool = false) {
        var snapshot = buildSnapshot()
        let existing = Set(diffableDataSource.snapshot().itemIdentifiers)
        let staleItems = snapshot.itemIdentifiers.filter { existing.contains($0) }
        if !staleItems.isEmpty {
            snapshot.reloadItems(staleItems)
        }
        diffableDataSource.apply(snapshot, animatingDifferences: animatingDifferences)
    }

    // MARK: - Section Headers & Footers

    private func sectionHeader(for sectionID: ModelConfigSectionID) -> String? {
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
            case .openAIResponses, .openAIChatCompletions, .openRouter:
                return String(localized: "chat.menu.reasoning")
            case .anthropic, .googleGemini, .xiaomiMiMo:
                return String(localized: "chat.menu.thinking")
            }
        case .manage:
            if isFollowingParent { return nil }
            return String(localized: "model_config.section.manage_models")
        }
    }

    private func sectionFooter(for sectionID: ModelConfigSectionID) -> String? {
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

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath) else {
            return nil
        }
        switch itemID {
        case .inheritToggle, .thinkingToggle, .modelSearchBar:
            return nil
        case .provider(_, let inherited), .model(_, let inherited), .reasoningEffort(_, let inherited):
            return inherited ? nil : indexPath
        case .manageUseDefault, .manageProviders, .manageRefreshModels, .manageAddCustomModel:
            return isFollowingParent ? nil : indexPath
        }
    }

    func tableView(
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

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath) else {
            return
        }
        switch itemID {
        case .inheritToggle, .thinkingToggle, .modelSearchBar:
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
            modelFilterText = ""
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
        guard provider.kind == .openAIResponses || provider.kind == .openAIChatCompletions || provider.kind == .openRouter else {
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

// MARK: - DataSource (header/footer support)

private final class ModelConfigDataSource: UITableViewDiffableDataSource<ModelConfigSectionID, ModelConfigItemID> {
    var headerProvider: ((ModelConfigSectionID) -> String?)?
    var footerProvider: ((ModelConfigSectionID) -> String?)?

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let sectionID = sectionIdentifier(for: section) else { return nil }
        return headerProvider?(sectionID) ?? nil
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let sectionID = sectionIdentifier(for: section) else { return nil }
        return footerProvider?(sectionID) ?? nil
    }
}
