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
        title = "Providers"
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
        "Configured Providers"
    }

    override func tableView(
        _ tableView: UITableView,
        titleForFooterInSection section: Int
    ) -> String? {
        providers.isEmpty ? "点击右上角 + 添加第一个 Provider。" : "左滑可删除 Provider。"
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        if providers.isEmpty {
            let cell = tableView.dequeueReusableCell(withIdentifier: "PlaceholderCell", for: indexPath)
            cell.selectionStyle = .none
            var configuration = UIListContentConfiguration.cell()
            configuration.text = "还没有 Provider"
            configuration.textProperties.alignment = .center
            configuration.textProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            return cell
        }

        let provider = providers[indexPath.row]
        let cell = tableView.dequeueReusableCell(withIdentifier: "ProviderCell", for: indexPath)
        cell.selectionStyle = .none

        var configuration = cell.defaultContentConfiguration()
        configuration.image = provider.authMode == .apiKey
            ? UIImage(systemName: "key.fill")
            : UIImage(systemName: "person.crop.circle.badge.checkmark")
        configuration.text = provider.label
        configuration.secondaryText = "\(provider.kind.displayName) · \(provider.authMode.displayName)"
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
        let deleteAction = UIContextualAction(style: .destructive, title: "删除") { [weak self] _, _, completion in
            self?.deleteProvider(provider, completion: completion)
        }
        deleteAction.backgroundColor = .systemRed
        return UISwipeActionsConfiguration(actions: [deleteAction])
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
            title: "删除失败",
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

    @objc
    private func didTapAddProvider() {
        let controller = AddProviderViewController()
        navigationController?.pushViewController(controller, animated: true)
    }
}
