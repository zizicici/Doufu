//
//  LLMQuickSetupViewController.swift
//  Doufu
//
//  Created by Claude on 2026/03/09.
//

import UIKit

@MainActor
final class LLMQuickSetupViewController: UIViewController, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var diffableDataSource: LLMQuickSetupDataSource!

    var onDismiss: (() -> Void)?

    private let store = LLMProviderSettingsStore.shared
    private let modelSelectionStore = ModelSelectionStateStore.shared
    private var modelSelectionObserver: NSObjectProtocol?

    init() {
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let modelSelectionObserver {
            NotificationCenter.default.removeObserver(modelSelectionObserver)
        }
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
        title = String(localized: "settings.section.llm_providers")
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .done,
            target: self,
            action: #selector(didTapDone)
        )
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")

        configureDiffableDataSource()

        modelSelectionObserver = modelSelectionStore.addObserver { [weak self] change in
            guard case .appDefault = change.scope else { return }
            self?.applySnapshot()
        }
        applySnapshot()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applySnapshot()
    }

    // MARK: - Diffable DataSource

    private func configureDiffableDataSource() {
        diffableDataSource = LLMQuickSetupDataSource(
            tableView: tableView
        ) { [weak self] tableView, indexPath, itemID in
            guard let self else { return UITableViewCell() }
            let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            var configuration = UIListContentConfiguration.valueCell()
            switch itemID {
            case .manageProviders(let subtitle):
                configuration.text = String(localized: "settings.providers.title")
                configuration.secondaryText = subtitle
            case .defaultModel(let subtitle):
                configuration.text = String(localized: "settings.default_model.title")
                configuration.secondaryText = subtitle
            }
            cell.contentConfiguration = configuration
            return cell
        }
        diffableDataSource.defaultRowAnimation = .none
    }

    // MARK: - Snapshot

    private func buildSnapshot() -> NSDiffableDataSourceSnapshot<LLMQuickSetupSectionID, LLMQuickSetupItemID> {
        var snapshot = NSDiffableDataSourceSnapshot<LLMQuickSetupSectionID, LLMQuickSetupItemID>()
        snapshot.appendSections([.main])

        let count = store.loadProviders().count
        let providersSubtitle = String(
            format: String(localized: "settings.manage_providers.configured_count_format"),
            count
        )
        snapshot.appendItems([
            .manageProviders(subtitle: providersSubtitle),
            .defaultModel(subtitle: defaultModelDisplayName()),
        ], toSection: .main)

        return snapshot
    }

    private func applySnapshot() {
        var snapshot = buildSnapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        diffableDataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Selection

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath) else { return }
        switch itemID {
        case .manageProviders:
            let controller = ManageProvidersViewController()
            navigationController?.pushViewController(controller, animated: true)
        case .defaultModel:
            let controller = DefaultModelSelectionViewController()
            navigationController?.pushViewController(controller, animated: true)
        }
    }

    @objc
    private func didTapDone() {
        dismiss(animated: true) { [weak self] in
            self?.onDismiss?()
        }
    }

    private func defaultModelDisplayName() -> String {
        guard let selection = modelSelectionStore.loadAppDefaultSelection() else {
            return String(localized: "settings.default_model.not_set")
        }
        let resolution = ModelSelectionResolver.resolve(
            appDefault: selection,
            projectDefault: nil,
            threadSelection: nil,
            availableCredentials: ProviderCredentialResolver.resolveAvailableCredentials(providerStore: store),
            providerStore: store
        )
        guard resolution.state == .valid,
              let resolvedProviderID = resolution.providerID,
              let provider = store.loadProvider(id: resolvedProviderID)
        else {
            return String(
                localized: "settings.default_model.invalid",
                defaultValue: "Invalid App Default"
            )
        }
        let model = provider.availableModels.first(where: {
            $0.id.caseInsensitiveCompare(selection.modelRecordID) == .orderedSame
        })
        let modelName = model?.effectiveDisplayName ?? selection.modelRecordID
        return provider.label + " · " + modelName
    }
}

// MARK: - Section & Item IDs

nonisolated enum LLMQuickSetupSectionID: Hashable, Sendable {
    case main

    var header: String? {
        switch self {
        case .main:
            return String(localized: "settings.section.llm_providers")
        }
    }

    var footer: String? {
        nil
    }
}

nonisolated enum LLMQuickSetupItemID: Hashable, Sendable {
    case manageProviders(subtitle: String)
    case defaultModel(subtitle: String)
}

// MARK: - DataSource (header/footer support)

private final class LLMQuickSetupDataSource: UITableViewDiffableDataSource<LLMQuickSetupSectionID, LLMQuickSetupItemID> {
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sectionIdentifier(for: section)?.header
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sectionIdentifier(for: section)?.footer
    }
}
