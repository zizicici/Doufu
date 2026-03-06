//
//  SettingsViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import UIKit

final class SettingsViewController: UITableViewController {

    private enum Section: Int, CaseIterable {
        case llmProviders
    }

    private enum LLMProvidersRow: Int, CaseIterable {
        case manageProviders
        case tokenUsage
    }

    private let store = LLMProviderSettingsStore.shared

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "settings.title")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "SettingsCell")
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard Section(rawValue: section) == .llmProviders else {
            return 0
        }
        return LLMProvidersRow.allCases.count
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard Section(rawValue: section) == .llmProviders else {
            return nil
        }
        return String(localized: "settings.section.llm_providers")
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard Section(rawValue: section) == .llmProviders else {
            return nil
        }
        return String(localized: "settings.section.llm_providers.footer")
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
        cell.accessoryType = .disclosureIndicator

        guard let row = LLMProvidersRow(rawValue: indexPath.row) else {
            return cell
        }

        var configuration = cell.defaultContentConfiguration()
        switch row {
        case .manageProviders:
            let providersCount = store.loadProviders().count
            configuration.image = UIImage(systemName: "server.rack")
            configuration.text = String(localized: "settings.manage_providers.title")
            configuration.secondaryText = String(
                format: String(localized: "settings.manage_providers.configured_count_format"),
                providersCount
            )
        case .tokenUsage:
            configuration.image = UIImage(systemName: "chart.bar.xaxis")
            configuration.text = String(localized: "providers.manage.item.token_usage")
            configuration.secondaryText = String(localized: "providers.manage.item.token_usage.subtitle")
        }
        configuration.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = configuration
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .llmProviders else {
            return
        }
        guard let row = LLMProvidersRow(rawValue: indexPath.row) else {
            return
        }
        switch row {
        case .manageProviders:
            let controller = ManageProvidersViewController()
            navigationController?.pushViewController(controller, animated: true)
        case .tokenUsage:
            let controller = TokenUsageViewController()
            navigationController?.pushViewController(controller, animated: true)
        }
    }
}
