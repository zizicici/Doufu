//
//  ChatModelSelectionManager.swift
//  Doufu
//

import Foundation

@MainActor
protocol ChatModelSelectionManagerDelegate: AnyObject {
    func modelSelectionDidChange()
}

@MainActor
struct SelectionApplyOutcome {
    let hasExplicitSelection: Bool
}

@MainActor
final class ChatModelSelectionManager {

    weak var delegate: ChatModelSelectionManagerDelegate?

    private(set) var availableProviderCredentials: [ProjectChatService.ProviderCredential] = []
    private(set) var resolution = ModelSelectionResolution.missingSelection(hasUsableProviderEnvironment: false)

    let providerStore: LLMProviderSettingsStore
    let modelDiscoveryService: LLMProviderModelDiscoveryService
    private let modelSelectionStore: ModelSelectionStateStore

    private let projectID: String
    private let currentThreadIDProvider: () -> String?

    private var modelRefreshTask: Task<Void, Never>?
    private var modelSelectionObserver: NSObjectProtocol?
    private var currentSelections = ModelSelectionStateStore.Snapshot()

    private var appDefault: ModelSelection? {
        currentSelections.appDefault
    }

    private var projectDefault: ModelSelection? {
        currentSelections.projectDefault
    }

    private var threadOverride: ModelSelection? {
        currentSelections.threadSelection
    }

    var providerCredential: ProjectChatService.ProviderCredential? {
        resolution.credential
    }

    var hasThreadOverride: Bool {
        threadOverride != nil
    }

    var canSend: Bool {
        resolution.canSend
    }

    var hasUsableProviderEnvironment: Bool {
        resolution.hasUsableProviderEnvironment
    }

    var hasConfiguredProviders: Bool {
        !providerStore.loadProviders().isEmpty
    }

    init(
        projectID: String,
        currentThreadIDProvider: @escaping () -> String?,
        providerStore: LLMProviderSettingsStore? = nil,
        modelDiscoveryService: LLMProviderModelDiscoveryService? = nil,
        modelSelectionStore: ModelSelectionStateStore? = nil
    ) {
        self.projectID = projectID
        self.currentThreadIDProvider = currentThreadIDProvider
        self.providerStore = providerStore ?? .shared
        self.modelDiscoveryService = modelDiscoveryService ?? LLMProviderModelDiscoveryService()
        self.modelSelectionStore = modelSelectionStore ?? .shared
        observeModelSelectionState()
    }

    deinit {
        if let modelSelectionObserver {
            NotificationCenter.default.removeObserver(modelSelectionObserver)
        }
    }

    func cancelRefreshTask() {
        modelRefreshTask?.cancel()
    }

    func resetToDefaults() {
        applyThreadOverride(nil, persist: true)
    }

    func reloadModelSelectionContext(triggerModelRefresh: Bool = true) {
        let threadID = currentThreadIDProvider()
        var snapshot = modelSelectionStore.loadSnapshot(projectID: projectID, threadID: threadID)

        if let threadID {
            let loadedThreadOverride = snapshot.threadSelection
            let normalizedThreadOverride = normalizePersistedThreadOverride(loadedThreadOverride)
            snapshot.threadSelection = normalizedThreadOverride
            if loadedThreadOverride != normalizedThreadOverride {
                modelSelectionStore.setThreadSelection(
                    normalizedThreadOverride,
                    projectID: projectID,
                    threadID: threadID
                )
            }
        } else {
            snapshot.threadSelection = nil
        }

        currentSelections = snapshot
        resolveAndApply(triggerModelRefresh: triggerModelRefresh)
    }

    func refreshOfficialModels() {
        let providers = providerStore.loadProviders()
        modelRefreshTask?.cancel()
        modelRefreshTask = Task { [weak self] in
            guard let self else { return }
            var anyModelListChanged = false
            for provider in providers {
                if Task.isCancelled { return }
                let token = (try? self.providerStore.loadBearerToken(for: provider))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !token.isEmpty else { continue }

                do {
                    let models = try await self.modelDiscoveryService.fetchModels(for: provider, bearerToken: token)
                    _ = try self.providerStore.replaceOfficialModels(providerID: provider.id, models: models)
                    if self.shouldReResolveAfterRefreshingModels(for: provider.id) {
                        anyModelListChanged = true
                    }
                } catch {
                    print("[Doufu ModelDiscovery] failed to refresh models for provider=\(provider.id) error=\(error.localizedDescription)")
                }
            }

            if anyModelListChanged {
                self.resolveAndApply(triggerModelRefresh: false)
            }
        }
    }

    func availableModelRecords(for credential: ProjectChatService.ProviderCredential) -> [LLMProviderModelRecord] {
        providerStore.loadProvider(id: credential.providerID)?.availableModels ?? []
    }

    func resolveModelProfile(
        providerID: String,
        providerKind: LLMProviderRecord.Kind,
        modelID: String
    ) -> ResolvedModelProfile {
        let record = providerStore.modelRecord(providerID: providerID, modelID: modelID)
            ?? providerStore.availableModels(forProviderID: providerID)
                .first(where: { $0.normalizedModelID == normalizedModelID(modelID) })
        return LLMModelRegistry.resolve(
            providerKind: providerKind,
            modelID: record?.modelID ?? modelID,
            modelRecord: record
        )
    }

    func reasoningProfile(
        forModelID modelID: String,
        providerID: String,
        providerKind: LLMProviderRecord.Kind
    ) -> (supported: [ProjectChatService.ReasoningEffort], defaultEffort: ProjectChatService.ReasoningEffort)? {
        guard providerKind == .openAICompatible else { return nil }
        let profile = resolveModelProfile(providerID: providerID, providerKind: providerKind, modelID: modelID)
        let supported = profile.reasoningEfforts
        guard !supported.isEmpty else { return nil }
        let defaultEffort: ProjectChatService.ReasoningEffort
        if supported.contains(.high) {
            defaultEffort = .high
        } else {
            defaultEffort = supported.first ?? .medium
        }
        return (supported: supported, defaultEffort: defaultEffort)
    }

    func currentProviderKind() -> LLMProviderRecord.Kind? {
        if let providerID = resolution.providerID,
           let provider = providerStore.loadProvider(id: providerID) {
            return provider.kind
        }
        return resolution.credential?.providerKind
    }

    func resolvedModelRecord(for credential: ProjectChatService.ProviderCredential) -> LLMProviderModelRecord? {
        guard resolution.state == .valid, resolution.providerID == credential.providerID else {
            return nil
        }
        guard let selectedRecordID = resolution.modelRecordID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !selectedRecordID.isEmpty
        else {
            return nil
        }
        return availableModelRecords(for: credential).first(where: { $0.normalizedID == selectedRecordID.lowercased() })
    }

    func resolvedRequestModelID(for credential: ProjectChatService.ProviderCredential) -> String {
        resolvedModelRecord(for: credential)?.modelID ?? ""
    }

    func normalizedModelID(_ modelID: String) -> String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func executionOptions(for credential: ProjectChatService.ProviderCredential) -> ProjectChatService.ModelExecutionOptions {
        let providerKind = currentProviderKind() ?? credential.providerKind
        let selectionModelID = resolution.modelRecordID ?? ""
        let reasoningEffort = resolvedReasoningEffort(
            forModelID: selectionModelID,
            providerID: credential.providerID,
            providerKind: providerKind
        )
        let thinkingEnabled = resolvedThinkingEnabled(
            providerCredential: credential,
            modelID: selectionModelID
        )

        switch providerKind {
        case .openAICompatible:
            return ProjectChatService.ModelExecutionOptions(
                reasoningEffort: reasoningEffort,
                anthropicThinkingEnabled: true,
                geminiThinkingEnabled: true
            )
        case .anthropic:
            return ProjectChatService.ModelExecutionOptions(
                reasoningEffort: reasoningEffort,
                anthropicThinkingEnabled: thinkingEnabled,
                geminiThinkingEnabled: true
            )
        case .googleGemini:
            return ProjectChatService.ModelExecutionOptions(
                reasoningEffort: reasoningEffort,
                anthropicThinkingEnabled: true,
                geminiThinkingEnabled: thinkingEnabled
            )
        }
    }

    func runtimeCredential(from base: ProjectChatService.ProviderCredential) -> ProjectChatService.ProviderCredential {
        let normalizedSelectedModel = resolvedRequestModelID(for: base)
        guard !normalizedSelectedModel.isEmpty else {
            return base
        }
        let profile = resolveModelProfile(
            providerID: base.providerID,
            providerKind: base.providerKind,
            modelID: normalizedSelectedModel
        )
        return ProjectChatService.ProviderCredential(
            providerID: base.providerID,
            providerLabel: base.providerLabel,
            providerKind: base.providerKind,
            authMode: base.authMode,
            modelID: profile.modelID,
            baseURL: base.baseURL,
            bearerToken: base.bearerToken,
            chatGPTAccountID: base.chatGPTAccountID,
            profile: profile
        )
    }

    func sendBlockedMessage() -> String? {
        if !resolution.hasUsableProviderEnvironment {
            return ChatProviderError.noAvailableProvider.localizedDescription
        }

        switch resolution.state {
        case .valid:
            return nil
        case .missingSelection:
            return String(
                localized: "chat.model_selection.missing",
                defaultValue: "Missing Model Selection. Choose a model before sending."
            )
        case .invalidOverride:
            return String(
                format: invalidStatusTitle(for: resolution.source) + ". %@",
                String(
                    localized: "chat.model_selection.invalid.fix_hint",
                    defaultValue: "Open model settings to change the model or use the default."
                )
            )
        }
    }

    func currentModelMenuTitle() -> String {
        switch resolution.state {
        case .valid:
            guard let credential = providerCredential else {
                return String(localized: "chat.menu.model")
            }
            let selectedModel = resolvedModelRecord(for: credential)
            return selectedModel?.effectiveDisplayName ?? String(localized: "chat.menu.model")
        case .missingSelection:
            return String(localized: "chat.menu.model")
        case .invalidOverride:
            let modelID = resolution.modelRecordID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return modelID.isEmpty ? String(localized: "chat.menu.model") : modelID
        }
    }

    func currentModelMenuButtonTitle() -> String {
        let providerTitle = currentProviderDisplayTitle()
        switch resolution.state {
        case .missingSelection:
            return providerTitle.isEmpty ? String(localized: "chat.menu.model") : providerTitle + " · " + String(localized: "chat.menu.model")
        case .invalidOverride:
            let modelTitle = currentModelMenuTitle()
            guard !providerTitle.isEmpty else { return modelTitle }
            return providerTitle + " · " + modelTitle
        case .valid:
            guard let credential = providerCredential, let providerKind = currentProviderKind() else {
                return currentModelMenuTitle()
            }
            guard let selectedModel = resolvedModelRecord(for: credential) else {
                return providerTitle + " · " + String(localized: "chat.menu.model")
            }
            let modelTitle = selectedModel.effectiveDisplayName
            let capabilities = selectedModel.capabilities
            let selectionKey = selectedModel.id
            switch providerKind {
            case .openAICompatible:
                guard reasoningProfile(forModelID: selectionKey, providerID: credential.providerID, providerKind: providerKind) != nil else {
                    return providerTitle + " · " + modelTitle
                }
                let effort = resolvedReasoningEffort(
                    forModelID: selectionKey,
                    providerID: credential.providerID,
                    providerKind: providerKind
                )
                return providerTitle + " · " + modelTitle + " · " + effort.displayName
            case .anthropic:
                guard capabilities.thinkingSupported else {
                    return providerTitle + " · " + modelTitle
                }
                let anthropicEnabled = resolvedThinkingEnabled(providerCredential: credential, modelID: selectionKey)
                let anthropicStatus = anthropicEnabled
                    ? String(localized: "chat.thinking.enabled")
                    : String(localized: "chat.thinking.disabled")
                return providerTitle + " · " + modelTitle + " · " + anthropicStatus
            case .googleGemini:
                guard capabilities.thinkingSupported else {
                    return providerTitle + " · " + modelTitle
                }
                let geminiEnabled = resolvedThinkingEnabled(providerCredential: credential, modelID: selectionKey)
                let geminiStatus = geminiEnabled
                    ? String(localized: "chat.thinking.enabled")
                    : String(localized: "chat.thinking.disabled")
                return providerTitle + " · " + modelTitle + " · " + geminiStatus
            }
        }
    }

    func currentStatusPrompt() -> String? {
        switch resolution.state {
        case .valid:
            guard let summary = selectionPromptSummary() else {
                return nil
            }
            switch resolution.source {
            case .project, .app:
                return summary + " " + String(
                    localized: "chat.model_selection.default_suffix",
                    defaultValue: "(default)"
                )
            case .thread, .none:
                return summary
            }
        case .missingSelection:
            return String(
                localized: "settings.default_model.not_set",
                defaultValue: "Not Set"
            )
        case .invalidOverride:
            return String(
                localized: "chat.model_selection.invalid.short",
                defaultValue: "Invalid"
            )
        }
    }

    private func selectionPromptSummary() -> String? {
        let providerTitle = promptProviderTitle()
        let modelTitle = promptModelTitle()
        switch (providerTitle.isEmpty, modelTitle.isEmpty) {
        case (false, false):
            return providerTitle + " · " + modelTitle
        case (false, true):
            return providerTitle
        case (true, false):
            return modelTitle
        case (true, true):
            return nil
        }
    }

    private func promptProviderTitle() -> String {
        if let credential = providerCredential {
            return providerMenuTitle(for: credential)
        }
        guard let providerID = resolution.providerID?.trimmingCharacters(in: .whitespacesAndNewlines),
              !providerID.isEmpty
        else {
            return ""
        }
        if let provider = providerStore.loadProvider(id: providerID) {
            let label = provider.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return label.isEmpty ? provider.kind.displayName : label
        }
        return providerID
    }

    private func promptModelTitle() -> String {
        let rawModelID = resolution.modelRecordID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        switch resolution.state {
        case .valid:
            guard let credential = providerCredential else {
                return rawModelID
            }
            return resolvedModelRecord(for: credential)?.effectiveDisplayName ?? rawModelID
        case .missingSelection:
            return rawModelID
        case .invalidOverride:
            return rawModelID
        }
    }

    func providerMenuTitle(for credential: ProjectChatService.ProviderCredential) -> String {
        let normalizedLabel = credential.providerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedLabel.isEmpty ? credential.providerKind.displayName : normalizedLabel
    }

    func persistCurrentModelSelection() {
        guard let snapshot = buildCurrentModelSelection() else { return }
        modelSelectionStore.setThreadSelection(
            snapshot.selection,
            projectID: projectID,
            threadID: snapshot.threadID
        )
    }

    func persistCurrentModelSelectionAsync() async {
        guard let snapshot = buildCurrentModelSelection() else { return }
        await modelSelectionStore.setThreadSelectionAsync(
            snapshot.selection,
            projectID: projectID,
            threadID: snapshot.threadID
        )
    }

    /// The resolved state ignoring the thread override — represents what
    /// the thread would inherit from project/app defaults.
    var inheritedSnapshot: ModelConfigurationViewController.SelectionState {
        let inheritedResolution = ModelSelectionResolver.resolve(
            appDefault: appDefault,
            projectDefault: projectDefault,
            threadSelection: nil,
            availableCredentials: availableProviderCredentials,
            providerStore: providerStore
        )
        return ModelConfigurationViewController.SelectionState(
            selectedProviderID: inheritedResolution.providerID ?? "",
            selectedModelRecordID: inheritedResolution.modelRecordID ?? "",
            selectedReasoningEffort: inheritedResolution.reasoningEffort,
            selectedThinkingEnabled: inheritedResolution.thinkingEnabled
        )
    }

    var selectionSnapshot: ModelConfigurationViewController.SelectionState {
        if let threadOverride {
            return ModelConfigurationViewController.SelectionState(
                selectedProviderID: threadOverride.providerID,
                selectedModelRecordID: threadOverride.modelRecordID,
                selectedReasoningEffort: threadOverride.reasoningEffort,
                selectedThinkingEnabled: threadOverride.thinkingEnabled
            )
        }

        return ModelConfigurationViewController.SelectionState(
            selectedProviderID: resolution.providerID ?? "",
            selectedModelRecordID: resolution.modelRecordID ?? "",
            selectedReasoningEffort: resolution.reasoningEffort,
            selectedThinkingEnabled: resolution.thinkingEnabled
        )
    }

    @discardableResult
    func applySelectionState(_ state: ModelConfigurationViewController.SelectionState) -> SelectionApplyOutcome {
        let normalizedSelection = normalizeDraftState(state)
        let hasThreadOverride = applyThreadOverride(normalizedSelection, persist: true)
        return SelectionApplyOutcome(hasExplicitSelection: hasThreadOverride)
    }

    func resolveProviderCredentials() -> [ProjectChatService.ProviderCredential] {
        ProviderCredentialResolver.resolveAvailableCredentials(providerStore: providerStore)
    }

    func refreshWithResolvedCredentials(_ credentials: [ProjectChatService.ProviderCredential]) {
        availableProviderCredentials = credentials
        resolution = ModelSelectionResolver.resolve(
            appDefault: appDefault,
            projectDefault: projectDefault,
            threadSelection: threadOverride,
            availableCredentials: credentials,
            providerStore: providerStore
        )
        delegate?.modelSelectionDidChange()
    }

    private func resolveAndApply(triggerModelRefresh: Bool = true) {
        availableProviderCredentials = resolveProviderCredentials()
        resolution = ModelSelectionResolver.resolve(
            appDefault: appDefault,
            projectDefault: projectDefault,
            threadSelection: threadOverride,
            availableCredentials: availableProviderCredentials,
            providerStore: providerStore
        )
        delegate?.modelSelectionDidChange()
        if triggerModelRefresh {
            refreshOfficialModels()
        }
    }

    private func shouldReResolveAfterRefreshingModels(for providerID: String) -> Bool {
        if resolution.providerID == providerID {
            return true
        }
        if threadOverride?.providerID == providerID {
            return true
        }
        if projectDefault?.providerID == providerID {
            return true
        }
        if appDefault?.providerID == providerID {
            return true
        }
        return false
    }

    private func resolvedReasoningEffort(
        forModelID modelID: String,
        providerID: String,
        providerKind: LLMProviderRecord.Kind
    ) -> ProjectChatService.ReasoningEffort {
        guard let profile = reasoningProfile(forModelID: modelID, providerID: providerID, providerKind: providerKind) else {
            return .high
        }
        if let reasoningEffort = resolution.reasoningEffort,
           profile.supported.contains(reasoningEffort) {
            return reasoningEffort
        }
        return profile.defaultEffort
    }

    private func resolvedThinkingEnabled(
        providerCredential: ProjectChatService.ProviderCredential,
        modelID: String
    ) -> Bool {
        let capabilities = resolveModelProfile(
            providerID: providerCredential.providerID,
            providerKind: providerCredential.providerKind,
            modelID: modelID
        )
        guard capabilities.thinkingSupported else { return false }
        guard capabilities.thinkingCanDisable else { return true }
        if let thinkingEnabled = resolution.thinkingEnabled {
            return thinkingEnabled
        }
        return true
    }

    private func buildCurrentModelSelection() -> (threadID: String, selection: ModelSelection)? {
        guard let threadOverride else { return nil }
        guard let threadID = currentThreadIDProvider() else { return nil }
        return (threadID, threadOverride)
    }

    private func persistThreadOverride(_ selection: ModelSelection?, threadID: String) {
        modelSelectionStore.setThreadSelection(
            selection,
            projectID: projectID,
            threadID: threadID
        )
    }

    @discardableResult
    private func applyThreadOverride(_ selection: ModelSelection?, persist: Bool) -> Bool {
        currentSelections.threadSelection = selection
        resolveAndApply(triggerModelRefresh: false)
        if persist, let threadID = currentThreadIDProvider() {
            persistThreadOverride(selection, threadID: threadID)
        }
        return selection != nil
    }

    private func normalizePersistedThreadOverride(_ selection: ModelSelection?) -> ModelSelection? {
        guard let selection else { return nil }
        return ModelSelectionResolver.sanitizeSelection(
            providerID: selection.providerID,
            modelRecordID: selection.modelRecordID,
            reasoningEffort: selection.reasoningEffort,
            thinkingEnabled: selection.thinkingEnabled,
            providerStore: providerStore,
            requiresExistingProviderAndModel: false
        )
    }

    private func normalizeDraftState(
        _ state: ModelConfigurationViewController.SelectionState
    ) -> ModelSelection? {
        ModelSelectionResolver.sanitizeSelection(
            providerID: state.selectedProviderID,
            modelRecordID: state.selectedModelRecordID,
            reasoningEffort: state.selectedReasoningEffort,
            thinkingEnabled: state.selectedThinkingEnabled,
            providerStore: providerStore,
            requiresExistingProviderAndModel: true
        )
    }

    private func currentProviderDisplayTitle() -> String {
        if let credential = providerCredential {
            return providerMenuTitle(for: credential)
        }
        if let providerID = resolution.providerID,
           let provider = providerStore.loadProvider(id: providerID) {
            let label = provider.label.trimmingCharacters(in: .whitespacesAndNewlines)
            return label.isEmpty ? provider.kind.displayName : label
        }
        return ""
    }

    private func invalidStatusTitle(for source: ModelSelectionSource?) -> String {
        switch source {
        case .thread:
            return String(
                localized: "chat.model_selection.invalid.thread",
                defaultValue: "Invalid Thread Selection"
            )
        case .project:
            return String(
                localized: "chat.model_selection.invalid.project",
                defaultValue: "Invalid Project Default"
            )
        case .app:
            return String(
                localized: "chat.model_selection.invalid.app",
                defaultValue: "Invalid App Default"
            )
        case .none:
            return String(
                localized: "chat.model_selection.invalid.generic",
                defaultValue: "Invalid Model Selection"
            )
        }
    }

    private func observeModelSelectionState() {
        modelSelectionObserver = modelSelectionStore.addObserver { [weak self] change in
            guard let self else { return }
            self.handleModelSelectionStateChange(change)
        }
    }

    private func handleModelSelectionStateChange(_ change: ModelSelectionStateStore.Change) {
        guard isRelevantModelSelectionChange(change) else {
            return
        }
        Task { [weak self] in
            await self?.reloadModelSelectionContext(triggerModelRefresh: false)
        }
    }

    private func isRelevantModelSelectionChange(_ change: ModelSelectionStateStore.Change) -> Bool {
        switch change.scope {
        case .appDefault:
            return true
        case .projectDefault(let changedProjectID):
            return changedProjectID == projectID
        case .threadSelection(let changedProjectID, let changedThreadID):
            guard changedProjectID == projectID else {
                return false
            }
            return changedThreadID == currentThreadIDProvider()
        }
    }
}

enum ChatProviderError: LocalizedError {
    case noAvailableProvider
    case noThreadAvailable

    var errorDescription: String? {
        switch self {
        case .noAvailableProvider:
            return String(localized: "chat.error.no_provider")
        case .noThreadAvailable:
            return String(localized: "chat.error.no_thread")
        }
    }
}
