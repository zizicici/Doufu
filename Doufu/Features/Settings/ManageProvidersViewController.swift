//
//  ManageProvidersViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import UIKit

final class ManageProvidersViewController: UITableViewController {

    private let store = LLMProviderSettingsStore.shared
    private var providers: [LLMProviderRecord] = []

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
        title = String(localized: "providers.manage.title")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProviderCell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "PlaceholderCell")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(didTapAddProvider)
        )
        reloadProviders()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadProviders()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(providers.count, 1)
    }

    override func tableView(
        _ tableView: UITableView,
        titleForHeaderInSection section: Int
    ) -> String? {
        String(localized: "providers.manage.section.configured")
    }

    override func tableView(
        _ tableView: UITableView,
        titleForFooterInSection section: Int
    ) -> String? {
        providers.isEmpty
            ? String(localized: "providers.manage.footer.empty_hint")
            : String(localized: "providers.manage.footer.delete_hint")
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        if providers.isEmpty {
            let cell = tableView.dequeueReusableCell(withIdentifier: "PlaceholderCell", for: indexPath)
            cell.selectionStyle = .none
            var configuration = UIListContentConfiguration.cell()
            configuration.text = String(localized: "providers.manage.empty")
            configuration.textProperties.alignment = .center
            configuration.textProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            return cell
        }

        let provider = providers[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "ProviderCell", for: indexPath)
        cell.selectionStyle = .default
        cell.accessoryType = .disclosureIndicator

        var configuration = cell.defaultContentConfiguration()
        configuration.text = provider.label
        configuration.secondaryText = String(
            format: String(localized: "providers.manage.item.subtitle_format"),
            provider.kind.displayName,
            provider.authMode.displayName
        )
        configuration.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = configuration
        return cell
    }

    override func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard !providers.isEmpty else {
            return nil
        }

        let provider = providers[indexPath.row]
        let deleteAction = UIContextualAction(style: .destructive, title: String(localized: "common.action.delete")) { [weak self] _, _, completion in
            self?.deleteProvider(provider, completion: completion)
        }
        deleteAction.backgroundColor = .systemRed
        return UISwipeActionsConfiguration(actions: [deleteAction])
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard !providers.isEmpty else {
            return
        }

        let provider = providers[indexPath.row]
        switch provider.authMode {
        case .apiKey:
            let controller = ProviderAPIKeyFormViewController(provider: provider)
            navigationController?.pushViewController(controller, animated: true)
        case .oauth:
            // Anthropic OAuth providers use the API Key form because Anthropic's
            // "OAuth" flow is just pasting a key from the console (no real OAuth callback).
            if provider.kind == .anthropic {
                let controller = ProviderAPIKeyFormViewController(provider: provider)
                navigationController?.pushViewController(controller, animated: true)
            } else {
                let controller = ProviderOAuthFormViewController(provider: provider)
                navigationController?.pushViewController(controller, animated: true)
            }
        }
    }

    private func reloadProviders() {
        providers = store.loadProviders()
        tableView.reloadData()
    }

    private func deleteProvider(_ provider: LLMProviderRecord, completion: @escaping (Bool) -> Void) {
        do {
            try store.deleteProvider(id: provider.id)
            reloadProviders()
            completion(true)
        } catch {
            completion(false)
            showError(message: error.localizedDescription)
        }
    }

    private func showError(message: String) {
        let alert = UIAlertController(
            title: String(localized: "providers.manage.alert.delete_failed.title"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
        present(alert, animated: true)
    }

    @objc
    private func didTapAddProvider() {
        let controller = AddProviderViewController()
        navigationController?.pushViewController(controller, animated: true)
    }
}
