//
//  DefaultModelSelectionViewController.swift
//  Doufu
//
//  Created by Claude on 2026/03/09.
//

import UIKit

final class DefaultModelSelectionViewController: UITableViewController {

    private enum Section: Int, CaseIterable {
        case provider
        case model
    }

    private let store = LLMProviderSettingsStore.shared

    private var providers: [LLMProviderRecord] = []
    private var selectedProviderID: String?
    private var selectedModelRecordID: String?

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .doufuBackground
        title = String(localized: "settings.default_model.title")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        reloadProviders()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadProviders()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        selectedProviderID != nil ? Section.allCases.count : 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else { return 0 }
        switch section {
        case .provider:
            return providers.count
        case .model:
            return modelsForSelectedProvider().count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .provider:
            return String(localized: "chat.menu.provider")
        case .model:
            return String(localized: "chat.menu.model")
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .provider:
            if selectedProviderID == nil {
                return String(localized: "settings.default_model.provider_hint")
            }
            return nil
        case .model:
            return String(localized: "settings.default_model.footer")
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        guard let section = Section(rawValue: indexPath.section) else { return cell }

        switch section {
        case .provider:
            guard providers.indices.contains(indexPath.row) else { return cell }
            let provider = providers[indexPath.row]
            var configuration = cell.defaultContentConfiguration()
            configuration.text = provider.label
            configuration.secondaryText = provider.kind.displayName
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.accessoryType = selectedProviderID == provider.id ? .checkmark : .none

        case .model:
            let models = modelsForSelectedProvider()
            guard models.indices.contains(indexPath.row) else { return cell }
            let model = models[indexPath.row]
            var configuration = cell.defaultContentConfiguration()
            configuration.text = model.effectiveDisplayName
            let sourceLabel = model.source == .official
                ? String(localized: "provider_model.source.official")
                : String(localized: "provider_model.source.custom")
            configuration.secondaryText = sourceLabel + " · " + model.modelID
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.accessoryType = selectedModelRecordID.map({ model.id.caseInsensitiveCompare($0) == .orderedSame }) == true
                ? .checkmark
                : .none
        }

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let section = Section(rawValue: indexPath.section) else { return }

        switch section {
        case .provider:
            guard providers.indices.contains(indexPath.row) else { return }
            let provider = providers[indexPath.row]
            guard provider.id != selectedProviderID else { return }
            selectedProviderID = provider.id
            selectedModelRecordID = nil
            tableView.reloadData()

        case .model:
            let models = modelsForSelectedProvider()
            guard models.indices.contains(indexPath.row) else { return }
            guard let providerID = selectedProviderID else { return }
            let model = models[indexPath.row]
            selectedModelRecordID = model.id
            store.saveDefaultModelSelection(providerID: providerID, modelRecordID: model.id)
            tableView.reloadSections(IndexSet(integer: Section.model.rawValue), with: .none)
        }
    }

    private func reloadProviders() {
        providers = store.loadProviders()
        let current = store.loadDefaultModelSelection()
        if let current, providers.contains(where: { $0.id == current.providerID }) {
            selectedProviderID = current.providerID
            selectedModelRecordID = current.modelRecordID
        } else {
            selectedProviderID = nil
            selectedModelRecordID = nil
        }
        tableView.reloadData()
    }

    private func modelsForSelectedProvider() -> [LLMProviderModelRecord] {
        guard let provider = providers.first(where: { $0.id == selectedProviderID }) else {
            return []
        }
        return provider.availableModels
    }
}
