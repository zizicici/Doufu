//
//  SettingsSpecificationsViewController.swift
//  Doufu
//
//  Created by Claude on 2026/03/12.
//

import SafariServices
import UIKit

@MainActor
final class SettingsSpecificationsViewController: UITableViewController {

    private enum Section: Int, CaseIterable {
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
            default:
                return nil
            }
        }
    }

    private enum SummaryRow: Int, CaseIterable {
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
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "settings.specifications.title")
        navigationItem.largeTitleDisplayMode = .never
        tableView.backgroundColor = .doufuBackground
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else { return 0 }
        switch section {
        case .summary:
            return SummaryRow.allCases.count
        case .thirdParty:
            return ThirdParty.current.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        Section(rawValue: section)?.header
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        Section(rawValue: section)?.footer
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        guard let section = Section(rawValue: indexPath.section) else { return cell }

        switch section {
        case .summary:
            guard let row = SummaryRow(rawValue: indexPath.row) else { return cell }
            var config = UIListContentConfiguration.valueCell()
            config.text = row.title
            config.secondaryText = row.value
            cell.contentConfiguration = config
            cell.accessoryType = .none
            cell.selectionStyle = .none

        case .thirdParty:
            let item = ThirdParty.current[indexPath.row]
            var config = UIListContentConfiguration.valueCell()
            config.text = item.name
            config.secondaryText = item.version
            cell.contentConfiguration = config
            cell.accessoryType = .disclosureIndicator
            cell.selectionStyle = .default
        }

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let section = Section(rawValue: indexPath.section) else { return }

        switch section {
        case .thirdParty:
            let item = ThirdParty.current[indexPath.row]
            guard let url = URL(string: item.urlString) else { return }
            let safari = SFSafariViewController(url: url)
            present(safari, animated: true)
        default:
            break
        }
    }
}
