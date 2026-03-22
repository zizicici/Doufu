//
//  SettingsSpecificationsViewController.swift
//  Doufu
//
//  Created by Claude on 2026/03/12.
//

import SafariServices
import UIKit

@MainActor
final class SettingsSpecificationsViewController: UIViewController, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var diffableDataSource: SpecificationsDataSource!

    fileprivate enum SummaryRow: Int, CaseIterable {
        case name
        case version
        case manufacturer
        case publisher
        case license

        var title: String {
            switch self {
            case .name:
                return String(localized: "settings.specifications.name")
            case .version:
                return String(localized: "settings.specifications.version")
            case .manufacturer:
                return String(localized: "settings.specifications.manufacturer")
            case .publisher:
                return String(localized: "settings.specifications.publisher")
            case .license:
                return String(localized: "settings.specifications.license")
            }
        }

        var value: String {
            switch self {
            case .name:
                return Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String
                    ?? Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
                    ?? "Doufu"
            case .version:
                return Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
            case .manufacturer:
                return "@App君"
            case .publisher:
                return "ZIZICICI LIMITED"
            case .license:
                return "闽ICP备2023015823号"
            }
        }
    }

    private struct ThirdParty {
        let name: String
        let version: String
        let urlString: String

        static let current: [ThirdParty] = [
            ThirdParty(name: "GRDB", version: "7.10.0", urlString: "https://github.com/groue/GRDB.swift"),
            ThirdParty(name: "Runestone", version: "0.5.1", urlString: "https://github.com/simonbs/Runestone"),
            ThirdParty(name: "SwiftGitX", version: "0.4.0", urlString: "https://github.com/ibrahimcetin/SwiftGitX"),
            ThirdParty(name: "Swift Markdown", version: "0.7.3", urlString: "https://github.com/apple/swift-markdown"),
        ]
    }

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
        title = String(localized: "settings.specifications.title")
        navigationItem.largeTitleDisplayMode = .never
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")

        configureDiffableDataSource()
        applySnapshot()
    }

    // MARK: - Diffable DataSource

    private func configureDiffableDataSource() {
        diffableDataSource = SpecificationsDataSource(
            tableView: tableView
        ) { [weak self] tableView, indexPath, itemID in
            guard let self else { return UITableViewCell() }
            let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)

            switch itemID {
            case .name, .version, .manufacturer, .publisher, .license:
                let summaryRows: [SpecificationsItemID: SummaryRow] = [
                    .name: .name, .version: .version, .manufacturer: .manufacturer,
                    .publisher: .publisher, .license: .license,
                ]
                guard let summaryRow = summaryRows[itemID] else { return cell }
                var config = UIListContentConfiguration.valueCell()
                config.text = summaryRow.title
                config.secondaryText = summaryRow.value
                cell.contentConfiguration = config
                cell.accessoryType = .none
                cell.selectionStyle = .none

            case .thirdParty(let index):
                let item = ThirdParty.current[index]
                var config = UIListContentConfiguration.valueCell()
                config.text = item.name
                config.secondaryText = item.version
                cell.contentConfiguration = config
                cell.accessoryType = .disclosureIndicator
                cell.selectionStyle = .default
            }

            return cell
        }
        diffableDataSource.defaultRowAnimation = .none
    }

    // MARK: - Snapshot

    private func buildSnapshot() -> NSDiffableDataSourceSnapshot<SpecificationsSectionID, SpecificationsItemID> {
        var snapshot = NSDiffableDataSourceSnapshot<SpecificationsSectionID, SpecificationsItemID>()
        snapshot.appendSections([.summary, .thirdParty])
        snapshot.appendItems([.name, .version, .manufacturer, .publisher, .license], toSection: .summary)
        snapshot.appendItems(
            ThirdParty.current.indices.map { .thirdParty(index: $0) },
            toSection: .thirdParty
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

        switch itemID {
        case .thirdParty(let index):
            let item = ThirdParty.current[index]
            guard let url = URL(string: item.urlString) else { return }
            let safari = SFSafariViewController(url: url)
            present(safari, animated: true)
        default:
            break
        }
    }
}

// MARK: - Section & Item IDs

nonisolated enum SpecificationsSectionID: Hashable, Sendable {
    case summary
    case thirdParty

    var header: String? {
        switch self {
        case .summary:
            return nil
        case .thirdParty:
            return String(localized: "settings.specifications.third_party.header")
        }
    }

    var footer: String? {
        switch self {
        case .thirdParty:
            return String(localized: "settings.specifications.third_party.footer")
        case .summary:
            return nil
        }
    }
}

nonisolated enum SpecificationsItemID: Hashable, Sendable {
    case name
    case version
    case manufacturer
    case publisher
    case license
    case thirdParty(index: Int)
}

// MARK: - DataSource (header/footer support)

private final class SpecificationsDataSource: UITableViewDiffableDataSource<SpecificationsSectionID, SpecificationsItemID> {
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sectionIdentifier(for: section)?.header
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sectionIdentifier(for: section)?.footer
    }
}
