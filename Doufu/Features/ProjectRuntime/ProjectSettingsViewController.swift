//
//  ProjectSettingsViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import UIKit

final class ProjectSettingsViewController: UITableViewController {

    var onProjectUpdated: ((String) -> Void)?
    var onToolPermissionModeChanged: ((ToolPermissionMode) -> Void)?

    private enum Section: Int, CaseIterable {
        case project
        case chat
        case checkpoints
    }

    private enum ProjectRow: Int, CaseIterable {
        case name
        case disableEdgeSwipe
    }

    private enum ChatRow: Int, CaseIterable {
        case toolPermission
    }

    private enum CheckpointRow: Int, CaseIterable {
        case undo
        case history
    }

    private let projectURL: URL
    private let store = AppProjectStore.shared
    private let gitService = ProjectGitService.shared

    private var projectNameText: String
    /// nil means "use app default"
    private var toolPermissionOverride: ToolPermissionMode?

    init(projectURL: URL, projectName: String) {
        self.projectURL = projectURL
        projectNameText = projectName
        toolPermissionOverride = AppProjectStore.shared.loadProjectToolPermissionOverride(projectURL: projectURL)
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "project_settings.title")
        tableView.keyboardDismissMode = .onDrag
        tableView.register(SettingsTextInputCell.self, forCellReuseIdentifier: SettingsTextInputCell.reuseIdentifier)
        tableView.register(SettingsCenteredButtonCell.self, forCellReuseIdentifier: SettingsCenteredButtonCell.reuseIdentifier)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "CheckpointCell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ChatSettingCell")

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(didTapClose)
        )
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else { return 0 }
        switch section {
        case .project:
            return ProjectRow.allCases.count
        case .chat:
            return ChatRow.allCases.count
        case .checkpoints:
            return CheckpointRow.allCases.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .project:
            return String(localized: "project_settings.section.project")
        case .chat:
            return String(localized: "project_settings.section.chat")
        case .checkpoints:
            return String(localized: "project_settings.section.checkpoints")
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .project:
            return String(localized: "project_settings.footer.project_name_usage")
        case .chat:
            return String(localized: "project_settings.footer.tool_permission")
        case .checkpoints:
            return String(localized: "project_settings.footer.checkpoints")
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let section = Section(rawValue: indexPath.section) else {
            return UITableViewCell()
        }

        switch section {
        case .project:
            guard let row = ProjectRow(rawValue: indexPath.row) else { return UITableViewCell() }
            switch row {
            case .name:
                guard
                    let cell = tableView.dequeueReusableCell(
                        withIdentifier: SettingsTextInputCell.reuseIdentifier,
                        for: indexPath
                    ) as? SettingsTextInputCell
                else {
                    return UITableViewCell()
                }

                cell.configure(
                    title: String(localized: "project_settings.field.name_title"),
                    text: projectNameText,
                    placeholder: String(localized: "project_settings.field.name_placeholder"),
                    autocapitalizationType: .words
                ) { [weak self] text in
                    self?.projectNameText = text
                    self?.commitProjectName()
                }
                return cell

            case .disableEdgeSwipe:
                let cell = tableView.dequeueReusableCell(withIdentifier: "ChatSettingCell", for: indexPath)
                let isDisabled = store.isEdgeSwipeDismissDisabled(projectURL: projectURL)
                var configuration = UIListContentConfiguration.valueCell()
                configuration.text = String(localized: "project_settings.disable_edge_swipe.title")
                configuration.secondaryText = isDisabled
                    ? String(localized: "settings.common.on")
                    : String(localized: "settings.common.off")
                cell.contentConfiguration = configuration
                cell.accessoryType = .disclosureIndicator
                return cell
            }

        case .chat:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ChatSettingCell", for: indexPath)
            var configuration = cell.defaultContentConfiguration()
            configuration.text = String(localized: "project_settings.chat.tool_permission.title")
            if let override = toolPermissionOverride {
                configuration.secondaryText = displayName(for: override)
            } else {
                let appDefault = store.loadAppToolPermissionMode()
                configuration.secondaryText = String(
                    format: String(localized: "project_settings.chat.tool_permission.default_format"),
                    displayName(for: appDefault)
                )
            }
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.accessoryType = .disclosureIndicator
            return cell

        case .checkpoints:
            guard let row = CheckpointRow(rawValue: indexPath.row) else {
                return UITableViewCell()
            }

            switch row {
            case .undo:
                guard
                    let cell = tableView.dequeueReusableCell(
                        withIdentifier: SettingsCenteredButtonCell.reuseIdentifier,
                        for: indexPath
                    ) as? SettingsCenteredButtonCell
                else {
                    return UITableViewCell()
                }
                let hasCheckpoint = gitService.hasCheckpoint(projectURL: projectURL)
                cell.configure(
                    title: String(localized: "project_settings.checkpoint.undo_button"),
                    isEnabled: hasCheckpoint
                )
                return cell

            case .history:
                let cell = tableView.dequeueReusableCell(withIdentifier: "CheckpointCell", for: indexPath)
                var configuration = cell.defaultContentConfiguration()
                configuration.text = String(localized: "project_settings.checkpoint.history_title")
                configuration.secondaryText = String(localized: "project_settings.checkpoint.history_subtitle")
                configuration.secondaryTextProperties.color = .secondaryLabel
                cell.contentConfiguration = configuration
                cell.accessoryType = .disclosureIndicator
                return cell
            }
        }
    }

    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard let section = Section(rawValue: indexPath.section) else { return nil }
        switch section {
        case .project:
            guard let row = ProjectRow(rawValue: indexPath.row) else { return nil }
            return row == .disableEdgeSwipe ? indexPath : nil
        case .chat:
            return indexPath
        case .checkpoints:
            return indexPath
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard let section = Section(rawValue: indexPath.section) else { return }

        switch section {
        case .project:
            guard ProjectRow(rawValue: indexPath.row) == .disableEdgeSwipe else { break }
            let controller = ProjectEdgeSwipeDismissPickerViewController(projectURL: projectURL)
            navigationController?.pushViewController(controller, animated: true)

        case .chat:
            presentToolPermissionPicker()

        case .checkpoints:
            guard let row = CheckpointRow(rawValue: indexPath.row) else { return }
            switch row {
            case .undo:
                undoLastCheckpoint()
            case .history:
                openCheckpointsPage()
            }
        }
    }

    // MARK: - Project Name Auto-Save

    private func commitProjectName() {
        var name = projectNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        if name.isEmpty {
            name = String(localized: "project_settings.unnamed_project")
            projectNameText = name
        }
        try? store.updateProjectName(projectURL: projectURL, name: name)
        onProjectUpdated?(name)
    }

    // MARK: - Tool Permission Picker

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
        let alert = UIAlertController(
            title: String(localized: "tool_permission.picker.title"),
            message: String(localized: "tool_permission.picker.message"),
            preferredStyle: .actionSheet
        )

        // "Use Default" option
        let defaultAction = UIAlertAction(
            title: String(localized: "project_settings.chat.tool_permission.use_default"),
            style: .default
        ) { [weak self] _ in
            self?.applyToolPermissionOverride(nil)
        }
        if toolPermissionOverride == nil {
            defaultAction.setValue(true, forKey: "checked")
        }
        alert.addAction(defaultAction)

        for mode in ToolPermissionMode.allCases {
            let title = displayName(for: mode)
            let action = UIAlertAction(title: title, style: .default) { [weak self] _ in
                self?.applyToolPermissionOverride(mode)
            }
            if mode == toolPermissionOverride {
                action.setValue(true, forKey: "checked")
            }
            alert.addAction(action)
        }

        alert.addAction(UIAlertAction(title: String(localized: "common.action.cancel"), style: .cancel))
        present(alert, animated: true)
    }

    private func applyToolPermissionOverride(_ mode: ToolPermissionMode?) {
        toolPermissionOverride = mode
        try? store.saveToolPermissionMode(projectURL: projectURL, mode: mode)
        let effective = mode ?? store.loadAppToolPermissionMode()
        onToolPermissionModeChanged?(effective)
        tableView.reloadSections(IndexSet(integer: Section.chat.rawValue), with: .none)
    }

    // MARK: - Actions

    @objc
    private func didTapClose() {
        dismiss(animated: true)
    }

    private func undoLastCheckpoint() {
        let alert = UIAlertController(
            title: String(localized: "checkpoint.alert.undo.title"),
            message: String(localized: "checkpoint.alert.undo.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "checkpoint.action.undo"), style: .destructive) { [weak self] _ in
            self?.performUndo()
        })
        present(alert, animated: true)
    }

    private func performUndo() {
        do {
            let didUndo = try gitService.undo(projectURL: projectURL)
            if didUndo {
                let latestProjectName = store.loadProjectName(projectURL: projectURL)
                projectNameText = latestProjectName
                onProjectUpdated?(latestProjectName)
                tableView.reloadData()

                let alert = UIAlertController(
                    title: String(localized: "checkpoint.alert.undo_done.title"),
                    message: String(localized: "checkpoint.alert.undo_done.message"),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
                present(alert, animated: true)
            }
        } catch {
            let alert = UIAlertController(
                title: String(localized: "checkpoint.alert.undo_failed.title"),
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
            present(alert, animated: true)
        }
    }

    private func openCheckpointsPage() {
        let controller = ProjectCheckpointsViewController(projectURL: projectURL)
        controller.onCheckpointRestored = { [weak self] in
            guard let self else { return }
            let latestProjectName = self.store.loadProjectName(projectURL: self.projectURL)
            self.projectNameText = latestProjectName
            self.onProjectUpdated?(latestProjectName)
            self.tableView.reloadData()
        }
        navigationController?.pushViewController(controller, animated: true)
    }
}

// MARK: - Checkpoint History

private final class ProjectCheckpointsViewController: UITableViewController {

    var onCheckpointRestored: (() -> Void)?

    private let projectURL: URL
    private let gitService = ProjectGitService.shared
    private var checkpoints: [ProjectGitService.CheckpointRecord] = []
    private var currentCheckpointID: String?

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    init(projectURL: URL) {
        self.projectURL = projectURL
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "checkpoint_list.title")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "CheckpointRow")
        reloadCheckpoints()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadCheckpoints()
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        max(1, checkpoints.count)
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "CheckpointRow", for: indexPath)

        guard !checkpoints.isEmpty, indexPath.row < checkpoints.count else {
            var configuration = cell.defaultContentConfiguration()
            configuration.text = String(localized: "checkpoint_list.empty")
            configuration.textProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.selectionStyle = .none
            cell.accessoryType = .none
            return cell
        }

        let checkpoint = checkpoints[indexPath.row]
        var configuration = cell.defaultContentConfiguration()
        configuration.text = checkpoint.userMessage.isEmpty
            ? dateFormatter.string(from: checkpoint.date)
            : checkpoint.userMessage
        configuration.secondaryText = dateFormatter.string(from: checkpoint.date)
        configuration.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = configuration
        cell.selectionStyle = .default
        cell.accessoryType = checkpoint.id == currentCheckpointID ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }

        guard !checkpoints.isEmpty, indexPath.row < checkpoints.count else { return }
        let checkpoint = checkpoints[indexPath.row]

        let alert = UIAlertController(
            title: String(localized: "checkpoint_list.alert.restore.title"),
            message: String(
                format: String(localized: "checkpoint_list.alert.restore.message_format"),
                dateFormatter.string(from: checkpoint.date)
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "checkpoint_list.action.restore"), style: .destructive) { [weak self] _ in
            self?.restoreCheckpoint(checkpoint)
        })
        present(alert, animated: true)
    }

    private func reloadCheckpoints() {
        checkpoints = (try? gitService.listCheckpoints(projectURL: projectURL)) ?? []
        currentCheckpointID = gitService.currentCheckpointID(projectURL: projectURL)
        tableView.reloadData()
    }

    private func restoreCheckpoint(_ checkpoint: ProjectGitService.CheckpointRecord) {
        do {
            try gitService.restore(projectURL: projectURL, checkpointID: checkpoint.id)
            onCheckpointRestored?()
            reloadCheckpoints()

            let alert = UIAlertController(
                title: String(localized: "checkpoint_list.alert.restored.title"),
                message: String(localized: "checkpoint_list.alert.restored.message"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default) { [weak self] _ in
                self?.navigationController?.popViewController(animated: true)
            })
            present(alert, animated: true)
        } catch {
            let alert = UIAlertController(
                title: String(localized: "checkpoint_list.alert.restore_failed.title"),
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
            present(alert, animated: true)
        }
    }
}
