//
//  ProjectModelSelectionViewController.swift
//  Doufu
//

import UIKit

/// Project-level default model selection. Adds a "Use App Default" row at the top.
final class ProjectModelSelectionViewController: BaseModelSelectionViewController {

    var onSelectionChanged: ((ModelSelection?) -> Void)?

    /// Whether the user explicitly chose "Use App Default" (nil selection).
    private var isUsingAppDefault: Bool = true
    private var storedSelection: ModelSelection?
    private var storedResolution = ModelSelectionResolution.missingSelection(hasUsableProviderEnvironment: false)
    private var appDefaultSummaryText: String?

    init(projectID: String, currentSelection: ModelSelection?) {
        super.init()
        storedSelection = currentSelection
        if let selection = currentSelection {
            self.selectedProviderID = selection.providerID
            self.selectedModelRecordID = selection.modelRecordID
            self.isUsingAppDefault = false
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "project_settings.default_model.title")
    }

    // MARK: - Hooks

    override func providerRowCount() -> Int {
        providers.count + 1 // +1 for "Use App Default"
    }

    override func configureProviderCell(_ cell: UITableViewCell, at row: Int) {
        if row == 0 {
            var configuration = cell.defaultContentConfiguration()
            configuration.text = String(localized: "project_settings.default_model.use_app_default")
            if case .invalidOverride = storedResolution.state {
                configuration.secondaryText = String(
                    localized: "project_settings.default_model.invalid",
                    defaultValue: "Invalid Project Default"
                )
            } else {
                configuration.secondaryText = appDefaultSummaryText
            }
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.accessoryType = isUsingAppDefault ? .checkmark : .none
        } else {
            let providerIndex = row - 1
            guard providers.indices.contains(providerIndex) else { return }
            let provider = providers[providerIndex]
            var configuration = cell.defaultContentConfiguration()
            configuration.text = provider.label
            configuration.secondaryText = provider.kind.displayName
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.accessoryType = (!isUsingAppDefault && selectedProviderID == provider.id) ? .checkmark : .none
        }
    }

    override func handleProviderSelection(at row: Int) -> Bool {
        if row == 0 {
            isUsingAppDefault = true
            selectedProviderID = nil
            selectedModelRecordID = nil
            storedSelection = nil
            storedResolution = .missingSelection(
                hasUsableProviderEnvironment: !ProviderCredentialResolver
                    .resolveAvailableCredentials(providerStore: providerStore)
                    .isEmpty
            )
            navigationItem.prompt = nil
            onSelectionChanged?(nil)
            tableView.reloadData()
            return true
        }
        let providerIndex = row - 1
        guard providers.indices.contains(providerIndex) else { return false }
        let provider = providers[providerIndex]
        guard provider.id != selectedProviderID || isUsingAppDefault else { return true }
        isUsingAppDefault = false
        selectedProviderID = provider.id
        selectedModelRecordID = nil
        tableView.reloadData()
        return true
    }

    override func handleModelSelected(providerID: String, model: LLMProviderModelRecord) {
        let selection = ModelSelection(providerID: providerID, modelRecordID: model.id)
        storedSelection = selection
        isUsingAppDefault = false
        reloadStoredSelectionState()
        onSelectionChanged?(selection)
    }

    override func providerSectionFooter() -> String? {
        String(localized: "project_settings.default_model.provider_hint")
    }

    override func modelSectionFooter() -> String? {
        String(localized: "project_settings.default_model.footer")
    }

    override func onProvidersReloaded() {
        reloadStoredSelectionState()
    }

    private func reloadStoredSelectionState() {
        let credentials = ProviderCredentialResolver.resolveAvailableCredentials(providerStore: providerStore)
        appDefaultSummaryText = {
            guard let appDefault = providerStore.loadDefaultModelSelection() else {
                return String(localized: "settings.default_model.not_set")
            }
            let resolution = ModelSelectionResolver.resolve(
                appDefault: appDefault,
                projectDefault: nil,
                threadSelection: nil,
                availableCredentials: credentials,
                providerStore: providerStore
            )
            guard resolution.state == .valid else {
                return String(
                    localized: "settings.default_model.invalid",
                    defaultValue: "Invalid App Default"
                )
            }
            let providerLabel = providers.first(where: { $0.id == appDefault.providerID })?.label ?? appDefault.providerID
            let modelLabel = providers.first(where: { $0.id == appDefault.providerID })?
                .availableModels.first(where: { $0.normalizedID == appDefault.modelRecordID.lowercased() })?
                .effectiveDisplayName ?? appDefault.modelRecordID
            return "\(providerLabel) · \(modelLabel)"
        }()

        if let storedSelection {
            storedResolution = ModelSelectionResolver.resolve(
                appDefault: nil,
                projectDefault: storedSelection,
                threadSelection: nil,
                availableCredentials: credentials,
                providerStore: providerStore
            )
            isUsingAppDefault = false
            if providers.contains(where: { $0.id == storedSelection.providerID }) {
                selectedProviderID = storedSelection.providerID
                selectedModelRecordID = storedSelection.modelRecordID
            } else {
                selectedProviderID = nil
                selectedModelRecordID = nil
            }
        } else {
            storedResolution = .missingSelection(hasUsableProviderEnvironment: !credentials.isEmpty)
            isUsingAppDefault = true
            selectedProviderID = nil
            selectedModelRecordID = nil
        }

        navigationItem.prompt = {
            guard case .invalidOverride = storedResolution.state else { return nil }
            return String(
                localized: "project_settings.default_model.invalid",
                defaultValue: "Invalid Project Default"
            )
        }()
    }
}
