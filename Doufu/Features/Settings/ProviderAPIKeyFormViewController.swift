//
//  ProviderAPIKeyFormViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import UIKit

final class ProviderAPIKeyFormViewController: UITableViewController {

    private enum Section: Int, CaseIterable {
        case label
        case apiKey
        case customAPI
        case storedModels
        case manageModels
        case addProvider
    }

    private enum CustomAPIRow: Int, CaseIterable {
        case baseURL
        case autoAppendV1
    }

    private let store = LLMProviderSettingsStore.shared
    private let modelManagement = ProviderModelManagementCoordinator()
    private let editingProvider: LLMProviderRecord?
    private let providerKind: LLMProviderRecord.Kind

    private var labelText = ""
    private var apiKeyText = ""
    private var customBaseURLText = ""
    private var shouldAutoAppendV1 = true
    private var isEditingProvider: Bool {
        editingProvider != nil
    }

    private var submitButtonTitle: String {
        isEditingProvider
            ? String(localized: "common.action.save")
            : String(localized: "providers.form.button.add_provider")
    }

    private var canSubmitProvider: Bool {
        let trimmedLabel = labelText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedAPIKey = apiKeyText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = customBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedLabel.isEmpty, !trimmedAPIKey.isEmpty else {
            return false
        }
        return isValidOptionalBaseURL(trimmedBaseURL)
    }

    init(providerKind: LLMProviderRecord.Kind) {
        editingProvider = nil
        self.providerKind = providerKind
        shouldAutoAppendV1 = providerKind.defaultAutoAppendV1
        super.init(style: .insetGrouped)
    }

    init(provider: LLMProviderRecord) {
        editingProvider = provider
        providerKind = provider.kind
        labelText = provider.label
        customBaseURLText = provider.baseURLString
        shouldAutoAppendV1 = provider.autoAppendV1
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .doufuBackground
        title = providerKind.displayName + " · " + String(localized: "providers.auth_method.api_key.title")
        if let editingProvider {
            apiKeyText = (try? store.loadAPIKey(for: editingProvider.id)) ?? ""
            if apiKeyText.isEmpty, editingProvider.kind == .anthropic, editingProvider.authMode == .oauth {
                apiKeyText = (try? store.loadOAuthBearerToken(for: editingProvider.id)) ?? ""
            }
        }
        tableView.keyboardDismissMode = .onDrag
        tableView.register(SettingsTextInputCell.self, forCellReuseIdentifier: SettingsTextInputCell.reuseIdentifier)
        tableView.register(SettingsSecureInputCell.self, forCellReuseIdentifier: SettingsSecureInputCell.reuseIdentifier)
        tableView.register(SettingsToggleCell.self, forCellReuseIdentifier: SettingsToggleCell.reuseIdentifier)
        tableView.register(SettingsCenteredButtonCell.self, forCellReuseIdentifier: SettingsCenteredButtonCell.reuseIdentifier)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProviderCell")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if isEditingProvider {
            tableView.reloadData()
        }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        modelManagement.cancelRefreshIfNeeded(whenViewRemoved: view.window == nil)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else {
            return 0
        }

        switch section {
        case .label, .apiKey, .addProvider:
            return 1
        case .customAPI:
            return CustomAPIRow.allCases.count
        case .storedModels:
            guard isEditingProvider else {
                return 0
            }
            return max(storedModels().count, 1)
        case .manageModels:
            return isEditingProvider ? ProviderModelManageRow.allCases.count : 0
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else {
            return nil
        }

        switch section {
        case .label:
            return String(localized: "providers.form.section.label")
        case .apiKey:
            return String(localized: "providers.form.section.api_key")
        case .customAPI:
            return String(localized: "providers.api_key_form.section.custom_api")
        case .storedModels:
            return isEditingProvider ? String(localized: "provider_model.section.stored_models") : nil
        case .manageModels:
            return isEditingProvider ? String(localized: "provider_model.section.manage_models") : nil
        case .addProvider:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else {
            return nil
        }

        switch section {
        case .customAPI:
            return "Default: \(providerKind.defaultBaseURLString)"
        default:
            return nil
        }
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        guard let section = Section(rawValue: indexPath.section) else {
            return UITableViewCell()
        }

        switch section {
        case .label:
            guard
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: SettingsTextInputCell.reuseIdentifier,
                    for: indexPath
                ) as? SettingsTextInputCell
            else {
                return UITableViewCell()
            }
            cell.configure(
                title: nil,
                text: labelText,
                placeholder: String(localized: "providers.form.placeholder.provider_name"),
                autocapitalizationType: .words
            ) { [weak self] text in
                self?.labelText = text
                self?.refreshAddProviderCell()
            }
            return cell

        case .apiKey:
            guard
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: SettingsSecureInputCell.reuseIdentifier,
                    for: indexPath
                ) as? SettingsSecureInputCell
            else {
                return UITableViewCell()
            }
            cell.configure(
                text: apiKeyText,
                placeholder: String(localized: "providers.api_key_form.placeholder.api_key")
            ) { [weak self] text in
                self?.apiKeyText = text
                self?.refreshAddProviderCell()
            }
            return cell

        case .customAPI:
            guard let row = CustomAPIRow(rawValue: indexPath.row) else {
                return UITableViewCell()
            }

            switch row {
            case .baseURL:
                guard
                    let cell = tableView.dequeueReusableCell(
                        withIdentifier: SettingsTextInputCell.reuseIdentifier,
                        for: indexPath
                    ) as? SettingsTextInputCell
                else {
                    return UITableViewCell()
                }
                cell.configure(
                    title: nil,
                    text: customBaseURLText,
                    placeholder: providerKind.defaultBaseURLString,
                    keyboardType: .URL,
                    autocapitalizationType: .none
                ) { [weak self] text in
                    self?.customBaseURLText = text
                    self?.refreshAddProviderCell()
                }
                return cell

            case .autoAppendV1:
                guard
                    let cell = tableView.dequeueReusableCell(
                        withIdentifier: SettingsToggleCell.reuseIdentifier,
                        for: indexPath
                    ) as? SettingsToggleCell
                else {
                    return UITableViewCell()
                }
                cell.configure(title: String(localized: "providers.api_key_form.toggle.auto_append_v1"), isOn: shouldAutoAppendV1) { [weak self] isOn in
                    self?.shouldAutoAppendV1 = isOn
                }
                return cell
            }

        case .storedModels:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProviderCell", for: indexPath)
            let models = storedModels()
            if models.isEmpty {
                cell.selectionStyle = .none
                cell.accessoryType = .none
                var configuration = UIListContentConfiguration.cell()
                configuration.text = String(localized: "provider_model.stored_models.empty")
                configuration.textProperties.color = .secondaryLabel
                configuration.textProperties.alignment = .center
                cell.contentConfiguration = configuration
                return cell
            }
            guard models.indices.contains(indexPath.row) else {
                return cell
            }
            let model = models[indexPath.row]
            var configuration = cell.defaultContentConfiguration()
            configuration.text = model.effectiveDisplayName
            let sourceLabel = model.source == .official
                ? String(localized: "provider_model.source.official")
                : String(localized: "provider_model.source.custom")
            configuration.secondaryText = sourceLabel + " · " + model.modelID
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.accessoryType = .disclosureIndicator
            return cell

        case .manageModels:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProviderCell", for: indexPath)
            guard let row = ProviderModelManageRow(rawValue: indexPath.row) else {
                return cell
            }
            var configuration = cell.defaultContentConfiguration()
            switch row {
            case .refreshOfficialModels:
                configuration.text = modelManagement.isRefreshingModels
                    ? String(localized: "provider_model.action.refreshing_models")
                    : String(localized: "provider_model.action.refresh_models")
                configuration.secondaryText = String(localized: "provider_model.action.refresh_models.subtitle")
                cell.accessoryType = .none
            case .addCustomModel:
                configuration.text = String(localized: "provider_model.action.add_custom_model")
                configuration.secondaryText = String(localized: "provider_model.action.add_custom_model.subtitle")
                cell.accessoryType = .disclosureIndicator
            }
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            return cell

        case .addProvider:
            guard
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: SettingsCenteredButtonCell.reuseIdentifier,
                    for: indexPath
                ) as? SettingsCenteredButtonCell
            else {
                return UITableViewCell()
            }
            cell.configure(title: submitButtonTitle, isEnabled: canSubmitProvider)
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard let section = Section(rawValue: indexPath.section) else {
            return nil
        }
        switch section {
        case .addProvider:
            return canSubmitProvider ? indexPath : nil
        case .manageModels:
            return modelManagement.isRefreshingModels ? nil : indexPath
        case .storedModels:
            let models = storedModels()
            guard models.indices.contains(indexPath.row) else { return nil }
            return indexPath
        case .label, .apiKey, .customAPI:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }

        guard let section = Section(rawValue: indexPath.section) else {
            return
        }
        switch section {
        case .addProvider:
            guard canSubmitProvider else {
                return
            }
            submitProvider()
        case .storedModels:
            let models = storedModels()
            guard models.indices.contains(indexPath.row),
                  let provider = latestEditingProvider()
            else { return }
            let model = models[indexPath.row]
            if model.source == .official {
                modelManagement.presentModelDetail(
                    for: provider,
                    model: model,
                    from: self
                )
            } else {
                modelManagement.presentModelEditor(
                    for: provider,
                    existingModel: model,
                    from: self
                )
            }
        case .manageModels:
            guard let row = ProviderModelManageRow(rawValue: indexPath.row) else {
                return
            }
            switch row {
            case .refreshOfficialModels:
                guard let provider = latestEditingProvider() else {
                    return
                }
                modelManagement.refreshOfficialModels(
                    for: provider,
                    manageSectionIndex: Section.manageModels.rawValue,
                    in: self
                )
            case .addCustomModel:
                guard let provider = latestEditingProvider() else {
                    return
                }
                modelManagement.presentModelEditor(
                    for: provider,
                    existingModel: nil,
                    from: self
                )
            }
        case .label, .apiKey, .customAPI:
            break
        }
    }

    private func submitProvider() {
        view.endEditing(true)

        do {
            if let editingProvider {
                if editingProvider.kind == .anthropic, editingProvider.authMode == .oauth {
                    // Anthropic OAuth providers are routed to the API Key form
                    // because the "OAuth" flow is just pasting a token from the
                    // console.  Preserve the original authMode so it is not
                    // silently converted to .apiKey on save.
                    _ = try store.updateProviderUsingOAuth(
                        providerID: editingProvider.id,
                        label: labelText,
                        baseURLString: customBaseURLText,
                        autoAppendV1: shouldAutoAppendV1,
                        bearerToken: apiKeyText,
                        chatGPTAccountID: nil,
                        modelID: latestEditingProvider()?.modelID
                    )
                } else {
                    _ = try store.updateProviderUsingAPIKey(
                        providerID: editingProvider.id,
                        label: labelText,
                        apiKey: apiKeyText,
                        baseURLString: customBaseURLText,
                        autoAppendV1: shouldAutoAppendV1,
                        modelID: latestEditingProvider()?.modelID
                    )
                }
                popToManageProviders()
            } else {
                let provider = try store.addProviderUsingAPIKey(
                    kind: providerKind,
                    label: labelText,
                    apiKey: apiKeyText,
                    baseURLString: customBaseURLText,
                    autoAppendV1: shouldAutoAppendV1,
                    modelID: nil
                )
                showAddedAlert(providerLabel: provider.label)
            }
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    private func showError(message: String) {
        let alert = UIAlertController(
            title: isEditingProvider
                ? String(localized: "file_viewer.alert.save_failed.title")
                : String(localized: "providers.form.alert.add_failed.title"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
        present(alert, animated: true)
    }

    private func refreshAddProviderCell() {
        let sectionIndex = Section.addProvider.rawValue
        guard tableView.numberOfSections > sectionIndex else {
            return
        }
        let indexPath = IndexPath(row: 0, section: sectionIndex)
        guard tableView.numberOfRows(inSection: sectionIndex) > indexPath.row else {
            return
        }
        tableView.reloadRows(at: [indexPath], with: .none)
    }

    private func isValidOptionalBaseURL(_ baseURLString: String) -> Bool {
        guard !baseURLString.isEmpty else {
            return true
        }

        guard
            let components = URLComponents(string: baseURLString),
            let scheme = components.scheme?.lowercased(),
            (scheme == "https" || scheme == "http"),
            components.host?.isEmpty == false
        else {
            return false
        }
        return true
    }

    private func showAddedAlert(providerLabel: String) {
        let alert = UIAlertController(
            title: String(localized: "providers.form.alert.add_success.title"),
            message: String(
                format: String(localized: "providers.form.alert.add_success.message_format"),
                providerLabel
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.action.done"), style: .default, handler: { [weak self] _ in
            self?.popToManageProviders()
        }))
        present(alert, animated: true)
    }

    private func popToManageProviders() {
        guard let navigationController else {
            return
        }

        if let target = navigationController.viewControllers.first(where: { $0 is ManageProvidersViewController }) {
            navigationController.popToViewController(target, animated: true)
            return
        }
        navigationController.popViewController(animated: true)
    }

    private func latestEditingProvider() -> LLMProviderRecord? {
        guard let editingProvider else {
            return nil
        }
        return store.loadProvider(id: editingProvider.id) ?? editingProvider
    }

    private func storedModels() -> [LLMProviderModelRecord] {
        modelManagement.storedModels(for: latestEditingProvider())
    }
}
