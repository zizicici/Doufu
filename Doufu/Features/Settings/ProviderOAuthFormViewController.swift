//
//  ProviderOAuthFormViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import AuthenticationServices
import SafariServices
import UIKit

final class ProviderOAuthFormViewController: UIViewController, UITableViewDelegate, SFSafariViewControllerDelegate, ASWebAuthenticationPresentationContextProviding {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

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

    private var diffableDataSource: OAuthFormDataSource!

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
        super.init(nibName: nil, bundle: nil)
    }

    init(provider: LLMProviderRecord) {
        editingProvider = provider
        providerKind = provider.kind
        labelText = provider.label
        manualBaseURLText = provider.baseURLString
        oauthSuggestedAutoAppendV1 = provider.autoAppendV1
        oauthDerivedChatGPTAccountID = provider.chatGPTAccountID
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
        title = providerKind.displayName + " · " + String(localized: "providers.auth_method.oauth.title")
        if let editingProvider {
            manualBearerTokenText = (try? store.loadOAuthBearerToken(for: editingProvider.id)) ?? ""
        }
        tableView.keyboardDismissMode = .onDrag
        tableView.register(SettingsTextInputCell.self, forCellReuseIdentifier: SettingsTextInputCell.reuseIdentifier)
        tableView.register(SettingsSecureInputCell.self, forCellReuseIdentifier: SettingsSecureInputCell.reuseIdentifier)
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
        diffableDataSource = OAuthFormDataSource(
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
        itemID: OAuthFormItemID
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

        case .oauthSignIn:
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

        case .manualBaseURL:
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
                self?.refreshSubmitButton()
            }
            return cell

        case .manualBearerToken:
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
                self?.refreshSubmitButton()
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

    private func buildSnapshot() -> NSDiffableDataSourceSnapshot<OAuthFormSectionID, OAuthFormItemID> {
        var snapshot = NSDiffableDataSourceSnapshot<OAuthFormSectionID, OAuthFormItemID>()

        snapshot.appendSections([.label, .oauth, .manual])
        snapshot.appendItems([.labelInput], toSection: .label)
        snapshot.appendItems([.oauthSignIn(isSigningIn: oauthService != nil)], toSection: .oauth)
        snapshot.appendItems([.manualBaseURL, .manualBearerToken], toSection: .manual)

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

    private func footer(for sectionID: OAuthFormSectionID) -> String? {
        switch sectionID {
        case .oauth:
            return oauthFooterText()
        case .manual:
            return String(localized: "providers.form.footer.default_base_url \(providerKind.defaultBaseURLString)")
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
        case .oauthSignIn:
            return indexPath
        case .addProvider:
            return canSubmitProvider ? indexPath : nil
        case .refreshModels:
            return modelManagement.isRefreshingModels ? nil : indexPath
        case .addCustomModel:
            return indexPath
        case .storedModel:
            return indexPath
        case .labelInput, .manualBaseURL, .manualBearerToken, .emptyModels:
            return nil
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }

        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath) else {
            return
        }

        switch itemID {
        case .oauthSignIn:
            signInWithProvider()
        case .addProvider:
            if canSubmitProvider {
                submitProvider()
            }
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
        case .labelInput, .manualBaseURL, .manualBearerToken, .emptyModels:
            break
        }
    }

    private func signInWithProvider() {
        switch providerKind {
        case .openAIResponses, .openRouter:
            signInWithOpenAIOAuth()
        case .anthropic:
            guard let loginURL = oauthLoginURL(for: providerKind) else {
                showError(message: String(localized: "providers.oauth_form.error.login_url_unavailable", defaultValue: "OAuth login URL unavailable."))
                return
            }
            let safariController = SFSafariViewController(url: loginURL)
            safariController.delegate = self
            loginSafariViewController = safariController
            present(safariController, animated: true)
        case .openAIChatCompletions, .googleGemini, .xiaomiMiMo:
            // These providers only support API Key auth; this VC should not be
            // reachable for them.
            break
        }
    }

    private func signInWithOpenAIOAuth() {
        guard oauthService == nil else {
            return
        }

        let oauthService = OpenAIOAuthService()
        self.oauthService = oauthService
        applySnapshot()

        oauthService.startWebAuth(contextProvider: self) { [weak self] result in
            self?.handleOAuthResult(result)
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
            let accountID = (providerKind == .openAIResponses || providerKind == .openRouter) ? oauthDerivedChatGPTAccountID : nil
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
        applySnapshot()

        switch result {
        case let .success(payload):
            if manualBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                manualBaseURLText = payload.baseURLString
            }
            manualBearerTokenText = payload.bearerToken
            oauthSuggestedAutoAppendV1 = payload.autoAppendV1
            oauthDerivedChatGPTAccountID = payload.chatGPTAccountID
            applySnapshot()

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
        applySnapshot()
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        view.window ?? ASPresentationAnchor()
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
        case .openAIResponses, .openRouter:
            return String(localized: "providers.oauth_form.button.sign_in")
        case .anthropic:
            return String(localized: "providers.oauth_form.button.sign_in_anthropic", defaultValue: "Sign in with Anthropic")
        case .openAIChatCompletions, .googleGemini, .xiaomiMiMo:
            return ""
        }
    }

    private func oauthFooterText() -> String {
        switch providerKind {
        case .openAIResponses, .openRouter:
            return String(localized: "providers.oauth_form.footer.oauth")
        case .anthropic:
            return String(localized: "providers.oauth_form.footer.anthropic", defaultValue: "Login opens Anthropic account page. Paste OAuth bearer token below.")
        case .openAIChatCompletions, .googleGemini, .xiaomiMiMo:
            return ""
        }
    }

    private func oauthLoginURL(for kind: LLMProviderRecord.Kind) -> URL? {
        switch kind {
        case .openAIResponses, .openRouter:
            return URL(string: "https://auth.openai.com/log-in")
        case .anthropic:
            return URL(string: "https://console.anthropic.com/login")
        case .openAIChatCompletions, .googleGemini, .xiaomiMiMo:
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

// MARK: - Diffable DataSource Types

nonisolated enum OAuthFormSectionID: Hashable, Sendable {
    case label
    case oauth
    case manual
    case manageModels
    case storedModels
    case addProvider

    var header: String? {
        switch self {
        case .label:
            return String(localized: "providers.form.section.label")
        case .oauth:
            return String(localized: "providers.form.section.oauth")
        case .manual:
            return String(localized: "providers.oauth_form.section.manual")
        case .storedModels:
            return String(localized: "provider_model.section.stored_models")
        case .manageModels:
            return String(localized: "provider_model.section.manage_models")
        case .addProvider:
            return nil
        }
    }
}

nonisolated enum OAuthFormItemID: Hashable, Sendable {
    case labelInput
    case oauthSignIn(isSigningIn: Bool)
    case manualBaseURL
    case manualBearerToken
    case storedModel(id: String)
    case emptyModels
    case refreshModels(isRefreshing: Bool)
    case addCustomModel
    case addProvider
}

private final class OAuthFormDataSource: UITableViewDiffableDataSource<OAuthFormSectionID, OAuthFormItemID> {
    var footerProvider: ((OAuthFormSectionID) -> String?)?

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sectionIdentifier(for: section)?.header
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let sectionID = sectionIdentifier(for: section) else { return nil }
        return footerProvider?(sectionID) ?? nil
    }
}
