//
//  DefaultModelSelectionViewController.swift
//  Doufu
//

import UIKit

/// App-level default model selection (Settings → Default Model).
final class DefaultModelSelectionViewController: BaseModelSelectionViewController {

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "settings.default_model.title")
    }

    // MARK: - Hooks

    override func providerSectionFooter() -> String? {
        selectedProviderID == nil
            ? String(localized: "settings.default_model.provider_hint")
            : nil
    }

    override func modelSectionFooter() -> String? {
        String(localized: "settings.default_model.footer")
    }

    override func handleModelSelected(providerID: String, model: LLMProviderModelRecord) {
        providerStore.saveDefaultModelSelection(providerID: providerID, modelRecordID: model.id)
    }

    override func onProvidersReloaded() {
        let current = providerStore.loadDefaultModelSelection()
        if let current, providers.contains(where: { $0.id == current.providerID }) {
            selectedProviderID = current.providerID
            selectedModelRecordID = current.modelRecordID
        } else {
            selectedProviderID = nil
            selectedModelRecordID = nil
        }
    }
}
