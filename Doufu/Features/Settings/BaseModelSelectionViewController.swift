//
//  BaseModelSelectionViewController.swift
//  Doufu
//

import UIKit

/// Base class for provider + model selection UI.
/// Subclasses customize provider row count, cell configuration, selection handling,
/// and footer text by overriding the designated hook methods.
class BaseModelSelectionViewController: UITableViewController {

    enum Section: Int, CaseIterable {
        case provider
        case model
    }

    let providerStore = LLMProviderSettingsStore.shared

    private(set) var providers: [LLMProviderRecord] = []
    var selectedProviderID: String?
    var selectedModelRecordID: String?

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
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        reloadProviders()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadProviders()
    }

    // MARK: - Hooks for subclasses

    /// Number of rows in the provider section. Default returns `providers.count`.
    func providerRowCount() -> Int {
        providers.count
    }

    /// Configure a provider-section cell. `row` is the table row index.
    /// Default renders a plain provider row (no offset).
    func configureProviderCell(_ cell: UITableViewCell, at row: Int) {
        guard providers.indices.contains(row) else { return }
        let provider = providers[row]
        var configuration = cell.defaultContentConfiguration()
        configuration.text = provider.label
        configuration.secondaryText = provider.kind.displayName
        configuration.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = configuration
        cell.accessoryType = selectedProviderID == provider.id ? .checkmark : .none
    }

    /// Handle selection in the provider section. Return `true` if the subclass handled it.
    func handleProviderSelection(at row: Int) -> Bool {
        guard providers.indices.contains(row) else { return false }
        let provider = providers[row]
        guard provider.id != selectedProviderID else { return true }
        selectedProviderID = provider.id
        selectedModelRecordID = nil
        tableView.reloadData()
        return true
    }

    /// Called when a model is selected. Subclasses should persist the selection.
    func handleModelSelected(providerID: String, model: LLMProviderModelRecord) {
        // Default: no-op. Subclasses override.
    }

    /// Footer text for the provider section.
    func providerSectionFooter() -> String? { nil }

    /// Footer text for the model section.
    func modelSectionFooter() -> String? { nil }

    /// Called during `reloadProviders()` so subclasses can update their state.
    func onProvidersReloaded() {}

    // MARK: - DataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        selectedProviderID != nil ? Section.allCases.count : 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else { return 0 }
        switch section {
        case .provider:
            return providerRowCount()
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
            return providerSectionFooter()
        case .model:
            return modelSectionFooter()
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        guard let section = Section(rawValue: indexPath.section) else { return cell }

        switch section {
        case .provider:
            configureProviderCell(cell, at: indexPath.row)

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

    // MARK: - Selection

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let section = Section(rawValue: indexPath.section) else { return }

        switch section {
        case .provider:
            _ = handleProviderSelection(at: indexPath.row)

        case .model:
            let models = modelsForSelectedProvider()
            guard models.indices.contains(indexPath.row) else { return }
            guard let providerID = selectedProviderID else { return }
            let model = models[indexPath.row]
            selectedModelRecordID = model.id
            handleModelSelected(providerID: providerID, model: model)
            tableView.reloadSections(IndexSet(integer: Section.model.rawValue), with: .none)
        }
    }

    // MARK: - Helpers

    func reloadProviders() {
        providers = providerStore.loadProviders()
        onProvidersReloaded()
        tableView.reloadData()
    }

    func modelsForSelectedProvider() -> [LLMProviderModelRecord] {
        guard let provider = providers.first(where: { $0.id == selectedProviderID }) else {
            return []
        }
        return provider.availableModels
    }
}
