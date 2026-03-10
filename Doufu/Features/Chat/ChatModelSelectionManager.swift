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
final class ChatModelSelectionManager {

    weak var delegate: ChatModelSelectionManagerDelegate?

    var availableProviderCredentials: [ProjectChatService.ProviderCredential] = []
    var providerCredential: ProjectChatService.ProviderCredential?
    var selectedProviderID: String?
    var selectedModelID: String?
    var selectedModelIDByProviderID: [String: String] = [:]
    var selectedReasoningEffortsByModelID: [String: ProjectChatService.ReasoningEffort] = [:]
    var selectedAnthropicThinkingEnabledByModelID: [String: Bool] = [:]
    var selectedGeminiThinkingEnabledByModelID: [String: Bool] = [:]

    private var modelRefreshTask: Task<Void, Never>?

    let providerStore: LLMProviderSettingsStore
    let modelDiscoveryService: LLMProviderModelDiscoveryService

    private let projectID: String
    private let currentThreadIDProvider: () -> String?
    var dataService: ChatDataService?
    private var cachedProjectModelSelection: ModelSelection?

    /// Tracks whether the current thread has an explicit user-chosen model selection.
    /// When `false`, `persistCurrentThreadModelSelection` is a no-op so that
    /// inherited Project/App defaults are not silently solidified into thread-level data.
    private(set) var hasExplicitThreadSelection = false

    init(
        projectID: String,
        currentThreadIDProvider: @escaping () -> String?,
        providerStore: LLMProviderSettingsStore = .shared,
        modelDiscoveryService: LLMProviderModelDiscoveryService = LLMProviderModelDiscoveryService()
    ) {
        self.projectID = projectID
        self.currentThreadIDProvider = currentThreadIDProvider
        self.providerStore = providerStore
        self.modelDiscoveryService = modelDiscoveryService
    }

    func cancelRefreshTask() {
        modelRefreshTask?.cancel()
    }

    /// Reset all thread-specific model state and re-apply project/app defaults.
    func resetToDefaults() {
        hasExplicitThreadSelection = false
        selectedModelIDByProviderID = [:]
        selectedReasoningEffortsByModelID = [:]
        selectedAnthropicThinkingEnabledByModelID = [:]
        selectedGeminiThinkingEnabledByModelID = [:]
        selectedProviderID = nil
        selectedModelID = nil
        providerCredential = nil
        configureProvider()
    }

    /// Pre-load project-level model selection from the data store.
    /// Must be called (and awaited) before `configureProvider()` to populate `cachedProjectModelSelection`.
    func loadProjectModelSelection() async {
        cachedProjectModelSelection = await dataService?.loadProjectModelSelection()
    }

    /// Reload the cached project model selection and re-apply defaults if the
    /// current thread has no explicit override.  Call this when returning from
    /// Project Settings so that a changed Project default takes effect immediately.
    func refreshProjectModelSelectionIfNeeded() async {
        let previous = cachedProjectModelSelection
        cachedProjectModelSelection = await dataService?.loadProjectModelSelection()
        guard previous != cachedProjectModelSelection, !hasExplicitThreadSelection else { return }
        configureProvider()
    }

    // MARK: - Provider Resolution

    func configureProvider() {
        do {
            if
                let currentProviderID = providerCredential?.providerID,
                let currentModelID = selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines),
                !currentModelID.isEmpty
            {
                selectedModelIDByProviderID[currentProviderID] = currentModelID
            }

            availableProviderCredentials = try resolveProviderCredentials()

            let preferredProviderID = selectedProviderID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let credential: ProjectChatService.ProviderCredential
            if let found = availableProviderCredentials.first(where: { $0.providerID == preferredProviderID }), !preferredProviderID.isEmpty {
                credential = found
            } else if let resolved = resolveProjectOrAppDefault() {
                credential = resolved.credential
                selectedModelIDByProviderID[resolved.credential.providerID] = resolved.modelRecordID
            } else {
                // No project or app default set — leave unselected so the user picks explicitly
                providerCredential = nil
                selectedProviderID = nil
                selectedModelID = nil
                delegate?.modelSelectionDidChange()
                refreshOfficialModels()
                return
            }

            providerCredential = credential
            selectedProviderID = credential.providerID
            let providerSelectedModel = selectedModelIDByProviderID[credential.providerID]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if providerSelectedModel.isEmpty {
                let resolvedModel = resolvedModelID(for: credential)
                selectedModelID = resolvedModel.isEmpty ? nil : resolvedModel
                if resolvedModel.isEmpty {
                    selectedModelIDByProviderID.removeValue(forKey: credential.providerID)
                } else {
                    selectedModelIDByProviderID[credential.providerID] = resolvedModel
                }
            } else {
                selectedModelID = providerSelectedModel
            }

            delegate?.modelSelectionDidChange()
            refreshOfficialModels()
        } catch {
            print("[Doufu ChatModelSelection] configureProvider failed: \(error.localizedDescription)")
            availableProviderCredentials = []
            providerCredential = nil
            selectedProviderID = nil
            delegate?.modelSelectionDidChange()
        }
    }

    /// Resolves the best default credential + model from project or app settings.
    /// Pure query — does **not** mutate any state.
    func resolveProjectOrAppDefault() -> (credential: ProjectChatService.ProviderCredential, modelRecordID: String)? {
        if let projectSelection = cachedProjectModelSelection,
           let credential = availableProviderCredentials.first(where: { $0.providerID == projectSelection.providerID }),
           modelRecordExists(providerID: credential.providerID, modelRecordID: projectSelection.modelRecordID) {
            return (credential, projectSelection.modelRecordID)
        }
        if let appDefault = providerStore.loadDefaultModelSelection(),
           let credential = availableProviderCredentials.first(where: { $0.providerID == appDefault.providerID }),
           modelRecordExists(providerID: credential.providerID, modelRecordID: appDefault.modelRecordID) {
            return (credential, appDefault.modelRecordID)
        }
        return nil
    }

    func modelRecordExists(providerID: String, modelRecordID: String) -> Bool {
        let trimmed = modelRecordID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return providerStore.availableModels(forProviderID: providerID)
            .contains(where: { $0.normalizedID == trimmed.lowercased() })
    }

    func refreshOfficialModels() {
        let providers = providerStore.loadProviders()
        modelRefreshTask?.cancel()
        modelRefreshTask = Task { [weak self] in
            guard let self else { return }
            for provider in providers {
                if Task.isCancelled { return }
                let token = (try? self.providerStore.loadBearerToken(for: provider))?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !token.isEmpty else { continue }

                do {
                    let models = try await self.modelDiscoveryService.fetchModels(for: provider, bearerToken: token)
                    _ = try self.providerStore.replaceOfficialModels(providerID: provider.id, models: models)
                    if self.providerCredential?.providerID == provider.id {
                        if let base = self.providerCredential {
                            self.providerCredential = self.runtimeCredential(from: base)
                        }
                        self.delegate?.modelSelectionDidChange()
                    }
                } catch {
                    print("[Doufu ModelDiscovery] failed to refresh models for provider=\(provider.id) error=\(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Model Resolution

    func availableModelRecords(for credential: ProjectChatService.ProviderCredential) -> [LLMProviderModelRecord] {
        return providerStore.loadProvider(id: credential.providerID)?.availableModels ?? []
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

    func resolvedModelID(for credential: ProjectChatService.ProviderCredential) -> String {
        if let remembered = selectedModelIDByProviderID[credential.providerID]?
            .trimmingCharacters(in: .whitespacesAndNewlines),
           !remembered.isEmpty {
            return remembered
        }
        if providerCredential?.providerID == credential.providerID,
           let currentSelection = selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !currentSelection.isEmpty {
            return currentSelection
        }
        if let projectSelection = cachedProjectModelSelection,
           projectSelection.providerID == credential.providerID,
           modelRecordExists(providerID: credential.providerID, modelRecordID: projectSelection.modelRecordID) {
            return projectSelection.modelRecordID
        }
        if let appDefault = providerStore.loadDefaultModelSelection(),
           appDefault.providerID == credential.providerID,
           modelRecordExists(providerID: credential.providerID, modelRecordID: appDefault.modelRecordID) {
            return appDefault.modelRecordID
        }
        return ""
    }

    func resolvedModelRecord(for credential: ProjectChatService.ProviderCredential) -> LLMProviderModelRecord? {
        let selectedRecordID = resolvedModelID(for: credential)
        guard !selectedRecordID.isEmpty else { return nil }
        return availableModelRecords(for: credential).first(where: { $0.normalizedID == selectedRecordID.lowercased() })
    }

    func resolvedRequestModelID(for credential: ProjectChatService.ProviderCredential) -> String {
        resolvedModelRecord(for: credential)?.modelID ?? ""
    }

    func normalizedModelID(_ modelID: String) -> String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    func currentProviderKind() -> LLMProviderRecord.Kind? {
        guard let credential = providerCredential else { return nil }
        return providerStore.loadProvider(id: credential.providerID)?.kind ?? credential.providerKind
    }

    // MARK: - Selection Operations

    func switchProvider(to providerID: String) {
        guard let credential = availableProviderCredentials.first(where: { $0.providerID == providerID }) else {
            return
        }
        if let currentProviderID = providerCredential?.providerID,
           let currentModel = selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !currentModel.isEmpty {
            selectedModelIDByProviderID[currentProviderID] = currentModel
        }

        providerCredential = credential
        selectedProviderID = credential.providerID

        let providerModel = resolvedModelID(for: credential)
        if providerModel.isEmpty {
            selectedModelID = nil
            selectedModelIDByProviderID.removeValue(forKey: credential.providerID)
        } else {
            selectedModelID = providerModel
            selectedModelIDByProviderID[credential.providerID] = providerModel
        }
        delegate?.modelSelectionDidChange()
    }

    func selectProviderModel(
        providerCredential: ProjectChatService.ProviderCredential,
        modelID: String
    ) {
        hasExplicitThreadSelection = true
        switchProvider(to: providerCredential.providerID)
        selectedModelID = modelID
        selectedModelIDByProviderID[providerCredential.providerID] = modelID

        let providerKind = providerStore.loadProvider(id: providerCredential.providerID)?.kind ?? providerCredential.providerKind
        let normalizedModel = normalizedModelID(modelID)
        let capabilities = resolveModelProfile(
            providerID: providerCredential.providerID,
            providerKind: providerKind,
            modelID: modelID
        )

        switch providerKind {
        case .openAICompatible:
            if let profile = reasoningProfile(
                forModelID: modelID,
                providerID: providerCredential.providerID,
                providerKind: providerKind
            ) {
                if let selected = selectedReasoningEffortsByModelID[normalizedModel], profile.supported.contains(selected) {
                    selectedReasoningEffortsByModelID[normalizedModel] = selected
                } else {
                    selectedReasoningEffortsByModelID[normalizedModel] = profile.defaultEffort
                }
            } else {
                selectedReasoningEffortsByModelID.removeValue(forKey: normalizedModel)
            }
        case .anthropic:
            selectedReasoningEffortsByModelID.removeValue(forKey: normalizedModel)
            applyThinkingDefault(
                capabilities: capabilities,
                normalizedModel: normalizedModel,
                dict: &selectedAnthropicThinkingEnabledByModelID
            )
        case .googleGemini:
            selectedReasoningEffortsByModelID.removeValue(forKey: normalizedModel)
            applyThinkingDefault(
                capabilities: capabilities,
                normalizedModel: normalizedModel,
                dict: &selectedGeminiThinkingEnabledByModelID
            )
        }

        delegate?.modelSelectionDidChange()
        persistCurrentThreadModelSelection()
    }

    func resolvedReasoningEffort(
        forModelID modelID: String,
        providerID: String,
        providerKind: LLMProviderRecord.Kind
    ) -> ProjectChatService.ReasoningEffort {
        guard let profile = reasoningProfile(forModelID: modelID, providerID: providerID, providerKind: providerKind) else {
            return .high
        }
        let key = normalizedModelID(modelID)
        if let selected = selectedReasoningEffortsByModelID[key], profile.supported.contains(selected) {
            return selected
        }
        return profile.defaultEffort
    }

    func resolvedThinkingEnabled(
        providerCredential: ProjectChatService.ProviderCredential,
        modelID: String,
        thinkingEnabledByModelID: [String: Bool]
    ) -> Bool {
        let key = normalizedModelID(modelID)
        let capabilities = resolveModelProfile(
            providerID: providerCredential.providerID,
            providerKind: providerCredential.providerKind,
            modelID: modelID
        )
        guard capabilities.thinkingSupported else { return false }
        guard capabilities.thinkingCanDisable else { return true }
        return thinkingEnabledByModelID[key] ?? true
    }

    /// Sets thinking default for a model when first selected, without returning a value.
    private func applyThinkingDefault(
        capabilities: ResolvedModelProfile,
        normalizedModel: String,
        dict: inout [String: Bool]
    ) {
        if !capabilities.thinkingSupported {
            dict[normalizedModel] = false
        } else if !capabilities.thinkingCanDisable {
            dict[normalizedModel] = true
        } else if dict[normalizedModel] == nil {
            dict[normalizedModel] = true
        }
    }

    // MARK: - Runtime

    func executionOptions(for credential: ProjectChatService.ProviderCredential) -> ProjectChatService.ModelExecutionOptions {
        let providerKind = currentProviderKind() ?? credential.providerKind
        let selectionModelID = resolvedModelID(for: credential)
        let reasoningEffort = resolvedReasoningEffort(
            forModelID: selectionModelID,
            providerID: credential.providerID,
            providerKind: providerKind
        )
        let anthropicThinkingEnabled: Bool
        let geminiThinkingEnabled: Bool

        switch providerKind {
        case .openAICompatible:
            anthropicThinkingEnabled = true
            geminiThinkingEnabled = true
        case .anthropic:
            anthropicThinkingEnabled = resolvedThinkingEnabled(providerCredential: credential, modelID: selectionModelID, thinkingEnabledByModelID: selectedAnthropicThinkingEnabledByModelID)
            geminiThinkingEnabled = true
        case .googleGemini:
            anthropicThinkingEnabled = true
            geminiThinkingEnabled = resolvedThinkingEnabled(providerCredential: credential, modelID: selectionModelID, thinkingEnabledByModelID: selectedGeminiThinkingEnabledByModelID)
        }

        return ProjectChatService.ModelExecutionOptions(
            reasoningEffort: reasoningEffort,
            anthropicThinkingEnabled: anthropicThinkingEnabled,
            geminiThinkingEnabled: geminiThinkingEnabled
        )
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

    func ensureModelSelectionForSend(
        providerCredential: ProjectChatService.ProviderCredential
    ) -> Bool {
        let resolvedModel = resolvedModelID(for: providerCredential)
        if !resolvedModel.isEmpty {
            selectedModelID = resolvedModel
            selectedModelIDByProviderID[providerCredential.providerID] = resolvedModel
            return true
        }
        return false
    }

    // MARK: - UI Titles

    func currentModelMenuTitle() -> String {
        guard let credential = providerCredential else {
            return String(localized: "chat.menu.model")
        }
        let selectedModel = resolvedModelRecord(for: credential)
        return selectedModel?.effectiveDisplayName ?? String(localized: "chat.menu.model")
    }

    func currentModelMenuButtonTitle() -> String {
        guard let credential = providerCredential, let providerKind = currentProviderKind() else {
            return currentModelMenuTitle()
        }
        let normalizedProviderLabel = credential.providerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerTitle = normalizedProviderLabel.isEmpty ? providerKind.displayName : normalizedProviderLabel
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
            let anthropicEnabled = resolvedThinkingEnabled(providerCredential: credential, modelID: selectionKey, thinkingEnabledByModelID: selectedAnthropicThinkingEnabledByModelID)
            let anthropicStatus = anthropicEnabled
                ? String(localized: "chat.thinking.enabled")
                : String(localized: "chat.thinking.disabled")
            return providerTitle + " · " + modelTitle + " · " + anthropicStatus
        case .googleGemini:
            guard capabilities.thinkingSupported else {
                return providerTitle + " · " + modelTitle
            }
            let geminiEnabled = resolvedThinkingEnabled(providerCredential: credential, modelID: selectionKey, thinkingEnabledByModelID: selectedGeminiThinkingEnabledByModelID)
            let geminiStatus = geminiEnabled
                ? String(localized: "chat.thinking.enabled")
                : String(localized: "chat.thinking.disabled")
            return providerTitle + " · " + modelTitle + " · " + geminiStatus
        }
    }

    func providerMenuTitle(for credential: ProjectChatService.ProviderCredential) -> String {
        let normalizedLabel = credential.providerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedLabel.isEmpty ? credential.providerKind.displayName : normalizedLabel
    }

    // MARK: - Persistence

    private func buildCurrentThreadModelSelection() -> (threadID: String, selection: ThreadModelSelection)? {
        guard hasExplicitThreadSelection else { return nil }
        guard let threadID = currentThreadIDProvider() else { return nil }
        guard let providerID = selectedProviderID, !providerID.isEmpty else { return nil }
        let selection = ThreadModelSelection(
            selectedProviderID: providerID,
            selectedModelIDByProviderID: selectedModelIDByProviderID,
            selectedReasoningEffortsByModelID: selectedReasoningEffortsByModelID.mapValues { $0.rawValue },
            selectedAnthropicThinkingEnabledByModelID: selectedAnthropicThinkingEnabledByModelID,
            selectedGeminiThinkingEnabledByModelID: selectedGeminiThinkingEnabledByModelID
        )
        return (threadID, selection)
    }

    func persistCurrentThreadModelSelection() {
        guard let snapshot = buildCurrentThreadModelSelection() else { return }
        dataService?.persistModelSelection(snapshot.selection, threadID: snapshot.threadID)
    }

    func persistCurrentThreadModelSelectionAsync() async {
        guard let snapshot = buildCurrentThreadModelSelection() else { return }
        await dataService?.persistModelSelectionAsync(snapshot.selection, threadID: snapshot.threadID)
    }

    /// Restore model selection state from a pre-loaded `ThreadModelSelection`.
    /// Used by `ChatThreadSessionManager` which loads the selection via `ChatDataService`.
    func restoreFromThreadModelSelection(_ selection: ThreadModelSelection) {
        guard let credential = availableProviderCredentials.first(where: { $0.providerID == selection.selectedProviderID }) else {
            // Provider no longer available — fall back to defaults
            resetToDefaults()
            return
        }
        let modelRecordID = selection.selectedModelIDByProviderID[selection.selectedProviderID] ?? ""
        let availableModels = providerStore.availableModels(forProviderID: credential.providerID)
        if !modelRecordID.isEmpty, !availableModels.contains(where: { $0.normalizedID == modelRecordID.lowercased() }) {
            // Model no longer available — fall back to defaults
            resetToDefaults()
            return
        }

        hasExplicitThreadSelection = true
        selectedProviderID = selection.selectedProviderID
        selectedModelIDByProviderID = selection.selectedModelIDByProviderID
        selectedReasoningEffortsByModelID = selection.selectedReasoningEffortsByModelID.compactMapValues {
            ProjectChatService.ReasoningEffort(rawValue: $0)
        }
        selectedAnthropicThinkingEnabledByModelID = selection.selectedAnthropicThinkingEnabledByModelID
        selectedGeminiThinkingEnabledByModelID = selection.selectedGeminiThinkingEnabledByModelID

        selectedModelID = modelRecordID.isEmpty ? nil : modelRecordID
        providerCredential = credential
        delegate?.modelSelectionDidChange()
    }

    // MARK: - Selection State (for ModelConfigurationViewController)

    var selectionSnapshot: ModelConfigurationViewController.SelectionState {
        ModelConfigurationViewController.SelectionState(
            selectedProviderID: selectedProviderID ?? "",
            selectedModelIDByProviderID: selectedModelIDByProviderID,
            selectedReasoningEffortsByModelID: selectedReasoningEffortsByModelID,
            selectedAnthropicThinkingEnabledByModelID: selectedAnthropicThinkingEnabledByModelID,
            selectedGeminiThinkingEnabledByModelID: selectedGeminiThinkingEnabledByModelID
        )
    }

    func applySelectionState(_ state: ModelConfigurationViewController.SelectionState) {
        hasExplicitThreadSelection = true
        selectedModelIDByProviderID = state.selectedModelIDByProviderID
        selectedReasoningEffortsByModelID = state.selectedReasoningEffortsByModelID
        selectedAnthropicThinkingEnabledByModelID = state.selectedAnthropicThinkingEnabledByModelID
        selectedGeminiThinkingEnabledByModelID = state.selectedGeminiThinkingEnabledByModelID
        selectedProviderID = state.selectedProviderID

        providerCredential = availableProviderCredentials.first(where: { $0.providerID == state.selectedProviderID })
        let selectedModel = state.selectedModelIDByProviderID[state.selectedProviderID]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        selectedModelID = selectedModel.isEmpty ? nil : selectedModel

        delegate?.modelSelectionDidChange()
        persistCurrentThreadModelSelection()
    }

    // MARK: - JWT Utilities

    func resolveProviderCredentials() throws -> [ProjectChatService.ProviderCredential] {
        var output: [ProjectChatService.ProviderCredential] = []
        let providers = providerStore.loadProviders()
        for provider in providers {
            guard let baseURL = URL(string: provider.effectiveBaseURLString) else {
                continue
            }
            let token = try providerStore.loadBearerToken(for: provider)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !token.isEmpty else {
                continue
            }

            let chatGPTAccountID = provider.chatGPTAccountID ?? extractChatGPTAccountID(fromJWT: token)

            output.append(ProjectChatService.ProviderCredential(
                providerID: provider.id,
                providerLabel: provider.label,
                providerKind: provider.kind,
                authMode: provider.authMode,
                modelID: "",
                baseURL: baseURL,
                bearerToken: token,
                chatGPTAccountID: chatGPTAccountID,
                profile: LLMModelRegistry.resolve(providerKind: provider.kind, modelID: "", modelRecord: nil)
            ))
        }

        if output.isEmpty {
            throw ChatProviderError.noAvailableProvider
        }

        return output
    }

    func extractChatGPTAccountID(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else { return nil }
        guard let payloadData = decodeBase64URL(String(parts[1])) else { return nil }
        guard let payloadObject = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] else { return nil }

        if let authClaims = payloadObject["https://api.openai.com/auth"] as? [String: Any],
           let accountID = normalizedString(from: authClaims["chatgpt_account_id"] ?? authClaims["account_id"]) {
            return accountID
        }

        return normalizedString(from: payloadObject["chatgpt_account_id"] ?? payloadObject["account_id"])
    }

    func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingLength = (4 - (base64.count % 4)) % 4
        if paddingLength > 0 {
            base64.append(String(repeating: "=", count: paddingLength))
        }
        return Data(base64Encoded: base64)
    }

    func normalizedString(from value: Any?) -> String? {
        guard let rawValue = value as? String else { return nil }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
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
