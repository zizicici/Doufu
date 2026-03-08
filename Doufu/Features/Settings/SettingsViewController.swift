//
//  SettingsViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import UIKit

final class SettingsViewController: UITableViewController {

    private enum Section: Int, CaseIterable {
        case general
        case chat
        case llmProviders
    }

    private enum GeneralRow: Int, CaseIterable {
        case language
    }

    private enum ChatRow: Int, CaseIterable {
        case toolPermission
    }

    private enum LLMProvidersRow: Int, CaseIterable {
        case manageProviders
        case tokenUsage
    }

    private let store = LLMProviderSettingsStore.shared
    private let projectStore = AppProjectStore.shared

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
        guard let section = Section(rawValue: section) else { return 0 }
        switch section {
        case .general:
            return GeneralRow.allCases.count
        case .chat:
            return ChatRow.allCases.count
        case .llmProviders:
            return LLMProvidersRow.allCases.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .general:
            return String(localized: "settings.section.general")
        case .chat:
            return String(localized: "settings.section.chat")
        case .llmProviders:
            return String(localized: "settings.section.llm_providers")
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .general:
            return nil
        case .chat:
            return String(localized: "settings.section.chat.footer")
        case .llmProviders:
            return String(localized: "settings.section.llm_providers.footer")
        }
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
        cell.accessoryType = .disclosureIndicator

        guard let section = Section(rawValue: indexPath.section) else { return cell }

        switch section {
        case .general:
            var configuration = cell.defaultContentConfiguration()
            configuration.image = UIImage(systemName: "globe")
            configuration.text = String(localized: "settings.general.language.title")
            configuration.secondaryText = String(localized: "settings.general.language.subtitle")
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration

        case .chat:
            let mode = projectStore.loadAppToolPermissionMode()
            var configuration = cell.defaultContentConfiguration()
            configuration.image = UIImage(systemName: "wrench")
            configuration.text = String(localized: "settings.chat.tool_permission.title")
            configuration.secondaryText = displayName(for: mode)
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration

        case .llmProviders:
            guard let row = LLMProvidersRow(rawValue: indexPath.row) else { return cell }
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
        }

        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let section = Section(rawValue: indexPath.section) else { return }

        switch section {
        case .general:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }

        case .chat:
            presentToolPermissionPicker()

        case .llmProviders:
            guard let row = LLMProvidersRow(rawValue: indexPath.row) else { return }
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

    // MARK: - Tool Permission

    private func displayName(for mode: ToolPermissionMode) -> String {
        switch mode {
        case .standard:
            return String(localized: "tool_permission.mode.standard")
        case .autoApproveNonDestructive:
            return String(localized: "tool_permission.mode.auto_non_destructive")
        case .fullAutoApprove:
            return String(localized: "tool_permission.mode.full_auto")
        }
    }

    private func presentToolPermissionPicker() {
        let currentMode = projectStore.loadAppToolPermissionMode()
        let alert = UIAlertController(
            title: String(localized: "tool_permission.picker.title"),
            message: String(localized: "tool_permission.picker.message"),
            preferredStyle: .actionSheet
        )

        for mode in ToolPermissionMode.allCases {
            let title = displayName(for: mode)
            let action = UIAlertAction(title: title, style: .default) { [weak self] _ in
                guard let self else { return }
                self.projectStore.saveAppToolPermissionMode(mode)
                self.tableView.reloadSections(IndexSet(integer: Section.chat.rawValue), with: .none)
            }
            if mode == currentMode {
                action.setValue(true, forKey: "checked")
            }
            alert.addAction(action)
        }

        alert.addAction(UIAlertAction(title: String(localized: "common.action.cancel"), style: .cancel))
        present(alert, animated: true)
    }
}
