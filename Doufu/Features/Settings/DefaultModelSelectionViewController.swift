//
//  DefaultModelSelectionViewController.swift
//  Doufu
//

import UIKit

/// App-level default model selection (Settings → Default Model).
final class DefaultModelSelectionViewController: BaseModelSelectionViewController {

    private var storedSelection: ModelSelection?
    private var storedResolution = ModelSelectionResolution.missingSelection(hasUsableProviderEnvironment: false)

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "settings.default_model.title")
    }

    // MARK: - Hooks

    override func providerRowCount() -> Int {
        providers.count + 1
    }

    override func configureProviderCell(_ cell: UITableViewCell, at row: Int) {
        if row == 0 {
            var configuration = cell.defaultContentConfiguration()
            configuration.text = String(localized: "settings.default_model.not_set")
            if case .invalidOverride = storedResolution.state {
                configuration.secondaryText = String(
                    localized: "settings.default_model.invalid",
                    defaultValue: "Invalid App Default"
                )
            } else {
                configuration.secondaryText = nil
            }
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.accessoryType = storedSelection == nil ? .checkmark : .none
            return
        }
        super.configureProviderCell(cell, at: row - 1)
    }

    override func handleProviderSelection(at row: Int) -> Bool {
        if row == 0 {
            selectedProviderID = nil
            selectedModelRecordID = nil
            providerStore.clearDefaultModelSelection()
            storedSelection = nil
            storedResolution = .missingSelection(
                hasUsableProviderEnvironment: !ProviderCredentialResolver
                    .resolveAvailableCredentials(providerStore: providerStore)
                    .isEmpty
            )
            navigationItem.prompt = nil
            tableView.reloadData()
            return true
        }
        return super.handleProviderSelection(at: row - 1)
    }

    override func providerSectionFooter() -> String? {
        storedSelection == nil
            ? String(localized: "settings.default_model.provider_hint")
            : nil
    }

    override func modelSectionFooter() -> String? {
        String(localized: "settings.default_model.footer")
    }

    override func handleModelSelected(providerID: String, model: LLMProviderModelRecord) {
        providerStore.saveDefaultModelSelection(providerID: providerID, modelRecordID: model.id)
        reloadStoredSelectionState()
    }

    override func onProvidersReloaded() {
        reloadStoredSelectionState()
    }

    private func reloadStoredSelectionState() {
        storedSelection = providerStore.loadDefaultModelSelection()
        let credentials = ProviderCredentialResolver.resolveAvailableCredentials(providerStore: providerStore)
        if let storedSelection {
            storedResolution = ModelSelectionResolver.resolve(
                appDefault: storedSelection,
                projectDefault: nil,
                threadSelection: nil,
                availableCredentials: credentials,
                providerStore: providerStore
            )
            if providers.contains(where: { $0.id == storedSelection.providerID }) {
                selectedProviderID = storedSelection.providerID
                selectedModelRecordID = storedSelection.modelRecordID
            } else {
                selectedProviderID = nil
                selectedModelRecordID = nil
            }
        } else {
            storedResolution = .missingSelection(hasUsableProviderEnvironment: !credentials.isEmpty)
            selectedProviderID = nil
            selectedModelRecordID = nil
        }

        navigationItem.prompt = {
            guard case .invalidOverride = storedResolution.state else { return nil }
            return String(
                localized: "settings.default_model.invalid",
                defaultValue: "Invalid App Default"
            )
        }()
    }
}
