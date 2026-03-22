//
//  ProviderAuthMethodViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import AuthenticationServices
import UIKit

/// Presents authentication method choices for a provider kind.
///
/// Layout:
///   Section 0 — API Key:        one cell  (manual API key)
///   Section 1 — OAuth:          provider-specific OAuth options
final class ProviderAuthMethodViewController: UIViewController, UITableViewDelegate, ASWebAuthenticationPresentationContextProviding {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    // MARK: - Section / Row model

    private enum OAuthRow {
        case openAI
        case openRouter

        var title: String {
            switch self {
            case .openAI:
                return "OpenAI"
            case .openRouter:
                return "OpenRouter"
            }
        }

        var subtitle: String {
            switch self {
            case .openAI:
                return String(localized: "providers.auth_method.oauth.openai.subtitle")
            case .openRouter:
                return String(localized: "providers.auth_method.oauth.openrouter.subtitle")
            }
        }
    }

    // MARK: - Properties

    private let store = LLMProviderSettingsStore.shared
    private let providerKind: LLMProviderRecord.Kind
    private lazy var oauthRows: [OAuthRow] = {
        switch providerKind {
        case .openAIResponses:
            return [.openAI]
        case .openRouter:
            return [.openRouter]
        default:
            return []
        }
    }()
    private var openAIOAuth: OpenAIOAuthService?
    private var openRouterOAuth: OpenRouterOAuthService?

    /// True while an OAuth flow is in progress — disables row selection.
    private var isOAuthInProgress: Bool {
        openAIOAuth != nil || openRouterOAuth != nil
    }

    private var diffableDataSource: AuthMethodDataSource!

    // MARK: - Lifecycle

    init(providerKind: LLMProviderRecord.Kind = .openAIResponses) {
        self.providerKind = providerKind
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
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        title = String(localized: "providers.auth_method.title")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "MethodCell")

        configureDiffableDataSource()
        applySnapshot()
    }

    // MARK: - Diffable DataSource

    private func configureDiffableDataSource() {
        diffableDataSource = AuthMethodDataSource(
            tableView: tableView
        ) { [weak self] tableView, indexPath, itemID in
            guard let self else { return UITableViewCell() }
            return self.cell(for: tableView, indexPath: indexPath, itemID: itemID)
        }
        diffableDataSource.defaultRowAnimation = .none
    }

    private func cell(
        for tableView: UITableView,
        indexPath: IndexPath,
        itemID: AuthMethodItemID
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "MethodCell", for: indexPath)
        cell.accessoryType = .disclosureIndicator

        var configuration = cell.defaultContentConfiguration()

        switch itemID {
        case .apiKey:
            configuration.text = String(localized: "providers.auth_method.api_key.title")
            configuration.secondaryText = String(localized: "providers.auth_method.api_key.subtitle")

        case .oauthOpenAI:
            configuration.text = OAuthRow.openAI.title
            configuration.secondaryText = OAuthRow.openAI.subtitle

        case .oauthOpenRouter:
            configuration.text = OAuthRow.openRouter.title
            configuration.secondaryText = OAuthRow.openRouter.subtitle
        }

        configuration.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = configuration
        return cell
    }

    // MARK: - Snapshot

    private func buildSnapshot() -> NSDiffableDataSourceSnapshot<AuthMethodSectionID, AuthMethodItemID> {
        var snapshot = NSDiffableDataSourceSnapshot<AuthMethodSectionID, AuthMethodItemID>()

        snapshot.appendSections([.apiKey])
        snapshot.appendItems([.apiKey], toSection: .apiKey)

        if !oauthRows.isEmpty {
            snapshot.appendSections([.oauth])
            var items: [AuthMethodItemID] = []
            for row in oauthRows {
                switch row {
                case .openAI:
                    items.append(.oauthOpenAI)
                case .openRouter:
                    items.append(.oauthOpenRouter)
                }
            }
            snapshot.appendItems(items, toSection: .oauth)
        }

        return snapshot
    }

    private func applySnapshot() {
        var snapshot = buildSnapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        diffableDataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Selection

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        if isOAuthInProgress {
            return nil
        }
        return indexPath
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath) else { return }

        switch itemID {
        case .apiKey:
            let controller = ProviderAPIKeyFormViewController(providerKind: providerKind)
            navigationController?.pushViewController(controller, animated: true)

        case .oauthOpenAI:
            startOpenAIOAuth()

        case .oauthOpenRouter:
            startOpenRouterOAuth()
        }
    }

    // MARK: - ASWebAuthenticationPresentationContextProviding

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        view.window ?? ASPresentationAnchor()
    }

    // MARK: - OpenAI OAuth

    private func startOpenAIOAuth() {
        guard openAIOAuth == nil else { return }

        let service = OpenAIOAuthService()
        self.openAIOAuth = service

        service.startWebAuth(contextProvider: self) { [weak self] result in
            guard let self else { return }
            self.openAIOAuth = nil

            switch result {
            case let .success(payload):
                self.createOpenAIProvider(from: payload)

            case let .failure(error):
                if let serviceError = error as? OpenAIOAuthService.ServiceError,
                   case .cancelled = serviceError {
                    return
                }
                self.showError(message: error.localizedDescription)
            }
        }
    }

    private func createOpenAIProvider(from payload: OpenAIOAuthService.SignInResult) {
        do {
            let provider = try store.addProviderUsingOAuth(
                kind: .openAIResponses,
                label: "OpenAI",
                baseURLString: payload.baseURLString,
                autoAppendV1: payload.autoAppendV1,
                bearerToken: payload.bearerToken,
                chatGPTAccountID: payload.chatGPTAccountID,
                modelID: nil
            )
            showSuccessAndPop(providerLabel: provider.label)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    // MARK: - OpenRouter OAuth PKCE

    private func startOpenRouterOAuth() {
        guard openRouterOAuth == nil else { return }

        let service = OpenRouterOAuthService()
        self.openRouterOAuth = service

        service.start(contextProvider: self) { [weak self] result in
            guard let self else { return }
            self.openRouterOAuth = nil

            switch result {
            case let .success(payload):
                self.createOpenRouterProvider(apiKey: payload.apiKey)

            case let .failure(error):
                if let serviceError = error as? OpenRouterOAuthService.ServiceError,
                   case .cancelled = serviceError
                {
                    return
                }
                self.showError(message: error.localizedDescription)
            }
        }
    }

    private func createOpenRouterProvider(apiKey: String) {
        do {
            let provider = try store.addProviderUsingAPIKey(
                kind: providerKind,
                label: "OpenRouter",
                apiKey: apiKey,
                baseURLString: providerKind.defaultBaseURLString,
                autoAppendV1: providerKind.defaultAutoAppendV1,
                modelID: nil
            )
            showSuccessAndPop(providerLabel: provider.label)
        } catch {
            showError(message: error.localizedDescription)
        }
    }

    // MARK: - Alerts & navigation

    private func showSuccessAndPop(providerLabel: String) {
        let alert = UIAlertController(
            title: String(localized: "providers.form.alert.add_success.title"),
            message: String(
                format: String(localized: "providers.form.alert.add_success.message_format"),
                providerLabel
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: String(localized: "common.action.done"),
            style: .default,
            handler: { [weak self] _ in
                self?.popToManageProviders()
            }
        ))
        present(alert, animated: true)
    }

    private func showError(message: String) {
        let alert = UIAlertController(
            title: String(localized: "providers.form.alert.add_failed.title"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
        present(alert, animated: true)
    }

    private func popToManageProviders() {
        guard let navigationController else { return }
        if let target = navigationController.viewControllers.first(where: { $0 is ManageProvidersViewController }) {
            navigationController.popToViewController(target, animated: true)
            return
        }
        navigationController.popViewController(animated: true)
    }
}

// MARK: - Section & Item IDs

nonisolated enum AuthMethodSectionID: Hashable, Sendable {
    case apiKey
    case oauth

    var header: String? {
        switch self {
        case .apiKey:
            return String(localized: "providers.auth_method.api_key.title")
        case .oauth:
            return String(localized: "providers.auth_method.oauth.title")
        }
    }

    var footer: String? { nil }
}

nonisolated enum AuthMethodItemID: Hashable, Sendable {
    case apiKey
    case oauthOpenAI
    case oauthOpenRouter
}

// MARK: - DataSource (header/footer support)

private final class AuthMethodDataSource: UITableViewDiffableDataSource<AuthMethodSectionID, AuthMethodItemID> {
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sectionIdentifier(for: section)?.header
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sectionIdentifier(for: section)?.footer
    }
}
