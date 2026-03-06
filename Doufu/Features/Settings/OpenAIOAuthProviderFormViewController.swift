//
//  OpenAIOAuthProviderFormViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import SafariServices
import UIKit

final class OpenAIOAuthProviderFormViewController: UITableViewController, SFSafariViewControllerDelegate {

    private enum Section: Int, CaseIterable {
        case label
        case oauth
        case manual
    }

    private enum ManualRow: Int, CaseIterable {
        case httpsURL
        case bearerToken
        case model
        case addProvider
    }

    private let store = LLMProviderSettingsStore.shared
    private let editingProvider: LLMProviderRecord?
    private let providerKind: LLMProviderRecord.Kind
    private var oauthService: OpenAIOAuthService?
    private weak var loginSafariViewController: SFSafariViewController?

    private var labelText = ""
    private var manualBaseURLText = ""
    private var manualBearerTokenText = ""
    private var modelIDText = ""
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
        let trimmedModelID = modelIDText.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedLabel.isEmpty else {
            return false
        }
        guard !trimmedToken.isEmpty else {
            return false
        }
        guard !trimmedModelID.isEmpty else {
            return false
        }
        return isValidOptionalBaseURL(trimmedBaseURL)
    }

    init(providerKind: LLMProviderRecord.Kind) {
        editingProvider = nil
        self.providerKind = providerKind
        oauthSuggestedAutoAppendV1 = providerKind.defaultAutoAppendV1
        modelIDText = providerKind.defaultModelID
        super.init(style: .insetGrouped)
    }

    init(provider: LLMProviderRecord) {
        editingProvider = provider
        providerKind = provider.kind
        labelText = provider.label
        manualBaseURLText = provider.baseURLString
        modelIDText = provider.effectiveModelID
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
        title = providerKind.displayName + " · " + String(localized: "providers.auth_method.oauth.title")
        if let editingProvider {
            manualBearerTokenText = (try? store.loadOAuthBearerToken(for: editingProvider.id)) ?? ""
        }
        tableView.keyboardDismissMode = .onDrag
        tableView.register(SettingsTextInputCell.self, forCellReuseIdentifier: SettingsTextInputCell.reuseIdentifier)
        tableView.register(SettingsSecureInputCell.self, forCellReuseIdentifier: SettingsSecureInputCell.reuseIdentifier)
        tableView.register(SettingsCenteredButtonCell.self, forCellReuseIdentifier: SettingsCenteredButtonCell.reuseIdentifier)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else {
            return 0
        }

        switch section {
        case .label, .oauth:
            return 1
        case .manual:
            return ManualRow.allCases.count
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
            return "Default Base URL: \(providerKind.defaultBaseURLString)\nBuilt-in Models: \(providerKind.builtInModels.joined(separator: ", "))"
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

            case .model:
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
                    text: modelIDText,
                    placeholder: providerKind.defaultModelID,
                    autocapitalizationType: .none
                ) { [weak self] text in
                    self?.modelIDText = text
                    self?.refreshAddProviderCell()
                }
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
    }

    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard let section = Section(rawValue: indexPath.section) else {
            return nil
        }

        switch section {
        case .oauth:
            return indexPath
        case .manual:
            guard ManualRow(rawValue: indexPath.row) == .addProvider else {
                return nil
            }
            return canSubmitProvider ? indexPath : nil
        case .label:
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
        case .manual:
            if ManualRow(rawValue: indexPath.row) == .addProvider, canSubmitProvider {
                submitProvider()
            }
        case .label:
            break
        }
    }

    private func signInWithProvider() {
        switch providerKind {
        case .openAICompatible:
            signInWithOpenAIOAuth()
        case .anthropic, .googleGemini:
            guard let loginURL = oauthLoginURL(for: providerKind) else {
                showError(message: "OAuth login URL unavailable.")
                return
            }
            let safariController = SFSafariViewController(url: loginURL)
            safariController.delegate = self
            loginSafariViewController = safariController
            present(safariController, animated: true)
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
            let trimmedModelID = modelIDText.trimmingCharacters(in: .whitespacesAndNewlines)
            let accountID = providerKind == .openAICompatible ? oauthDerivedChatGPTAccountID : nil
            if let editingProvider {
                _ = try store.updateProviderUsingOAuth(
                    providerID: editingProvider.id,
                    label: labelText,
                    baseURLString: manualBaseURLText,
                    autoAppendV1: autoAppendV1,
                    bearerToken: trimmedToken,
                    chatGPTAccountID: accountID,
                    modelID: trimmedModelID
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
                    modelID: trimmedModelID
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
        let sectionIndex = Section.manual.rawValue
        let rowIndex = ManualRow.addProvider.rawValue
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

        let rows = [ManualRow.httpsURL.rawValue, ManualRow.bearerToken.rawValue, ManualRow.model.rawValue]
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
            return "Sign in with Google for Cloud Code Assist"
        }
    }

    private func oauthFooterText() -> String {
        switch providerKind {
        case .openAICompatible:
            return String(localized: "providers.oauth_form.footer.oauth")
        case .anthropic:
            return "Login opens Anthropic account page. Paste OAuth bearer token below."
        case .googleGemini:
            return "Login opens Google OAuth page for Cloud Code Assist. Paste OAuth bearer token below."
        }
    }

    private func oauthLoginURL(for kind: LLMProviderRecord.Kind) -> URL? {
        switch kind {
        case .openAICompatible:
            return URL(string: "https://auth.openai.com/log-in")
        case .anthropic:
            return URL(string: "https://console.anthropic.com/login")
        case .googleGemini:
            return URL(string: "https://accounts.google.com/o/oauth2/v2/auth")
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
}
