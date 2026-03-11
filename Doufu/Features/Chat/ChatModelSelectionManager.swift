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
    let hasThreadOverride: Bool
}

@MainActor
final class ChatModelSelectionManager {

    weak var delegate: ChatModelSelectionManagerDelegate?

    private(set) var availableProviderCredentials: [ProjectChatService.ProviderCredential] = []
    private(set) var resolution = ModelSelectionResolution.missingSelection(hasUsableProviderEnvironment: false)

    let providerStore: LLMProviderSettingsStore
    let modelDiscoveryService: LLMProviderModelDiscoveryService

    private let projectID: String
    private let currentThreadIDProvider: () -> String?
    var dataService: ChatDataService?

    private var modelRefreshTask: Task<Void, Never>?
    private var projectDefault: ModelSelection?
    private var threadOverride: ThreadModelSelection?

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
        modelDiscoveryService: LLMProviderModelDiscoveryService? = nil
    ) {
        self.projectID = projectID
        self.currentThreadIDProvider = currentThreadIDProvider
        self.providerStore = providerStore ?? .shared
        self.modelDiscoveryService = modelDiscoveryService ?? LLMProviderModelDiscoveryService()
    }

    func cancelRefreshTask() {
        modelRefreshTask?.cancel()
    }

    func resetToDefaults() {
        applyThreadOverride(nil, persist: true)
    }

    func reloadModelSelectionContext() async {
        projectDefault = await dataService?.loadProjectModelSelection()
        if let threadID = currentThreadIDProvider() {
            let loadedThreadOverride = await dataService?.loadThreadModelSelection(threadID: threadID)
            let normalizedThreadOverride = normalizePersistedThreadOverride(loadedThreadOverride)
            threadOverride = normalizedThreadOverride
            if loadedThreadOverride != normalizedThreadOverride {
                persistThreadOverride(normalizedThreadOverride, threadID: threadID)
            }
        } else {
            threadOverride = nil
        }
        resolveAndApply()
    }

    func restoreFromThreadModelSelection(_ selection: ThreadModelSelection?) {
        let normalizedSelection = normalizePersistedThreadOverride(selection)
        let didChange = normalizedSelection != selection
        threadOverride = normalizedSelection
        if didChange, let threadID = currentThreadIDProvider() {
            persistThreadOverride(normalizedSelection, threadID: threadID)
        }
        resolveAndApply(triggerModelRefresh: false)
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
            switch resolution.source {
            case .project:
                return String(
                    localized: "chat.model_selection.source.project",
                    defaultValue: "Using Project Default"
                )
            case .app:
                return String(
                    localized: "chat.model_selection.source.app",
                    defaultValue: "Using App Default"
                )
            case .thread, .none:
                return nil
            }
        case .missingSelection:
            return String(
                localized: "chat.model_selection.missing.short",
                defaultValue: "Missing Model Selection"
            )
        case .invalidOverride:
            return invalidStatusTitle(for: resolution.source)
        }
    }

    func providerMenuTitle(for credential: ProjectChatService.ProviderCredential) -> String {
        let normalizedLabel = credential.providerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedLabel.isEmpty ? credential.providerKind.displayName : normalizedLabel
    }

    func persistCurrentThreadModelSelection() {
        guard let snapshot = buildCurrentThreadModelSelection() else { return }
        dataService?.persistModelSelection(snapshot.selection, threadID: snapshot.threadID)
    }

    func persistCurrentThreadModelSelectionAsync() async {
        guard let snapshot = buildCurrentThreadModelSelection() else { return }
        await dataService?.persistModelSelectionAsync(snapshot.selection, threadID: snapshot.threadID)
    }

    var selectionSnapshot: ModelConfigurationViewController.SelectionState {
        if let threadOverride {
            return ModelConfigurationViewController.SelectionState(
                selectedProviderID: draftProviderID(for: threadOverride.providerID) ?? "",
                selectedModelRecordID: threadOverride.modelRecordID,
                selectedReasoningEffort: threadOverride.reasoningEffort,
                selectedThinkingEnabled: threadOverride.thinkingEnabled
            )
        }

        let providerID = draftProviderID(for: resolution.providerID)
        let modelRecordID: String = {
            guard let providerID else { return "" }
            if let currentProviderID = resolution.providerID,
               currentProviderID == providerID,
               let resolutionModelRecordID = resolution.modelRecordID {
                return resolutionModelRecordID
            }
            return availableModelID(forProviderID: providerID) ?? ""
        }()

        return ModelConfigurationViewController.SelectionState(
            selectedProviderID: providerID ?? "",
            selectedModelRecordID: modelRecordID,
            selectedReasoningEffort: nil,
            selectedThinkingEnabled: nil
        )
    }

    @discardableResult
    func applySelectionState(_ state: ModelConfigurationViewController.SelectionState) -> SelectionApplyOutcome {
        let normalizedSelection = normalizeDraftState(state)
        let hasThreadOverride = applyThreadOverride(normalizedSelection, persist: true)
        return SelectionApplyOutcome(hasThreadOverride: hasThreadOverride)
    }

    func resolveProviderCredentials() -> [ProjectChatService.ProviderCredential] {
        ProviderCredentialResolver.resolveAvailableCredentials(providerStore: providerStore)
    }

    func refreshWithResolvedCredentials(_ credentials: [ProjectChatService.ProviderCredential]) {
        availableProviderCredentials = credentials
        resolution = ModelSelectionResolver.resolve(
            appDefault: providerStore.loadDefaultModelSelection(),
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
            appDefault: providerStore.loadDefaultModelSelection(),
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
        if providerStore.loadDefaultModelSelection()?.providerID == providerID {
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
        guard let threadOverride,
              resolution.source == .thread,
              threadOverride.providerID == providerID,
              normalizedModelID(threadOverride.modelRecordID) == normalizedModelID(modelID),
              let reasoningEffort = threadOverride.reasoningEffort,
              profile.supported.contains(reasoningEffort)
        else {
            return profile.defaultEffort
        }
        return reasoningEffort
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
        guard let threadOverride,
              resolution.source == .thread,
              threadOverride.providerID == providerCredential.providerID,
              normalizedModelID(threadOverride.modelRecordID) == normalizedModelID(modelID),
              let thinkingEnabled = threadOverride.thinkingEnabled
        else {
            return true
        }
        return thinkingEnabled
    }

    private func buildCurrentThreadModelSelection() -> (threadID: String, selection: ThreadModelSelection)? {
        guard let threadOverride else { return nil }
        guard let threadID = currentThreadIDProvider() else { return nil }
        return (threadID, threadOverride)
    }

    private func persistThreadOverride(_ selection: ThreadModelSelection?, threadID: String) {
        if let selection {
            dataService?.persistModelSelection(selection, threadID: threadID)
        } else {
            dataService?.removeThreadModelSelection(threadID: threadID)
        }
    }

    @discardableResult
    private func applyThreadOverride(_ selection: ThreadModelSelection?, persist: Bool) -> Bool {
        threadOverride = selection
        resolveAndApply(triggerModelRefresh: false)
        if persist, let threadID = currentThreadIDProvider() {
            persistThreadOverride(selection, threadID: threadID)
        }
        return selection != nil
    }

    private func normalizePersistedThreadOverride(_ selection: ThreadModelSelection?) -> ThreadModelSelection? {
        guard let selection else { return nil }
        return sanitizedThreadOverride(
            providerID: selection.providerID,
            modelRecordID: selection.modelRecordID,
            reasoningEffort: selection.reasoningEffort,
            thinkingEnabled: selection.thinkingEnabled,
            requiresExistingProviderAndModel: false
        )
    }

    private func normalizeDraftState(
        _ state: ModelConfigurationViewController.SelectionState
    ) -> ThreadModelSelection? {
        sanitizedThreadOverride(
            providerID: state.selectedProviderID,
            modelRecordID: state.selectedModelRecordID,
            reasoningEffort: state.selectedReasoningEffort,
            thinkingEnabled: state.selectedThinkingEnabled,
            requiresExistingProviderAndModel: true
        )
    }

    private func sanitizedThreadOverride(
        providerID: String,
        modelRecordID: String,
        reasoningEffort: ProjectChatService.ReasoningEffort?,
        thinkingEnabled: Bool?,
        requiresExistingProviderAndModel: Bool
    ) -> ThreadModelSelection? {
        let trimmedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelRecordID = modelRecordID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProviderID.isEmpty, !trimmedModelRecordID.isEmpty else { return nil }

        let provider = providerStore.loadProvider(id: trimmedProviderID)
        let modelExists = providerStore.availableModels(forProviderID: trimmedProviderID)
            .contains(where: { $0.normalizedID == trimmedModelRecordID.lowercased() })

        if requiresExistingProviderAndModel, (provider == nil || !modelExists) {
            return nil
        }

        var normalizedReasoningEffort: ProjectChatService.ReasoningEffort?
        var normalizedThinkingEnabled: Bool?

        if let provider, modelExists {
            switch provider.kind {
            case .openAICompatible:
                if let profile = reasoningProfile(
                    forModelID: trimmedModelRecordID,
                    providerID: trimmedProviderID,
                    providerKind: provider.kind
                ),
                   let reasoningEffort,
                   profile.supported.contains(reasoningEffort),
                   reasoningEffort != profile.defaultEffort {
                    normalizedReasoningEffort = reasoningEffort
                }
            case .anthropic, .googleGemini:
                let capabilities = resolveModelProfile(
                    providerID: trimmedProviderID,
                    providerKind: provider.kind,
                    modelID: trimmedModelRecordID
                )
                if capabilities.thinkingSupported,
                   capabilities.thinkingCanDisable,
                   thinkingEnabled == false {
                    normalizedThinkingEnabled = false
                }
            }
        }

        let normalizedSelection = ThreadModelSelection(
            providerID: trimmedProviderID,
            modelRecordID: trimmedModelRecordID,
            reasoningEffort: normalizedReasoningEffort,
            thinkingEnabled: normalizedThinkingEnabled
        )

        return normalizedSelection
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

    private func draftProviderID(for preferredProviderID: String?) -> String? {
        let providers = providerStore.loadProviders()
        if let preferredProviderID,
           providers.contains(where: { $0.id == preferredProviderID }) {
            return preferredProviderID
        }
        return providers.first?.id
    }

    private func availableModelID(forProviderID providerID: String) -> String? {
        providerStore.availableModels(forProviderID: providerID).first?.id
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
