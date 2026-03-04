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
        case addProvider
    }

    private let store = LLMProviderSettingsStore.shared
    private var oauthService: OpenAICodexOAuthService?
    private weak var loginSafariViewController: SFSafariViewController?

    private var labelText = ""
    private var manualBaseURLText = ""
    private var manualBearerTokenText = ""

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

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "OAuth"
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
            return "Label"
        case .oauth:
            return "OAuth"
        case .manual:
            return "Or Configure Manually"
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else {
            return nil
        }

        switch section {
        case .oauth:
            return "点击后将跳转 OpenAI 登录，成功后将自动填入网址和 Bearer Token。"
        case .manual:
            return "留空网址时默认使用 https://api.openai.com"
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
                placeholder: "Provider Name",
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
                title: "Sign in with OpenAI",
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
                    placeholder: "https://api.openai.com",
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
                    placeholder: "Bearer Token"
                ) { [weak self] text in
                    self?.manualBearerTokenText = text
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
                cell.configure(title: "Add Provider", isEnabled: canSubmitProvider)
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
            signInWithOpenAI()
        case .manual:
            if ManualRow(rawValue: indexPath.row) == .addProvider, canSubmitProvider {
                addProvider()
            }
        case .label:
            break
        }
    }

    private func signInWithOpenAI() {
        guard oauthService == nil else {
            return
        }

        let oauthService = OpenAICodexOAuthService()
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

    private func addProvider() {
        view.endEditing(true)

        let trimmedToken = manualBearerTokenText.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmedToken.isEmpty {
            showError(message: "请先登录成功，或直接填写 Bearer Token。")
            return
        }

        do {
            let provider = try store.addOpenAICompatibleProviderUsingOAuth(
                label: labelText,
                baseURLString: manualBaseURLText,
                autoAppendV1: true,
                bearerToken: trimmedToken
            )
            showAddedAlert(providerLabel: provider.label)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    private func showError(message: String) {
        let alert = UIAlertController(title: "添加失败", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

    private func handleOAuthResult(_ result: Result<OpenAICodexOAuthService.SignInResult, Error>) {
        oauthService = nil
        dismissLoginIfNeeded()
        refreshOAuthAndAddProviderCells()

        switch result {
        case let .success(payload):
            if manualBaseURLText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                manualBaseURLText = payload.baseURLString
            }
            manualBearerTokenText = payload.bearerToken
            refreshManualInputRows()

        case let .failure(error):
            if
                let serviceError = error as? OpenAICodexOAuthService.ServiceError,
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
            title: "添加成功",
            message: "Provider「\(providerLabel)」已添加。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "完成", style: .default, handler: { [weak self] _ in
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
