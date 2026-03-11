//
//  SettingsViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import UIKit

@MainActor
final class SettingsViewController: UITableViewController {

    private enum Section: Int, CaseIterable {
        case general
        case llmProviders
        case project
    }

    private enum GeneralRow: Int, CaseIterable {
        case language
    }

    private enum ProjectRow: Int, CaseIterable {
        case autoCollapsePanel
        case toolPermission
        case pipProgress
    }

    private enum LLMProvidersRow: Int, CaseIterable {
        case manageProviders
        case defaultModel
        case tokenUsage
    }

    private let store = LLMProviderSettingsStore.shared
    private let projectStore = AppProjectStore.shared
    private let modelSelectionStore = ModelSelectionStateStore.shared
    private var modelSelectionObserver: NSObjectProtocol?

    init() {
        super.init(style: .insetGrouped)
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
        title = String(localized: "settings.title")
        tableView.backgroundColor = .doufuBackground
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "SettingsCell")
        modelSelectionObserver = modelSelectionStore.addObserver { [weak self] change in
            guard case .appDefault = change.scope else { return }
            self?.reloadDefaultModelRow()
        }
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
        case .project:
            return ProjectRow.allCases.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .general:
            return String(localized: "settings.section.general")
        case .llmProviders:
            return String(localized: "settings.section.llm_providers")
        case .project:
            return String(localized: "settings.section.project")
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .llmProviders:
            return String(localized: "settings.section.llm_providers.footer")
        case .general, .project:
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
            configuration.text = String(localized: "settings.general.language.title")
            configuration.secondaryText = currentLanguageDisplayName()
            cell.contentConfiguration = configuration

        case .llmProviders:
            guard let row = LLMProvidersRow(rawValue: indexPath.row) else { return cell }
            var configuration = UIListContentConfiguration.valueCell()
            switch row {
            case .manageProviders:
                let providersCount = store.loadProviders().count
                configuration.text = String(localized: "settings.providers.title")
                configuration.secondaryText = String(
                    format: String(localized: "settings.manage_providers.configured_count_format"),
                    providersCount
                )
            case .defaultModel:
                configuration.text = String(localized: "settings.default_model.title")
                configuration.secondaryText = defaultModelDisplayName()
            case .tokenUsage:
                configuration.text = String(localized: "providers.manage.item.token_usage")
            }
            cell.contentConfiguration = configuration

        case .project:
            guard let row = ProjectRow(rawValue: indexPath.row) else { return cell }
            var configuration = UIListContentConfiguration.valueCell()
            switch row {
            case .autoCollapsePanel:
                configuration.text = String(localized: "settings.project.auto_collapse_panel.title")
                configuration.secondaryText = projectStore.isAutoCollapsePanelEnabled
                    ? String(localized: "settings.common.on")
                    : String(localized: "settings.common.off")
            case .toolPermission:
                let mode = projectStore.loadAppToolPermissionMode()
                configuration.text = String(localized: "settings.chat.tool_permission.title")
                configuration.secondaryText = displayName(for: mode)
            case .pipProgress:
                configuration.text = String(localized: "settings.chat.pip_progress.title")
                configuration.secondaryText = PiPProgressManager.shared.isEnabled
                    ? String(localized: "settings.common.on")
                    : String(localized: "settings.common.off")
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
            case .defaultModel:
                let controller = DefaultModelSelectionViewController()
                navigationController?.pushViewController(controller, animated: true)
            case .tokenUsage:
                let controller = TokenUsageViewController()
                navigationController?.pushViewController(controller, animated: true)
            }

        case .project:
            guard let row = ProjectRow(rawValue: indexPath.row) else { return }
            switch row {
            case .autoCollapsePanel:
                let controller = makeAutoCollapsePanelPicker()
                navigationController?.pushViewController(controller, animated: true)
            case .toolPermission:
                let controller = makeToolPermissionPicker()
                navigationController?.pushViewController(controller, animated: true)
            case .pipProgress:
                let controller = makePiPProgressPicker()
                navigationController?.pushViewController(controller, animated: true)
            }
        }
    }

    // MARK: - Default Model

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
              let provider = store.loadProvider(id: selection.providerID)
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

    private func reloadDefaultModelRow() {
        guard isViewLoaded else { return }
        let indexPath = IndexPath(
            row: LLMProvidersRow.defaultModel.rawValue,
            section: Section.llmProviders.rawValue
        )
        guard tableView.numberOfSections > indexPath.section,
              tableView.numberOfRows(inSection: indexPath.section) > indexPath.row
        else {
            return
        }
        tableView.reloadRows(at: [indexPath], with: .none)
    }

    // MARK: - Language

    private func currentLanguageDisplayName() -> String {
        let langCode = Bundle.main.preferredLocalizations.first ?? "en"
        let locale = Locale(identifier: langCode)
        return locale.localizedString(forIdentifier: langCode)?.localizedCapitalized ?? langCode
    }

    // MARK: - Pickers

    private func makeAutoCollapsePanelPicker() -> SettingsPickerViewController {
        let onLabel = String(localized: "settings.common.on")
        let offLabel = String(localized: "settings.common.off")
        return SettingsPickerViewController(
            title: String(localized: "settings.project.auto_collapse_panel.title"),
            options: [SettingsPickerOption(onLabel), SettingsPickerOption(offLabel)],
            footerText: String(localized: "settings.project.auto_collapse_panel.footer"),
            selectedIndex: { [projectStore] in projectStore.isAutoCollapsePanelEnabled ? 0 : 1 },
            onSelect: { [projectStore] index in projectStore.isAutoCollapsePanelEnabled = (index == 0) }
        )
    }

    private func makeToolPermissionPicker() -> SettingsPickerViewController {
        let modes = ToolPermissionMode.allCases
        return SettingsPickerViewController(
            title: String(localized: "settings.chat.tool_permission.title"),
            options: modes.map { SettingsPickerOption(displayName(for: $0), subtitle: subtitle(for: $0)) },
            footerText: String(localized: "settings.chat.tool_permission.footer"),
            selectedIndex: { [projectStore] in
                let current = projectStore.loadAppToolPermissionMode()
                return modes.firstIndex(of: current) ?? 0
            },
            onSelect: { [projectStore] index in projectStore.saveAppToolPermissionMode(modes[index]) }
        )
    }

    private func makePiPProgressPicker() -> SettingsPickerViewController {
        let onLabel = String(localized: "settings.common.on")
        let offLabel = String(localized: "settings.common.off")
        return SettingsPickerViewController(
            title: String(localized: "settings.chat.pip_progress.title"),
            options: [SettingsPickerOption(onLabel), SettingsPickerOption(offLabel)],
            footerText: String(localized: "settings.chat.pip_progress.footer"),
            selectedIndex: { PiPProgressManager.shared.isEnabled ? 0 : 1 },
            onSelect: { index in PiPProgressManager.shared.isEnabled = (index == 0) }
        )
    }

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

    private func subtitle(for mode: ToolPermissionMode) -> String {
        switch mode {
        case .standard:
            return String(localized: "tool_permission.mode.standard.subtitle")
        case .autoApproveNonDestructive:
            return String(localized: "tool_permission.mode.auto_non_destructive.subtitle")
        case .fullAutoApprove:
            return String(localized: "tool_permission.mode.full_auto.subtitle")
        }
    }
}
