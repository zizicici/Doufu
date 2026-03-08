//
//  ProjectModelConfigurationViewController.swift
//  Doufu
//
//  Extracted from ProjectChatViewController.swift
//

import UIKit

@MainActor
final class ProjectModelConfigurationViewController: UITableViewController {
    struct SelectionState {
        var selectedProviderID: String
        var selectedModelIDByProviderID: [String: String]
        var selectedReasoningEffortsByModelID: [String: ProjectChatService.ReasoningEffort]
        var selectedAnthropicThinkingEnabledByModelID: [String: Bool]
        var selectedGeminiThinkingEnabledByModelID: [String: Bool]
    }

    var onSelectionStateChanged: ((SelectionState) -> Void)?

    private enum Section: Int, CaseIterable {
        case provider
        case model
        case parameter
        case manage
    }

    private enum ManageRow: Int, CaseIterable {
        case refreshOfficialModels
        case addCustomModel
    }

    private let providers: [ProjectChatService.ProviderCredential]
    private var state: SelectionState
    private let projectUsageIdentifier: String
    private let usageStore = LLMTokenUsageStore.shared
    private let providerStore = LLMProviderSettingsStore.shared
    private let modelDiscoveryService = LLMProviderModelDiscoveryService()
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
        providers: [ProjectChatService.ProviderCredential],
        initialState: SelectionState,
        projectUsageIdentifier: String
    ) {
        self.providers = providers
        state = initialState
        self.projectUsageIdentifier = projectUsageIdentifier
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refreshNavigationTitle()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProjectModelConfigCell")
        tableView.register(SettingsToggleCell.self, forCellReuseIdentifier: SettingsToggleCell.reuseIdentifier)
        reloadUsageData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadUsageData()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if view.window == nil {
            modelRefreshTask?.cancel()
        }
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else {
            return 0
        }
        switch section {
        case .provider:
            return providers.count
        case .model:
            guard let selectedProvider = selectedProviderCredential() else {
                return 0
            }
            return availableModels(for: selectedProvider).count
        case .parameter:
            guard let selectedProvider = selectedProviderCredential() else {
                return 0
            }
            let selectedModelRecordID = selectedModelRecordID(for: selectedProvider)
            guard !selectedModelRecordID.isEmpty else {
                return 0
            }
            switch selectedProvider.providerKind {
            case .openAICompatible:
                return reasoningProfile(for: selectedProvider, modelID: selectedModelRecordID)?
                    .supported.count ?? 0
            case .anthropic, .googleGemini:
                return modelCapabilities(for: selectedProvider, modelID: selectedModelRecordID).thinkingSupported ? 1 : 0
            }
        case .manage:
            guard selectedProviderCredential() != nil else {
                return 0
            }
            return ManageRow.allCases.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else {
            return nil
        }
        switch section {
        case .provider:
            return String(localized: "chat.menu.provider")
        case .model:
            return String(localized: "chat.menu.model")
        case .parameter:
            guard let selectedProvider = selectedProviderCredential() else {
                return nil
            }
            switch selectedProvider.providerKind {
            case .openAICompatible:
                return String(localized: "chat.menu.reasoning")
            case .anthropic, .googleGemini:
                return String(localized: "chat.menu.thinking")
            }
        case .manage:
            return "Manage Models"
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let section = Section(rawValue: indexPath.section) else {
            return UITableViewCell()
        }

        switch section {
        case .provider:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectModelConfigCell", for: indexPath)
            guard providers.indices.contains(indexPath.row) else {
                return cell
            }
            let provider = providers[indexPath.row]
            var configuration = cell.defaultContentConfiguration()
            configuration.text = providerTitle(for: provider)
            configuration.secondaryText = providerSubtitle(for: provider)
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.accessoryType = provider.providerID == state.selectedProviderID ? .checkmark : .none
            return cell

        case .model:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectModelConfigCell", for: indexPath)
            guard let selectedProvider = selectedProviderCredential() else {
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
                    providerID: selectedProvider.providerID,
                    modelID: modelID
                )
            )
            let sourceText: String
            switch model.source {
            case .official:
                sourceText = "Official"
            case .custom:
                sourceText = "Custom"
            }
            configuration.secondaryText = sourceText + " · " + usageText
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.accessoryType = model.id.caseInsensitiveCompare(selectedModelRecordID(for: selectedProvider)) == .orderedSame
                ? .checkmark
                : .none
            return cell

        case .parameter:
            guard let selectedProvider = selectedProviderCredential() else {
                return UITableViewCell()
            }
            let selectedModelRecordID = selectedModelRecordID(for: selectedProvider)
            guard !selectedModelRecordID.isEmpty else {
                return UITableViewCell()
            }
            switch selectedProvider.providerKind {
            case .openAICompatible:
                let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectModelConfigCell", for: indexPath)
                let profile = reasoningProfile(for: selectedProvider, modelID: selectedModelRecordID)
                let efforts = profile?.supported ?? []
                guard efforts.indices.contains(indexPath.row) else {
                    return cell
                }
                let effort = efforts[indexPath.row]
                var configuration = cell.defaultContentConfiguration()
                configuration.text = effort.displayName
                cell.contentConfiguration = configuration
                let currentEffort = selectedReasoningEffort(for: selectedProvider, modelID: selectedModelRecordID)
                cell.accessoryType = effort == currentEffort ? .checkmark : .none
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
                let capabilities = modelCapabilities(for: selectedProvider, modelID: selectedModelRecordID)
                let isOn: Bool
                switch selectedProvider.providerKind {
                case .anthropic:
                    isOn = selectedAnthropicThinkingEnabled(for: selectedProvider, modelID: selectedModelRecordID)
                case .googleGemini:
                    isOn = selectedGeminiThinkingEnabled(for: selectedProvider, modelID: selectedModelRecordID)
                case .openAICompatible:
                    isOn = true
                }
                cell.configure(
                    title: capabilities.thinkingCanDisable
                        ? String(localized: "chat.menu.thinking")
                        : "Thinking (required)",
                    isOn: isOn
                ) { [weak self] value in
                    guard let self else { return }
                    let key = self.normalizedModelID(selectedModelRecordID)
                    switch selectedProvider.providerKind {
                    case .anthropic:
                        self.state.selectedAnthropicThinkingEnabledByModelID[key] = value
                    case .googleGemini:
                        self.state.selectedGeminiThinkingEnabledByModelID[key] = value
                    case .openAICompatible:
                        break
                    }
                    self.notifySelectionChanged()
                }
                cell.isUserInteractionEnabled = capabilities.thinkingCanDisable
                cell.contentView.alpha = capabilities.thinkingCanDisable ? 1.0 : 0.72
                return cell
            }
        case .manage:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectModelConfigCell", for: indexPath)
            guard let row = ManageRow(rawValue: indexPath.row) else {
                return cell
            }
            var configuration = cell.defaultContentConfiguration()
            switch row {
            case .refreshOfficialModels:
                configuration.text = isRefreshingModels ? "Refreshing Official Models..." : "Refresh Official Models"
                configuration.secondaryText = "Pull the latest model list from the provider API."
                cell.accessoryType = .none
            case .addCustomModel:
                configuration.text = "Add Custom Model"
                configuration.secondaryText = "Register a model that is not returned by the provider API."
                cell.accessoryType = .disclosureIndicator
            }
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard let section = Section(rawValue: indexPath.section) else {
            return nil
        }
        switch section {
        case .provider, .model:
            return indexPath
        case .parameter:
            guard let selectedProvider = selectedProviderCredential() else {
                return nil
            }
            switch selectedProvider.providerKind {
            case .openAICompatible:
                return indexPath
            case .anthropic, .googleGemini:
                return nil
            }
        case .manage:
            return indexPath
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard let section = Section(rawValue: indexPath.section) else {
            return
        }
        switch section {
        case .provider:
            guard providers.indices.contains(indexPath.row) else {
                return
            }
            let selectedProvider = providers[indexPath.row]
            state.selectedProviderID = selectedProvider.providerID
            let selectedModelRecordID = selectedModelRecordID(for: selectedProvider)
            if selectedModelRecordID.isEmpty {
                state.selectedModelIDByProviderID.removeValue(forKey: selectedProvider.providerID)
            } else {
                state.selectedModelIDByProviderID[selectedProvider.providerID] = selectedModelRecordID
            }
            notifySelectionChanged()
            tableView.reloadData()

        case .model:
            guard let selectedProvider = selectedProviderCredential() else {
                return
            }
            let models = availableModels(for: selectedProvider)
            guard models.indices.contains(indexPath.row) else {
                return
            }
            let modelID = models[indexPath.row].id
            state.selectedModelIDByProviderID[selectedProvider.providerID] = modelID
            _ = try? providerStore.updateSelectedModelID(providerID: selectedProvider.providerID, modelID: modelID)
            if selectedProvider.providerKind == .openAICompatible {
                _ = selectedReasoningEffort(for: selectedProvider, modelID: modelID)
            }
            notifySelectionChanged()
            tableView.reloadData()

        case .parameter:
            guard let selectedProvider = selectedProviderCredential() else {
                return
            }
            let selectedModelRecordID = selectedModelRecordID(for: selectedProvider)
            switch selectedProvider.providerKind {
            case .openAICompatible:
                guard
                    let profile = reasoningProfile(for: selectedProvider, modelID: selectedModelRecordID),
                    profile.supported.indices.contains(indexPath.row)
                else {
                    return
                }
                let selectedEffort = profile.supported[indexPath.row]
                state.selectedReasoningEffortsByModelID[normalizedModelID(selectedModelRecordID)] = selectedEffort
                notifySelectionChanged()
                tableView.reloadSections(IndexSet(integer: Section.parameter.rawValue), with: .none)
            case .anthropic, .googleGemini:
                return
            }
        case .manage:
            guard
                let selectedProvider = selectedProviderCredential(),
                let row = ManageRow(rawValue: indexPath.row)
            else {
                return
            }
            switch row {
            case .refreshOfficialModels:
                refreshOfficialModels(for: selectedProvider)
            case .addCustomModel:
                presentModelEditor(provider: selectedProvider, existingModel: nil)
            }
        }
    }

    private func selectedProviderCredential() -> ProjectChatService.ProviderCredential? {
        if let credential = providers.first(where: { $0.providerID == state.selectedProviderID }) {
            return credential
        }
        return providers.first
    }

    private func selectedModelRecordID(for provider: ProjectChatService.ProviderCredential) -> String {
        let remembered = state.selectedModelIDByProviderID[provider.providerID]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !remembered.isEmpty {
            return remembered
        }
        if let providerRecord = providerStore.loadProvider(id: provider.providerID) {
            let selection = providerRecord.effectiveModelRecordID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !selection.isEmpty {
                return selection
            }
        }
        return availableModels(for: provider).first?.id ?? ""
    }

    private func selectedModelID(for provider: ProjectChatService.ProviderCredential) -> String {
        let selectedRecordID = selectedModelRecordID(for: provider)
        if let model = availableModels(for: provider).first(where: { $0.normalizedID == selectedRecordID.lowercased() }) {
            return model.modelID
        }
        let fallback = provider.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback
    }

    private func availableModels(for provider: ProjectChatService.ProviderCredential) -> [LLMProviderModelRecord] {
        providerStore.availableModels(forProviderID: provider.providerID)
    }

    private func providerTitle(for provider: ProjectChatService.ProviderCredential) -> String {
        let normalizedLabel = provider.providerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedLabel.isEmpty ? provider.providerKind.displayName : normalizedLabel
    }

    private func modelCapabilities(
        for provider: ProjectChatService.ProviderCredential,
        modelID: String
    ) -> LLMProviderModelCapabilities {
        if let record = providerStore.modelRecord(providerID: provider.providerID, modelID: modelID) {
            return record.capabilities
        }
        let normalized = normalizedModelID(modelID)
        if let record = availableModels(for: provider).first(where: { $0.normalizedModelID == normalized }) {
            return record.capabilities
        }
        return .defaults(for: provider.providerKind, modelID: modelID)
    }

    private func reasoningProfile(
        for provider: ProjectChatService.ProviderCredential,
        modelID: String
    ) -> (supported: [ProjectChatService.ReasoningEffort], defaultEffort: ProjectChatService.ReasoningEffort)? {
        guard provider.providerKind == .openAICompatible else {
            return nil
        }
        let supported = modelCapabilities(for: provider, modelID: modelID).reasoningEfforts
        guard !supported.isEmpty else {
            return nil
        }
        let defaultEffort: ProjectChatService.ReasoningEffort = supported.contains(.high)
            ? .high
            : (supported.first ?? .medium)
        return (supported: supported, defaultEffort: defaultEffort)
    }

    private func selectedReasoningEffort(
        for provider: ProjectChatService.ProviderCredential,
        modelID: String
    ) -> ProjectChatService.ReasoningEffort {
        guard let profile = reasoningProfile(for: provider, modelID: modelID) else {
            return .high
        }
        let key = normalizedModelID(modelID)
        if let selected = state.selectedReasoningEffortsByModelID[key], profile.supported.contains(selected) {
            return selected
        }
        state.selectedReasoningEffortsByModelID[key] = profile.defaultEffort
        return profile.defaultEffort
    }

    private func selectedAnthropicThinkingEnabled(
        for provider: ProjectChatService.ProviderCredential,
        modelID: String
    ) -> Bool {
        let key = normalizedModelID(modelID)
        let capabilities = modelCapabilities(for: provider, modelID: modelID)
        guard capabilities.thinkingSupported else {
            state.selectedAnthropicThinkingEnabledByModelID[key] = false
            return false
        }
        guard capabilities.thinkingCanDisable else {
            state.selectedAnthropicThinkingEnabledByModelID[key] = true
            return true
        }
        if let selected = state.selectedAnthropicThinkingEnabledByModelID[key] {
            return selected
        }
        state.selectedAnthropicThinkingEnabledByModelID[key] = true
        return true
    }

    private func selectedGeminiThinkingEnabled(
        for provider: ProjectChatService.ProviderCredential,
        modelID: String
    ) -> Bool {
        let key = normalizedModelID(modelID)
        let capabilities = modelCapabilities(for: provider, modelID: modelID)
        guard capabilities.thinkingSupported else {
            state.selectedGeminiThinkingEnabledByModelID[key] = false
            return false
        }
        guard capabilities.thinkingCanDisable else {
            state.selectedGeminiThinkingEnabledByModelID[key] = true
            return true
        }
        if let selected = state.selectedGeminiThinkingEnabledByModelID[key] {
            return selected
        }
        state.selectedGeminiThinkingEnabledByModelID[key] = true
        return true
    }

    private func normalizedModelID(_ modelID: String) -> String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
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

    private func providerSubtitle(for provider: ProjectChatService.ProviderCredential) -> String {
        let providerKindName = provider.providerKind.displayName
        let usageText = usedTokenCountText(providerTokenUsage(for: provider.providerID))
        return String(
            format: String(localized: "providers.usage.detail.section.model_format"),
            providerKindName,
            usageText
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

    private func refreshOfficialModels(for provider: ProjectChatService.ProviderCredential) {
        guard let providerRecord = providerStore.loadProvider(id: provider.providerID) else {
            return
        }

        isRefreshingModels = true
        tableView.reloadSections(IndexSet(integer: Section.manage.rawValue), with: .none)
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

            let token = (try? self.providerStore.loadBearerToken(for: providerRecord))?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !token.isEmpty else {
                return
            }

            do {
                let models = try await self.modelDiscoveryService.fetchModels(for: providerRecord, bearerToken: token)
                _ = try self.providerStore.replaceOfficialModels(providerID: providerRecord.id, models: models)
            } catch {
                let alert = UIAlertController(
                    title: "Refresh Failed",
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
                self.present(alert, animated: true)
            }
        }
    }

    private func presentModelEditor(
        provider: ProjectChatService.ProviderCredential,
        existingModel: LLMProviderModelRecord?
    ) {
        let controller = ProviderModelEditorViewController(
            provider: provider,
            existingModel: existingModel,
            selectedModelID: selectedModelRecordID(for: provider)
        )
        controller.onSave = { [weak self] payload in
            guard let self else {
                return
            }
            do {
                let updatedProvider = try self.providerStore.saveCustomModel(
                    providerID: provider.providerID,
                    modelID: payload.modelID,
                    displayName: payload.displayName,
                    capabilities: payload.capabilities,
                    shouldSelect: payload.shouldSelect
                )
                if payload.shouldSelect {
                    self.state.selectedModelIDByProviderID[provider.providerID] = updatedProvider.effectiveModelRecordID
                }
                self.notifySelectionChanged()
                self.tableView.reloadData()
            } catch {
                let alert = UIAlertController(
                    title: "Save Failed",
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
        refreshNavigationTitle()
        onSelectionStateChanged?(state)
    }

    private func refreshNavigationTitle() {
        guard let provider = selectedProviderCredential() else {
            title = String(localized: "chat.menu.model")
            return
        }
        let selectedRecordID = selectedModelRecordID(for: provider)
        let selectedTitle = availableModels(for: provider)
            .first(where: { $0.normalizedID == selectedRecordID.lowercased() })?
            .effectiveDisplayName ?? ""
        title = selectedTitle.isEmpty ? providerTitle(for: provider) : providerTitle(for: provider) + "-" + selectedTitle
    }
}
