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
        title = "设置"
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
        return 1
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard Section(rawValue: section) == .llmProviders else {
            return nil
        }
        return "LLM Providers"
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard Section(rawValue: section) == .llmProviders else {
            return nil
        }
        return "Provider 配置仅保存在本地设备。"
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
        cell.accessoryType = .disclosureIndicator

        let providersCount = store.loadProviders().count
        var configuration = cell.defaultContentConfiguration()
        configuration.image = UIImage(systemName: "server.rack")
        configuration.text = "Manage Providers"
        configuration.secondaryText = "\(providersCount) configured"
        configuration.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = configuration
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard Section(rawValue: indexPath.section) == .llmProviders else {
            return
        }

        let controller = ManageProvidersViewController()
        navigationController?.pushViewController(controller, animated: true)
    }
}
