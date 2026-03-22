//
//  ManageProvidersViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import UIKit

final class ManageProvidersViewController: UIViewController, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var diffableDataSource: ManageProvidersDataSource!

    private let store = LLMProviderSettingsStore.shared
    private var providers: [LLMProviderRecord] = []

    init() {
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
        title = String(localized: "providers.manage.title")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProviderCell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "PlaceholderCell")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .add,
            target: self,
            action: #selector(didTapAddProvider)
        )

        configureDiffableDataSource()
        reloadProviders()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadProviders()
    }

    // MARK: - Diffable DataSource

    private func configureDiffableDataSource() {
        diffableDataSource = ManageProvidersDataSource(
            tableView: tableView
        ) { [weak self] tableView, indexPath, itemID in
            guard let self else { return UITableViewCell() }

            switch itemID {
            case .empty:
                let cell = tableView.dequeueReusableCell(withIdentifier: "PlaceholderCell", for: indexPath)
                cell.selectionStyle = .none
                var configuration = UIListContentConfiguration.cell()
                configuration.text = String(localized: "providers.manage.empty")
                configuration.textProperties.alignment = .center
                configuration.textProperties.color = .secondaryLabel
                cell.contentConfiguration = configuration
                return cell

            case .provider(let id):
                let cell = tableView.dequeueReusableCell(withIdentifier: "ProviderCell", for: indexPath)
                cell.selectionStyle = .default
                cell.accessoryType = .disclosureIndicator
                if let provider = self.providers.first(where: { $0.id == id }) {
                    var configuration = cell.defaultContentConfiguration()
                    configuration.text = provider.label
                    configuration.secondaryText = String(
                        format: String(localized: "providers.manage.item.subtitle_format"),
                        provider.kind.displayName,
                        provider.authMode.displayName
                    )
                    configuration.secondaryTextProperties.color = .secondaryLabel
                    cell.contentConfiguration = configuration
                }
                return cell
            }
        }
        diffableDataSource.defaultRowAnimation = .none
        diffableDataSource.footerProvider = { [weak self] sectionID in
            guard let self else { return nil }
            return self.providers.isEmpty
                ? String(localized: "providers.manage.footer.empty_hint")
                : String(localized: "providers.manage.footer.delete_hint")
        }
    }

    // MARK: - Snapshot

    private func buildSnapshot() -> NSDiffableDataSourceSnapshot<ManageProvidersSectionID, ManageProvidersItemID> {
        var snapshot = NSDiffableDataSourceSnapshot<ManageProvidersSectionID, ManageProvidersItemID>()
        snapshot.appendSections([.providers])
        if providers.isEmpty {
            snapshot.appendItems([.empty], toSection: .providers)
        } else {
            snapshot.appendItems(providers.map { .provider(id: $0.id) }, toSection: .providers)
        }
        return snapshot
    }

    private func applySnapshot() {
        var snapshot = buildSnapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        diffableDataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Selection

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath),
              case .provider(let id) = itemID,
              let provider = providers.first(where: { $0.id == id })
        else { return }

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

    // MARK: - Swipe Actions

    func tableView(
        _ tableView: UITableView,
        trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath
    ) -> UISwipeActionsConfiguration? {
        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath),
              case .provider(let id) = itemID,
              let provider = providers.first(where: { $0.id == id })
        else { return nil }

        let deleteAction = UIContextualAction(style: .destructive, title: String(localized: "common.action.delete")) { [weak self] _, _, completion in
            self?.deleteProvider(provider, completion: completion)
        }
        deleteAction.backgroundColor = .systemRed
        return UISwipeActionsConfiguration(actions: [deleteAction])
    }

    // MARK: - Helpers

    private func reloadProviders() {
        providers = store.loadProviders()
        applySnapshot()
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

// MARK: - Section & Item IDs

nonisolated enum ManageProvidersSectionID: Hashable, Sendable {
    case providers

    var header: String? {
        switch self {
        case .providers:
            return String(localized: "providers.manage.section.configured")
        }
    }

    var footer: String? {
        nil
    }
}

nonisolated enum ManageProvidersItemID: Hashable, Sendable {
    case provider(id: String)
    case empty
}

// MARK: - DataSource (header/footer support)

private final class ManageProvidersDataSource: UITableViewDiffableDataSource<ManageProvidersSectionID, ManageProvidersItemID> {
    var footerProvider: ((ManageProvidersSectionID) -> String?)?

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sectionIdentifier(for: section)?.header
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let sectionID = sectionIdentifier(for: section) else { return nil }
        return footerProvider?(sectionID) ?? sectionID.footer
    }
}
