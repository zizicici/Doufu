//
//  ProviderAPIKeyFormViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import UIKit

final class ProviderAPIKeyFormViewController: UIViewController, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    private let store = LLMProviderSettingsStore.shared
    private let modelManagement = ProviderModelManagementCoordinator()
    private let editingProvider: LLMProviderRecord?
    private let providerKind: LLMProviderRecord.Kind

    private var labelText = ""
    private var apiKeyText = ""
    private var customBaseURLText = ""
    private var shouldAutoAppendV1 = true

    private var diffableDataSource: APIKeyFormDataSource!

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
        super.init(nibName: nil, bundle: nil)
    }

    init(provider: LLMProviderRecord) {
        editingProvider = provider
        providerKind = provider.kind
        labelText = provider.label
        customBaseURLText = provider.baseURLString
        shouldAutoAppendV1 = provider.autoAppendV1
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .doufuBackground
        tableView.backgroundColor = .doufuBackground
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        ])
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

        configureDiffableDataSource()
        applySnapshot()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applySnapshot()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        modelManagement.cancelRefreshIfNeeded(whenViewRemoved: view.window == nil)
    }

    // MARK: - Diffable DataSource

    private func configureDiffableDataSource() {
        diffableDataSource = APIKeyFormDataSource(
            tableView: tableView
        ) { [weak self] tableView, indexPath, itemID in
            guard let self else { return UITableViewCell() }
            return self.cell(for: tableView, indexPath: indexPath, itemID: itemID)
        }
        diffableDataSource.defaultRowAnimation = .none
        diffableDataSource.footerProvider = { [weak self] sectionID in
            self?.footer(for: sectionID)
        }
    }

    private func cell(
        for tableView: UITableView,
        indexPath: IndexPath,
        itemID: APIKeyFormItemID
    ) -> UITableViewCell {
        switch itemID {
        case .labelInput:
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
                self?.refreshSubmitButton()
            }
            return cell

        case .apiKeyInput:
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
                self?.refreshSubmitButton()
            }
            return cell

        case .baseURLInput:
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
                self?.refreshSubmitButton()
            }
            return cell

        case .autoAppendV1Toggle:
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

        case .storedModel(let id):
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProviderCell", for: indexPath)
            cell.selectionStyle = .default
            let models = storedModels()
            guard let model = models.first(where: { $0.id == id }) else {
                return cell
            }
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

        case .emptyModels:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProviderCell", for: indexPath)
            cell.selectionStyle = .none
            cell.accessoryType = .none
            var configuration = UIListContentConfiguration.cell()
            configuration.text = String(localized: "provider_model.stored_models.empty")
            configuration.textProperties.color = .secondaryLabel
            configuration.textProperties.alignment = .center
            cell.contentConfiguration = configuration
            return cell

        case .refreshModels:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProviderCell", for: indexPath)
            cell.selectionStyle = .default
            var configuration = cell.defaultContentConfiguration()
            configuration.text = modelManagement.isRefreshingModels
                ? String(localized: "provider_model.action.refreshing_models")
                : String(localized: "provider_model.action.refresh_models")
            configuration.secondaryText = String(localized: "provider_model.action.refresh_models.subtitle")
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.accessoryType = .none
            cell.contentConfiguration = configuration
            return cell

        case .addCustomModel:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProviderCell", for: indexPath)
            cell.selectionStyle = .default
            var configuration = cell.defaultContentConfiguration()
            configuration.text = String(localized: "provider_model.action.add_custom_model")
            configuration.secondaryText = String(localized: "provider_model.action.add_custom_model.subtitle")
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.accessoryType = .disclosureIndicator
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

    // MARK: - Snapshot

    private func buildSnapshot() -> NSDiffableDataSourceSnapshot<APIKeyFormSectionID, APIKeyFormItemID> {
        var snapshot = NSDiffableDataSourceSnapshot<APIKeyFormSectionID, APIKeyFormItemID>()

        snapshot.appendSections([.label, .apiKey, .customAPI])
        snapshot.appendItems([.labelInput], toSection: .label)
        snapshot.appendItems([.apiKeyInput], toSection: .apiKey)
        snapshot.appendItems([.baseURLInput, .autoAppendV1Toggle(isOn: shouldAutoAppendV1)], toSection: .customAPI)

        if isEditingProvider {
            snapshot.appendSections([.manageModels, .storedModels])

            let isRefreshing = modelManagement.isRefreshingModels
            snapshot.appendItems([
                .refreshModels(isRefreshing: isRefreshing),
                .addCustomModel
            ], toSection: .manageModels)

            let models = storedModels()
            if models.isEmpty {
                snapshot.appendItems([.emptyModels], toSection: .storedModels)
            } else {
                snapshot.appendItems(models.map { .storedModel(id: $0.id) }, toSection: .storedModels)
            }
        }

        snapshot.appendSections([.addProvider])
        snapshot.appendItems([.addProvider], toSection: .addProvider)

        return snapshot
    }

    private func applySnapshot() {
        var snapshot = buildSnapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        diffableDataSource.apply(snapshot, animatingDifferences: false)
    }

    private func refreshSubmitButton() {
        guard var snapshot = diffableDataSource?.snapshot() else { return }
        snapshot.reconfigureItems([.addProvider])
        diffableDataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Footer

    private func footer(for sectionID: APIKeyFormSectionID) -> String? {
        switch sectionID {
        case .customAPI:
            return String(localized: "providers.form.footer.default_url \(providerKind.defaultBaseURLString)")
        default:
            return nil
        }
    }

    // MARK: - Delegate

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath) else {
            return nil
        }
        switch itemID {
        case .addProvider:
            return canSubmitProvider ? indexPath : nil
        case .refreshModels:
            return modelManagement.isRefreshingModels ? nil : indexPath
        case .addCustomModel:
            return indexPath
        case .storedModel:
            return indexPath
        case .labelInput, .apiKeyInput, .baseURLInput, .autoAppendV1Toggle, .emptyModels:
            return nil
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }

        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath) else {
            return
        }
        switch itemID {
        case .addProvider:
            guard canSubmitProvider else {
                return
            }
            submitProvider()
        case .storedModel(let id):
            let models = storedModels()
            guard let model = models.first(where: { $0.id == id }),
                  let provider = latestEditingProvider()
            else { return }
            if model.source == .official {
                modelManagement.presentModelDetail(
                    for: provider,
                    model: model,
                    tableView: tableView,
                    from: self,
                    onUpdate: { [weak self] in self?.applySnapshot() }
                )
            } else {
                modelManagement.presentModelEditor(
                    for: provider,
                    existingModel: model,
                    tableView: tableView,
                    from: self,
                    onUpdate: { [weak self] in self?.applySnapshot() }
                )
            }
        case .refreshModels:
            guard let provider = latestEditingProvider() else {
                return
            }
            modelManagement.refreshOfficialModels(
                for: provider,
                manageSectionIndex: 0,
                tableView: tableView,
                in: self,
                onUpdate: { [weak self] in self?.applySnapshot() }
            )
        case .addCustomModel:
            guard let provider = latestEditingProvider() else {
                return
            }
            modelManagement.presentModelEditor(
                for: provider,
                existingModel: nil,
                tableView: tableView,
                from: self,
                onUpdate: { [weak self] in self?.applySnapshot() }
            )
        case .labelInput, .apiKeyInput, .baseURLInput, .autoAppendV1Toggle, .emptyModels:
            break
        }
    }

    private func submitProvider() {
        view.endEditing(true)

        if providerKind == .openAIResponses {
            let trimmedURL = customBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            if trimmedURL.contains("chat/completions") {
                showError(message: String(localized: "providers.openai.error.chat_completions_url"))
                return
            }
        }

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

// MARK: - Diffable DataSource Types

nonisolated enum APIKeyFormSectionID: Hashable, Sendable {
    case label
    case apiKey
    case customAPI
    case manageModels
    case storedModels
    case addProvider

    var header: String? {
        switch self {
        case .label:
            return String(localized: "providers.form.section.label")
        case .apiKey:
            return String(localized: "providers.form.section.api_key")
        case .customAPI:
            return String(localized: "providers.api_key_form.section.custom_api")
        case .storedModels:
            return String(localized: "provider_model.section.stored_models")
        case .manageModels:
            return String(localized: "provider_model.section.manage_models")
        case .addProvider:
            return nil
        }
    }
}

nonisolated enum APIKeyFormItemID: Hashable, Sendable {
    case labelInput
    case apiKeyInput
    case baseURLInput
    case autoAppendV1Toggle(isOn: Bool)
    case storedModel(id: String)
    case emptyModels
    case refreshModels(isRefreshing: Bool)
    case addCustomModel
    case addProvider
}

private final class APIKeyFormDataSource: UITableViewDiffableDataSource<APIKeyFormSectionID, APIKeyFormItemID> {
    var footerProvider: ((APIKeyFormSectionID) -> String?)?

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sectionIdentifier(for: section)?.header
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let sectionID = sectionIdentifier(for: section) else { return nil }
        return footerProvider?(sectionID) ?? nil
    }
}
