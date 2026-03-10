//
//  ProjectModelSelectionViewController.swift
//  Doufu
//

import UIKit

/// Lets the user pick a project-level default provider + model.
/// Similar to `DefaultModelSelectionViewController` but scoped to a single project
/// and includes a "Use App Default" option.
final class ProjectModelSelectionViewController: UITableViewController {

    var onSelectionChanged: ((ProjectModelSelection?) -> Void)?

    private enum Section: Int, CaseIterable {
        case provider
        case model
    }

    private let providerStore = LLMProviderSettingsStore.shared
    private let projectID: String

    private var providers: [LLMProviderRecord] = []
    private var selectedProviderID: String?
    private var selectedModelRecordID: String?
    /// Whether the user explicitly chose "Use App Default" (nil selection).
    private var isUsingAppDefault: Bool = true

    init(projectID: String, currentSelection: ProjectModelSelection?) {
        self.projectID = projectID
        if let selection = currentSelection {
            self.selectedProviderID = selection.providerID
            self.selectedModelRecordID = selection.modelRecordID
            self.isUsingAppDefault = false
        }
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .doufuBackground
        title = String(localized: "project_settings.default_model.title")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        reloadProviders()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadProviders()
    }

    // MARK: - DataSource

    override func numberOfSections(in tableView: UITableView) -> Int {
        selectedProviderID != nil ? Section.allCases.count : 1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else { return 0 }
        switch section {
        case .provider:
            return providers.count + 1 // +1 for "Use App Default"
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
            return String(localized: "project_settings.default_model.provider_hint")
        case .model:
            return String(localized: "project_settings.default_model.footer")
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        guard let section = Section(rawValue: indexPath.section) else { return cell }

        switch section {
        case .provider:
            if indexPath.row == 0 {
                // "Use App Default" row
                var configuration = cell.defaultContentConfiguration()
                configuration.text = String(localized: "project_settings.default_model.use_app_default")
                if let appDefault = providerStore.loadDefaultModelSelection() {
                    let providerLabel = providers.first(where: { $0.id == appDefault.providerID })?.label ?? appDefault.providerID
                    let modelLabel = providers.first(where: { $0.id == appDefault.providerID })?
                        .availableModels.first(where: { $0.normalizedID == appDefault.modelRecordID.lowercased() })?
                        .effectiveDisplayName ?? appDefault.modelRecordID
                    configuration.secondaryText = "\(providerLabel) · \(modelLabel)"
                } else {
                    configuration.secondaryText = String(localized: "settings.default_model.not_set")
                }
                configuration.secondaryTextProperties.color = .secondaryLabel
                cell.contentConfiguration = configuration
                cell.accessoryType = isUsingAppDefault ? .checkmark : .none
            } else {
                let providerIndex = indexPath.row - 1
                guard providers.indices.contains(providerIndex) else { return cell }
                let provider = providers[providerIndex]
                var configuration = cell.defaultContentConfiguration()
                configuration.text = provider.label
                configuration.secondaryText = provider.kind.displayName
                configuration.secondaryTextProperties.color = .secondaryLabel
                cell.contentConfiguration = configuration
                cell.accessoryType = (!isUsingAppDefault && selectedProviderID == provider.id) ? .checkmark : .none
            }

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
            if indexPath.row == 0 {
                // "Use App Default"
                isUsingAppDefault = true
                selectedProviderID = nil
                selectedModelRecordID = nil
                onSelectionChanged?(nil)
                tableView.reloadData()
            } else {
                let providerIndex = indexPath.row - 1
                guard providers.indices.contains(providerIndex) else { return }
                let provider = providers[providerIndex]
                guard provider.id != selectedProviderID || isUsingAppDefault else { return }
                isUsingAppDefault = false
                selectedProviderID = provider.id
                selectedModelRecordID = nil
                tableView.reloadData()
            }

        case .model:
            let models = modelsForSelectedProvider()
            guard models.indices.contains(indexPath.row) else { return }
            guard let providerID = selectedProviderID else { return }
            let model = models[indexPath.row]
            selectedModelRecordID = model.id
            let selection = ProjectModelSelection(providerID: providerID, modelRecordID: model.id)
            onSelectionChanged?(selection)
            tableView.reloadSections(IndexSet(integer: Section.model.rawValue), with: .none)
        }
    }

    // MARK: - Helpers

    private func reloadProviders() {
        providers = providerStore.loadProviders()
        if let providerID = selectedProviderID,
           !providers.contains(where: { $0.id == providerID }) {
            selectedProviderID = nil
            selectedModelRecordID = nil
            isUsingAppDefault = true
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
