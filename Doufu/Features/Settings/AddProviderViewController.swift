//
//  AddProviderViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import UIKit

final class AddProviderViewController: UIViewController, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var diffableDataSource: AddProviderDataSource!

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
        title = String(localized: "providers.add.title")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProviderOptionCell")

        configureDiffableDataSource()
        applySnapshot()
    }

    // MARK: - Diffable DataSource

    private func configureDiffableDataSource() {
        diffableDataSource = AddProviderDataSource(
            tableView: tableView
        ) { tableView, indexPath, itemID in
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProviderOptionCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            let kind = itemID.kind
            var configuration = cell.defaultContentConfiguration()
            configuration.text = kind.displayName
            configuration.secondaryText = kind.subtitle
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            return cell
        }
        diffableDataSource.defaultRowAnimation = .none
    }

    // MARK: - Snapshot

    private func buildSnapshot() -> NSDiffableDataSourceSnapshot<AddProviderSectionID, AddProviderItemID> {
        var snapshot = NSDiffableDataSourceSnapshot<AddProviderSectionID, AddProviderItemID>()
        snapshot.appendSections([.standard, .other])
        snapshot.appendItems(
            [.openAIResponses, .openAIChatCompletions, .anthropic],
            toSection: .standard
        )
        snapshot.appendItems(
            [.googleGemini, .openRouter, .xiaomiMiMo],
            toSection: .other
        )
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
        let controller: UIViewController
        switch itemID {
        case .openAIResponses:
            controller = ProviderAuthMethodViewController()
        case .openRouter:
            controller = ProviderAuthMethodViewController(providerKind: .openRouter)
        case .openAIChatCompletions, .anthropic, .googleGemini, .xiaomiMiMo:
            controller = ProviderAPIKeyFormViewController(providerKind: itemID.kind)
        }
        navigationController?.pushViewController(controller, animated: true)
    }
}

// MARK: - Section & Item IDs

nonisolated enum AddProviderSectionID: Hashable, Sendable {
    case standard
    case other

    var header: String? {
        switch self {
        case .standard:
            return String(localized: "providers.add.section.standard")
        case .other:
            return String(localized: "providers.add.section.other")
        }
    }

    var footer: String? {
        nil
    }
}

nonisolated enum AddProviderItemID: Hashable, Sendable {
    case openAIResponses
    case openAIChatCompletions
    case anthropic
    case googleGemini
    case openRouter
    case xiaomiMiMo

    var kind: LLMProviderRecord.Kind {
        switch self {
        case .openAIResponses: return .openAIResponses
        case .openAIChatCompletions: return .openAIChatCompletions
        case .anthropic: return .anthropic
        case .googleGemini: return .googleGemini
        case .openRouter: return .openRouter
        case .xiaomiMiMo: return .xiaomiMiMo
        }
    }
}

// MARK: - DataSource (header/footer support)

private final class AddProviderDataSource: UITableViewDiffableDataSource<AddProviderSectionID, AddProviderItemID> {
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sectionIdentifier(for: section)?.header
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sectionIdentifier(for: section)?.footer
    }
}
