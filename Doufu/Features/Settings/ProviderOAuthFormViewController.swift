//
//  ProviderOAuthFormViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import SafariServices
import UIKit

final class ProviderOAuthFormViewController: UITableViewController, SFSafariViewControllerDelegate {

    private enum Section: Int, CaseIterable {
        case label
        case oauth
        case manual
        case storedModels
        case manageModels
        case addProvider
    }

    private enum ManualRow: Int, CaseIterable {
        case httpsURL
        case bearerToken
    }

    private let store = LLMProviderSettingsStore.shared
    private let modelManagement = ProviderModelManagementCoordinator()
    private let editingProvider: LLMProviderRecord?
    private let providerKind: LLMProviderRecord.Kind
    private var oauthService: OpenAIOAuthService?
    private weak var loginSafariViewController: SFSafariViewController?

    private var labelText = ""
    private var manualBaseURLText = ""
    private var manualBearerTokenText = ""
    private var oauthSuggestedAutoAppendV1 = true
    private var oauthDerivedChatGPTAccountID: String?

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
        let trimmedToken = manualBearerTokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedBaseURL = manualBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedLabel.isEmpty else {
            return false
        }
        guard !trimmedToken.isEmpty else {
            return false
        }
        return isValidOptionalBaseURL(trimmedBaseURL)
    }

    init(providerKind: LLMProviderRecord.Kind) {
        editingProvider = nil
        self.providerKind = providerKind
        oauthSuggestedAutoAppendV1 = providerKind.defaultAutoAppendV1
        super.init(style: .insetGrouped)
    }

    init(provider: LLMProviderRecord) {
        editingProvider = provider
        providerKind = provider.kind
        labelText = provider.label
        manualBaseURLText = provider.baseURLString
        oauthSuggestedAutoAppendV1 = provider.autoAppendV1
        oauthDerivedChatGPTAccountID = provider.chatGPTAccountID
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .doufuBackground
        title = providerKind.displayName + " · " + String(localized: "providers.auth_method.oauth.title")
        if let editingProvider {
            manualBearerTokenText = (try? store.loadOAuthBearerToken(for: editingProvider.id)) ?? ""
        }
        tableView.keyboardDismissMode = .onDrag
        tableView.register(SettingsTextInputCell.self, forCellReuseIdentifier: SettingsTextInputCell.reuseIdentifier)
        tableView.register(SettingsSecureInputCell.self, forCellReuseIdentifier: SettingsSecureInputCell.reuseIdentifier)
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
        case .label, .oauth, .addProvider:
            return 1
        case .manual:
            return ManualRow.allCases.count
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
        case .oauth:
            return String(localized: "providers.form.section.oauth")
        case .manual:
            return String(localized: "providers.oauth_form.section.manual")
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
        case .oauth:
            return oauthFooterText()
        case .manual:
            return "Default Base URL: \(providerKind.defaultBaseURLString)"
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

        case .oauth:
            guard
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: SettingsCenteredButtonCell.reuseIdentifier,
                    for: indexPath
                ) as? SettingsCenteredButtonCell
            else {
                return UITableViewCell()
            }
            cell.configure(
                title: signInButtonTitle(),
                isEnabled: oauthService == nil
            )
            return cell

        case .manual:
            guard let row = ManualRow(rawValue: indexPath.row) else {
                return UITableViewCell()
            }

            switch row {
            case .httpsURL:
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
                    text: manualBaseURLText,
                    placeholder: providerKind.defaultBaseURLString,
                    keyboardType: .URL,
                    autocapitalizationType: .none
                ) { [weak self] text in
                    self?.manualBaseURLText = text
                    self?.refreshAddProviderCell()
                }
                return cell

            case .bearerToken:
                guard
                    let cell = tableView.dequeueReusableCell(
                        withIdentifier: SettingsSecureInputCell.reuseIdentifier,
                        for: indexPath
                    ) as? SettingsSecureInputCell
                else {
                    return UITableViewCell()
                }
                cell.configure(
                    text: manualBearerTokenText,
                    placeholder: String(localized: "providers.form.placeholder.bearer_token")
                ) { [weak self] text in
                    self?.manualBearerTokenText = text
                    self?.refreshAddProviderCell()
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
        case .oauth:
            return indexPath
        case .addProvider:
            return canSubmitProvider ? indexPath : nil
        case .manageModels:
            return modelManagement.isRefreshingModels ? nil : indexPath
        case .storedModels:
            let models = storedModels()
            guard models.indices.contains(indexPath.row) else { return nil }
            return indexPath
        case .label, .manual:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }

        guard let section = Section(rawValue: indexPath.section) else {
            return
        }

        switch section {
        case .oauth:
            signInWithProvider()
        case .addProvider:
            if canSubmitProvider {
                submitProvider()
            }
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
        case .label, .manual:
            break
        }
    }

    private func signInWithProvider() {
        switch providerKind {
        case .openAICompatible:
            signInWithOpenAIOAuth()
        case .anthropic:
            guard let loginURL = oauthLoginURL(for: providerKind) else {
                showError(message: "OAuth login URL unavailable.")
                return
            }
            let safariController = SFSafariViewController(url: loginURL)
            safariController.delegate = self
            loginSafariViewController = safariController
            present(safariController, animated: true)
        case .googleGemini:
            // Gemini only supports API Key auth; this VC should not be
            // reachable for Gemini providers.
            break
        }
    }

    private func signInWithOpenAIOAuth() {
        guard oauthService == nil else {
            return
        }

        let oauthService = OpenAIOAuthService()
        do {
            let authorizeURL = try oauthService.start { [weak self] result in
                self?.handleOAuthResult(result)
            }

            self.oauthService = oauthService

            let safariController = SFSafariViewController(url: authorizeURL)
            safariController.delegate = self
            loginSafariViewController = safariController
            present(safariController, animated: true)
            refreshOAuthAndAddProviderCells()
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    private func submitProvider() {
        view.endEditing(true)

        let trimmedToken = manualBearerTokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToken.isEmpty {
            showError(message: String(localized: "providers.oauth_form.error.empty_token"))
            return
        }

        do {
            let autoAppendV1 = resolveAutoAppendV1()
            let accountID = providerKind == .openAICompatible ? oauthDerivedChatGPTAccountID : nil
            if let editingProvider {
                _ = try store.updateProviderUsingOAuth(
                    providerID: editingProvider.id,
                    label: labelText,
                    baseURLString: manualBaseURLText,
                    autoAppendV1: autoAppendV1,
                    bearerToken: trimmedToken,
                    chatGPTAccountID: accountID,
                    modelID: latestEditingProvider()?.modelID
                )
                popToManageProviders()
            } else {
                let provider = try store.addProviderUsingOAuth(
                    kind: providerKind,
                    label: labelText,
                    baseURLString: manualBaseURLText,
                    autoAppendV1: autoAppendV1,
                    bearerToken: trimmedToken,
                    chatGPTAccountID: accountID,
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

    private func handleOAuthResult(_ result: Result<OpenAIOAuthService.SignInResult, Error>) {
        oauthService = nil
        dismissLoginIfNeeded()
        refreshOAuthAndAddProviderCells()

        switch result {
        case let .success(payload):
            if manualBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                manualBaseURLText = payload.baseURLString
            }
            manualBearerTokenText = payload.bearerToken
            oauthSuggestedAutoAppendV1 = payload.autoAppendV1
            oauthDerivedChatGPTAccountID = payload.chatGPTAccountID
            refreshManualInputRows()

        case let .failure(error):
            if
                let serviceError = error as? OpenAIOAuthService.ServiceError,
                case .cancelled = serviceError
            {
                return
            }
            showError(message: error.localizedDescription)
        }
    }

    private func dismissLoginIfNeeded() {
        guard let presented = loginSafariViewController else {
            return
        }
        if presented.presentingViewController != nil {
            presented.dismiss(animated: true)
        }
        loginSafariViewController = nil
    }

    func safariViewControllerDidFinish(_ controller: SFSafariViewController) {
        loginSafariViewController = nil
        oauthService?.cancel()
        oauthService = nil
        refreshOAuthAndAddProviderCells()
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

    private func refreshAddProviderCell() {
        let sectionIndex = Section.addProvider.rawValue
        let rowIndex = 0
        guard tableView.numberOfSections > sectionIndex else {
            return
        }
        let indexPath = IndexPath(row: rowIndex, section: sectionIndex)
        guard tableView.numberOfRows(inSection: sectionIndex) > rowIndex else {
            return
        }
        tableView.reloadRows(at: [indexPath], with: .none)
    }

    private func refreshOAuthAndAddProviderCells() {
        let oauthIndexPath = IndexPath(row: 0, section: Section.oauth.rawValue)
        if tableView.numberOfSections > Section.oauth.rawValue,
           tableView.numberOfRows(inSection: Section.oauth.rawValue) > 0 {
            tableView.reloadRows(at: [oauthIndexPath], with: .none)
        }
        refreshAddProviderCell()
    }

    private func refreshManualInputRows() {
        let sectionIndex = Section.manual.rawValue
        guard tableView.numberOfSections > sectionIndex else {
            return
        }

        let rows = [ManualRow.httpsURL.rawValue, ManualRow.bearerToken.rawValue]
        let indexPaths = rows.compactMap { row -> IndexPath? in
            guard tableView.numberOfRows(inSection: sectionIndex) > row else {
                return nil
            }
            return IndexPath(row: row, section: sectionIndex)
        }

        if !indexPaths.isEmpty {
            tableView.reloadRows(at: indexPaths, with: .none)
        }
        refreshAddProviderCell()
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

    private func resolveAutoAppendV1() -> Bool {
        let trimmedBaseURL = manualBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedBaseURL.isEmpty else {
            return oauthSuggestedAutoAppendV1
        }

        let loweredBaseURL = trimmedBaseURL.lowercased()
        if loweredBaseURL.contains("chatgpt.com/backend-api/codex") {
            return false
        }
        if isEditingProvider {
            return oauthSuggestedAutoAppendV1
        }
        return providerKind.defaultAutoAppendV1
    }

    private func signInButtonTitle() -> String {
        switch providerKind {
        case .openAICompatible:
            return String(localized: "providers.oauth_form.button.sign_in")
        case .anthropic:
            return "Sign in with Anthropic"
        case .googleGemini:
            return ""
        }
    }

    private func oauthFooterText() -> String {
        switch providerKind {
        case .openAICompatible:
            return String(localized: "providers.oauth_form.footer.oauth")
        case .anthropic:
            return "Login opens Anthropic account page. Paste OAuth bearer token below."
        case .googleGemini:
            return ""
        }
    }

    private func oauthLoginURL(for kind: LLMProviderRecord.Kind) -> URL? {
        switch kind {
        case .openAICompatible:
            return URL(string: "https://auth.openai.com/log-in")
        case .anthropic:
            return URL(string: "https://console.anthropic.com/login")
        case .googleGemini:
            return nil
        }
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
