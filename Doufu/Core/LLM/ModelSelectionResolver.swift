//
//  ModelSelectionResolver.swift
//  Doufu
//

import Foundation

enum ModelSelectionSource: Equatable {
    case thread
    case project
    case app
}

enum ModelSelectionInvalidReason: Equatable {
    case providerMissing
    case credentialUnavailable
    case modelMissing
}

enum ModelSelectionResolutionState: Equatable {
    case missingSelection
    case valid
    case invalidOverride(ModelSelectionInvalidReason)
}

struct ModelSelectionResolution: Equatable {
    let hasUsableProviderEnvironment: Bool
    let state: ModelSelectionResolutionState
    let source: ModelSelectionSource?
    let providerID: String?
    let modelRecordID: String?
    let credential: ProjectChatService.ProviderCredential?
    let reasoningEffort: ProjectChatService.ReasoningEffort?
    let thinkingEnabled: Bool?

    var canSend: Bool {
        state == .valid && credential != nil
    }

    static func missingSelection(hasUsableProviderEnvironment: Bool) -> ModelSelectionResolution {
        ModelSelectionResolution(
            hasUsableProviderEnvironment: hasUsableProviderEnvironment,
            state: .missingSelection,
            source: nil,
            providerID: nil,
            modelRecordID: nil,
            credential: nil,
            reasoningEffort: nil,
            thinkingEnabled: nil
        )
    }

    static func == (lhs: ModelSelectionResolution, rhs: ModelSelectionResolution) -> Bool {
        lhs.hasUsableProviderEnvironment == rhs.hasUsableProviderEnvironment
            && lhs.state == rhs.state
            && lhs.source == rhs.source
            && lhs.providerID == rhs.providerID
            && lhs.modelRecordID == rhs.modelRecordID
            && lhs.credential?.providerID == rhs.credential?.providerID
            && lhs.credential?.baseURL == rhs.credential?.baseURL
            && lhs.credential?.modelID == rhs.credential?.modelID
            && lhs.reasoningEffort == rhs.reasoningEffort
            && lhs.thinkingEnabled == rhs.thinkingEnabled
    }
}

struct ModelSelectionResolver {

    static func resolve(
        appDefault: ModelSelection?,
        projectDefault: ModelSelection?,
        threadSelection: ModelSelection?,
        availableCredentials: [ProjectChatService.ProviderCredential],
        providerStore: LLMProviderSettingsStore
    ) -> ModelSelectionResolution {
        let hasUsableProviderEnvironment = !availableCredentials.isEmpty

        if let thread = threadSelection {
            return validateSelection(
                providerID: providerStore.providerID(forModelRecordID: thread.modelRecordID) ?? "",
                modelRecordID: thread.modelRecordID,
                reasoningEffort: thread.reasoningEffort,
                thinkingEnabled: thread.thinkingEnabled,
                source: .thread,
                availableCredentials: availableCredentials,
                providerStore: providerStore,
                hasUsableProviderEnvironment: hasUsableProviderEnvironment
            )
        }

        if let project = projectDefault {
            return validateSelection(
                providerID: providerStore.providerID(forModelRecordID: project.modelRecordID) ?? "",
                modelRecordID: project.modelRecordID,
                reasoningEffort: project.reasoningEffort,
                thinkingEnabled: project.thinkingEnabled,
                source: .project,
                availableCredentials: availableCredentials,
                providerStore: providerStore,
                hasUsableProviderEnvironment: hasUsableProviderEnvironment
            )
        }

        if let app = appDefault {
            return validateSelection(
                providerID: providerStore.providerID(forModelRecordID: app.modelRecordID) ?? "",
                modelRecordID: app.modelRecordID,
                reasoningEffort: app.reasoningEffort,
                thinkingEnabled: app.thinkingEnabled,
                source: .app,
                availableCredentials: availableCredentials,
                providerStore: providerStore,
                hasUsableProviderEnvironment: hasUsableProviderEnvironment
            )
        }

        return .missingSelection(hasUsableProviderEnvironment: hasUsableProviderEnvironment)
    }

    static func sanitizeSelection(
        providerID: String,
        modelRecordID: String,
        reasoningEffort: ProjectChatService.ReasoningEffort?,
        thinkingEnabled: Bool?,
        providerStore: LLMProviderSettingsStore,
        requiresExistingProviderAndModel: Bool
    ) -> ModelSelection? {
        let trimmedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelRecordID = modelRecordID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProviderID.isEmpty, !trimmedModelRecordID.isEmpty else {
            return nil
        }

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
            case .openAICompatible, .openRouter:
                if let profile = reasoningProfile(
                    providerID: trimmedProviderID,
                    providerKind: provider.kind,
                    modelID: trimmedModelRecordID,
                    providerStore: providerStore
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
                    modelID: trimmedModelRecordID,
                    providerStore: providerStore
                )
                if capabilities.thinkingSupported,
                   capabilities.thinkingCanDisable,
                   thinkingEnabled == false {
                    normalizedThinkingEnabled = false
                }
            }
        }

        return ModelSelection(
            modelRecordID: trimmedModelRecordID,
            reasoningEffort: normalizedReasoningEffort,
            thinkingEnabled: normalizedThinkingEnabled
        )
    }

    private static func validateSelection(
        providerID: String,
        modelRecordID: String,
        reasoningEffort: ProjectChatService.ReasoningEffort?,
        thinkingEnabled: Bool?,
        source: ModelSelectionSource,
        availableCredentials: [ProjectChatService.ProviderCredential],
        providerStore: LLMProviderSettingsStore,
        hasUsableProviderEnvironment: Bool
    ) -> ModelSelectionResolution {
        let trimmedProviderID = providerID.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedModelID = modelRecordID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedProviderID.isEmpty, !trimmedModelID.isEmpty else {
            return ModelSelectionResolution(
                hasUsableProviderEnvironment: hasUsableProviderEnvironment,
                state: .invalidOverride(.modelMissing),
                source: source,
                providerID: trimmedProviderID.isEmpty ? nil : trimmedProviderID,
                modelRecordID: trimmedModelID.isEmpty ? nil : trimmedModelID,
                credential: nil,
                reasoningEffort: nil,
                thinkingEnabled: nil
            )
        }

        guard providerStore.loadProvider(id: trimmedProviderID) != nil else {
            return ModelSelectionResolution(
                hasUsableProviderEnvironment: hasUsableProviderEnvironment,
                state: .invalidOverride(.providerMissing),
                source: source,
                providerID: trimmedProviderID,
                modelRecordID: trimmedModelID,
                credential: nil,
                reasoningEffort: nil,
                thinkingEnabled: nil
            )
        }

        guard let credential = availableCredentials.first(where: { $0.providerID == trimmedProviderID }) else {
            return ModelSelectionResolution(
                hasUsableProviderEnvironment: hasUsableProviderEnvironment,
                state: .invalidOverride(.credentialUnavailable),
                source: source,
                providerID: trimmedProviderID,
                modelRecordID: trimmedModelID,
                credential: nil,
                reasoningEffort: nil,
                thinkingEnabled: nil
            )
        }

        let modelExists = providerStore.availableModels(forProviderID: trimmedProviderID)
            .contains(where: { $0.normalizedID == trimmedModelID.lowercased() })
        guard modelExists else {
            return ModelSelectionResolution(
                hasUsableProviderEnvironment: hasUsableProviderEnvironment,
                state: .invalidOverride(.modelMissing),
                source: source,
                providerID: trimmedProviderID,
                modelRecordID: trimmedModelID,
                credential: nil,
                reasoningEffort: nil,
                thinkingEnabled: nil
            )
        }

        return ModelSelectionResolution(
            hasUsableProviderEnvironment: hasUsableProviderEnvironment,
            state: .valid,
            source: source,
            providerID: trimmedProviderID,
            modelRecordID: trimmedModelID,
            credential: credential,
            reasoningEffort: reasoningEffort,
            thinkingEnabled: thinkingEnabled
        )
    }

    private static func resolveModelProfile(
        providerID: String,
        providerKind: LLMProviderRecord.Kind,
        modelID: String,
        providerStore: LLMProviderSettingsStore
    ) -> ResolvedModelProfile {
        let record = providerStore.modelRecord(providerID: providerID, modelID: modelID)
            ?? providerStore.availableModels(forProviderID: providerID)
                .first(where: { $0.normalizedModelID == modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() })
        return LLMModelRegistry.resolve(
            providerKind: providerKind,
            modelID: record?.modelID ?? modelID,
            modelRecord: record
        )
    }

    private static func reasoningProfile(
        providerID: String,
        providerKind: LLMProviderRecord.Kind,
        modelID: String,
        providerStore: LLMProviderSettingsStore
    ) -> (supported: [ProjectChatService.ReasoningEffort], defaultEffort: ProjectChatService.ReasoningEffort)? {
        guard providerKind == .openAICompatible || providerKind == .openRouter else {
            return nil
        }
        let supported = resolveModelProfile(
            providerID: providerID,
            providerKind: providerKind,
            modelID: modelID,
            providerStore: providerStore
        ).reasoningEfforts
        guard !supported.isEmpty else {
            return nil
        }
        let defaultEffort: ProjectChatService.ReasoningEffort = supported.contains(.high)
            ? .high
            : (supported.first ?? .medium)
        return (supported: supported, defaultEffort: defaultEffort)
    }
}
