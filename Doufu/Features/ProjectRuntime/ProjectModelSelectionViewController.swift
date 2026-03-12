//
//  ProjectModelSelectionViewController.swift
//  Doufu
//

import UIKit

/// Project-level default model selection.
/// Embeds `ModelConfigurationViewController` for full provider/model/reasoning/thinking configuration.
/// "Use Default" resets to app default (nil selection).
@MainActor
final class ProjectModelSelectionViewController: UIViewController {

    var onSelectionChanged: ((ModelSelection?) -> Void)?

    private let providerStore = LLMProviderSettingsStore.shared
    private let modelSelectionStore = ModelSelectionStateStore.shared
    private var currentSelection: ModelSelection?

    init(projectID: String, currentSelection: ModelSelection?) {
        self.currentSelection = currentSelection
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "project_settings.default_model.title")
        view.backgroundColor = .doufuBackground

        let initialState = buildSelectionState()
        let hasExplicitSelection = currentSelection != nil
        let controller = ModelConfigurationViewController(
            initialState: initialState,
            showsResetToDefaults: hasExplicitSelection,
            projectUsageIdentifier: "project-default",
            inheritedState: buildInheritedState(),
            inheritedStateProvider: { [weak self] in
                self?.buildInheritedState()
            },
            inheritTitle: String(localized: "model_config.inherit.use_app_default")
        )
        controller.onSelectionStateChanged = { [weak self] state in
            guard let self else { return SelectionApplyOutcome(hasExplicitSelection: false) }
            let selection = self.normalizedSelection(from: state)
            self.currentSelection = selection
            self.onSelectionChanged?(selection)
            self.refreshStatusPrompt()
            return SelectionApplyOutcome(hasExplicitSelection: selection != nil)
        }
        controller.onResetToDefaults = { [weak self] in
            guard let self else { return initialState }
            self.currentSelection = nil
            self.onSelectionChanged?(nil)
            self.refreshStatusPrompt()
            return self.buildInheritedState()
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
        refreshStatusPrompt()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshStatusPrompt()
    }

    private func buildSelectionState() -> ModelSelectionDraft {
        if let stored = currentSelection {
            return selectionState(from: stored)
        }
        return buildInheritedState()
    }

    private func buildInheritedState() -> ModelSelectionDraft {
        if let appDefault = modelSelectionStore.loadAppDefaultSelection() {
            return selectionState(from: appDefault)
        }
        return .empty
    }

    private func selectionState(from selection: ModelSelection) -> ModelSelectionDraft {
        ModelSelectionDraft(
            selectedProviderID: selection.providerID,
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

    private func refreshStatusPrompt() {
        if let currentSelection {
            let resolution = ModelSelectionResolver.resolve(
                appDefault: nil,
                projectDefault: currentSelection,
                threadSelection: nil,
                availableCredentials: ProviderCredentialResolver.resolveAvailableCredentials(providerStore: providerStore),
                providerStore: providerStore
            )
            if case .invalidOverride = resolution.state {
                navigationItem.prompt = String(
                    localized: "project_settings.default_model.invalid",
                    defaultValue: "Invalid Project Default"
                )
            } else {
                navigationItem.prompt = nil
            }
            return
        }

        let resolution = ModelSelectionResolver.resolve(
            appDefault: modelSelectionStore.loadAppDefaultSelection(),
            projectDefault: nil,
            threadSelection: nil,
            availableCredentials: ProviderCredentialResolver.resolveAvailableCredentials(providerStore: providerStore),
            providerStore: providerStore
        )
        switch resolution.state {
        case .invalidOverride:
            navigationItem.prompt = String(
                localized: "settings.default_model.invalid",
                defaultValue: "Invalid App Default"
            )
        case .missingSelection:
            navigationItem.prompt = String(
                localized: "chat.model_selection.missing.short",
                defaultValue: "Missing Model Selection"
            )
        case .valid:
            navigationItem.prompt = nil
        }
    }
}
