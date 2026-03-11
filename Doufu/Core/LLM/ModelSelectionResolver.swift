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
            credential: nil
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
    }
}

struct ModelSelectionResolver {

    static func resolve(
        appDefault: ModelSelection?,
        projectDefault: ModelSelection?,
        threadSelection: ThreadModelSelection?,
        availableCredentials: [ProjectChatService.ProviderCredential],
        providerStore: LLMProviderSettingsStore
    ) -> ModelSelectionResolution {
        let hasUsableProviderEnvironment = !availableCredentials.isEmpty

        if let thread = threadSelection {
            return validateSelection(
                providerID: thread.providerID,
                modelRecordID: thread.modelRecordID,
                source: .thread,
                availableCredentials: availableCredentials,
                providerStore: providerStore,
                hasUsableProviderEnvironment: hasUsableProviderEnvironment
            )
        }

        if let project = projectDefault {
            return validateSelection(
                providerID: project.providerID,
                modelRecordID: project.modelRecordID,
                source: .project,
                availableCredentials: availableCredentials,
                providerStore: providerStore,
                hasUsableProviderEnvironment: hasUsableProviderEnvironment
            )
        }

        if let app = appDefault {
            return validateSelection(
                providerID: app.providerID,
                modelRecordID: app.modelRecordID,
                source: .app,
                availableCredentials: availableCredentials,
                providerStore: providerStore,
                hasUsableProviderEnvironment: hasUsableProviderEnvironment
            )
        }

        return .missingSelection(hasUsableProviderEnvironment: hasUsableProviderEnvironment)
    }

    private static func validateSelection(
        providerID: String,
        modelRecordID: String,
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
                credential: nil
            )
        }

        guard providerStore.loadProvider(id: trimmedProviderID) != nil else {
            return ModelSelectionResolution(
                hasUsableProviderEnvironment: hasUsableProviderEnvironment,
                state: .invalidOverride(.providerMissing),
                source: source,
                providerID: trimmedProviderID,
                modelRecordID: trimmedModelID,
                credential: nil
            )
        }

        guard let credential = availableCredentials.first(where: { $0.providerID == trimmedProviderID }) else {
            return ModelSelectionResolution(
                hasUsableProviderEnvironment: hasUsableProviderEnvironment,
                state: .invalidOverride(.credentialUnavailable),
                source: source,
                providerID: trimmedProviderID,
                modelRecordID: trimmedModelID,
                credential: nil
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
                credential: nil
            )
        }

        return ModelSelectionResolution(
            hasUsableProviderEnvironment: hasUsableProviderEnvironment,
            state: .valid,
            source: source,
            providerID: trimmedProviderID,
            modelRecordID: trimmedModelID,
            credential: credential
        )
    }
}
