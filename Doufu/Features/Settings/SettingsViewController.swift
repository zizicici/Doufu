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
        case llmProviders
        case chat
    }

    private enum GeneralRow: Int, CaseIterable {
        case language
    }

    private enum ChatRow: Int, CaseIterable {
        case toolPermission
        case pipProgress
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
        case .llmProviders:
            return LLMProvidersRow.allCases.count
        case .chat:
            return ChatRow.allCases.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .general:
            return String(localized: "settings.section.general")
        case .llmProviders:
            return String(localized: "settings.section.llm_providers")
        case .chat:
            return String(localized: "settings.section.chat")
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .llmProviders:
            return String(localized: "settings.section.llm_providers.footer")
        case .general, .chat:
            return nil
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
            var configuration = UIListContentConfiguration.valueCell()
            configuration.image = UIImage(systemName: "globe")
            configuration.text = String(localized: "settings.general.language.title")
            configuration.secondaryText = currentLanguageDisplayName()
            cell.contentConfiguration = configuration

        case .llmProviders:
            guard let row = LLMProvidersRow(rawValue: indexPath.row) else { return cell }
            var configuration = UIListContentConfiguration.valueCell()
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
            }
            cell.contentConfiguration = configuration

        case .chat:
            guard let row = ChatRow(rawValue: indexPath.row) else { return cell }
            var configuration = UIListContentConfiguration.valueCell()
            switch row {
            case .toolPermission:
                let mode = projectStore.loadAppToolPermissionMode()
                configuration.image = UIImage(systemName: "wrench")
                configuration.text = String(localized: "settings.chat.tool_permission.title")
                configuration.secondaryText = displayName(for: mode)
            case .pipProgress:
                configuration.image = UIImage(systemName: "pip")
                configuration.text = String(localized: "settings.chat.pip_progress.title")
                configuration.secondaryText = PiPProgressManager.shared.isEnabled
                    ? String(localized: "settings.chat.pip_progress.on")
                    : String(localized: "settings.chat.pip_progress.off")
            }
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

        case .chat:
            guard let row = ChatRow(rawValue: indexPath.row) else { return }
            switch row {
            case .toolPermission:
                let controller = ToolPermissionPickerViewController()
                navigationController?.pushViewController(controller, animated: true)
            case .pipProgress:
                let controller = PiPProgressPickerViewController()
                navigationController?.pushViewController(controller, animated: true)
            }
        }
    }

    // MARK: - Language

    private func currentLanguageDisplayName() -> String {
        let langCode = Bundle.main.preferredLocalizations.first ?? "en"
        let locale = Locale(identifier: langCode)
        return locale.localizedString(forIdentifier: langCode)?.localizedCapitalized ?? langCode
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
}
