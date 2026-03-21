//
//  DefaultModelSelectionViewController.swift
//  Doufu
//

import UIKit

/// App-level default model selection (Settings → Default Model).
/// Embeds `ModelConfigurationViewController` for full provider/model/reasoning/thinking configuration.
@MainActor
final class DefaultModelSelectionViewController: UIViewController {

    private let providerStore = LLMProviderSettingsStore.shared
    private let modelSelectionStore = ModelSelectionStateStore.shared

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "settings.default_model.title")
        view.backgroundColor = .doufuBackground

        let initialState = buildSelectionState()
        let controller = ModelConfigurationViewController(
            initialState: initialState,
            showsResetToDefaults: modelSelectionStore.loadAppDefaultSelection() != nil,
            projectUsageIdentifier: nil
        )
        controller.onSelectionStateChanged = { [weak self] state in
            guard let self else { return SelectionApplyOutcome(hasExplicitSelection: false) }
            let selection = self.normalizedSelection(from: state)
            self.modelSelectionStore.setAppDefaultSelection(selection)
            self.refreshStatusPrompt(for: selection)
            return SelectionApplyOutcome(hasExplicitSelection: selection != nil)
        }
        controller.onResetToDefaults = { [weak self] in
            guard let self else { return initialState }
            self.modelSelectionStore.setAppDefaultSelection(nil)
            self.refreshStatusPrompt(for: nil)
            return self.buildSelectionState()
        }

        addChild(controller)
        view.addSubview(controller.view)
        controller.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            controller.view.topAnchor.constraint(equalTo: view.topAnchor),
            controller.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            controller.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            controller.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        controller.didMove(toParent: self)
        refreshStatusPrompt(for: modelSelectionStore.loadAppDefaultSelection())
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshStatusPrompt(for: modelSelectionStore.loadAppDefaultSelection())
    }

    private func buildSelectionState() -> ModelSelectionDraft {
        if let stored = modelSelectionStore.loadAppDefaultSelection() {
            return selectionState(from: stored)
        }
        let providers = providerStore.loadProviders()
        let fallbackProviderID = providers.first?.id ?? ""
        let fallbackModelID = providers.first.flatMap {
            providerStore.availableModels(forProviderID: $0.id).first?.id
        } ?? ""
        return ModelSelectionDraft(
            selectedProviderID: fallbackProviderID,
            selectedModelRecordID: fallbackModelID,
            selectedReasoningEffort: nil,
            selectedThinkingEnabled: nil
        )
    }

    private func selectionState(from selection: ModelSelection) -> ModelSelectionDraft {
        ModelSelectionDraft(
            selectedProviderID: providerStore.providerID(forModelRecordID: selection.modelRecordID) ?? "",
            selectedModelRecordID: selection.modelRecordID,
            selectedReasoningEffort: selection.reasoningEffort,
            selectedThinkingEnabled: selection.thinkingEnabled
        )
    }

    private func normalizedSelection(
        from state: ModelSelectionDraft
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

    private func refreshStatusPrompt(for selection: ModelSelection?) {
        guard let selection else {
            navigationItem.prompt = nil
            return
        }
        let resolution = ModelSelectionResolver.resolve(
            appDefault: selection,
            projectDefault: nil,
            threadSelection: nil,
            availableCredentials: ProviderCredentialResolver.resolveAvailableCredentials(providerStore: providerStore),
            providerStore: providerStore
        )
        guard case .invalidOverride = resolution.state else {
            navigationItem.prompt = nil
            return
        }
        navigationItem.prompt = String(
            localized: "settings.default_model.invalid",
            defaultValue: "Invalid App Default"
        )
    }
}
