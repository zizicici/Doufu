//
//  ProjectSettingsViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import UIKit

@MainActor
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
        case description
    }

    private enum ChatRow: Int, CaseIterable {
        case defaultModel
        case toolPermission
    }

    private enum CheckpointRow: Int, CaseIterable {
        case history
    }

    private let projectURL: URL
    private let repositoryURL: URL
    private let projectID: String
    private let store = AppProjectStore.shared
    private let gitService = ProjectGitService.shared
    private let modelSelectionStore = ModelSelectionStateStore.shared

    private var projectNameText: String
    private var projectDescriptionText: String
    /// nil means "use app default"
    private var toolPermissionOverride: ToolPermissionMode?
    private var projectModelSelection: ModelSelection?
    private var modelSelectionObserver: NSObjectProtocol?

    init(projectURL: URL, projectName: String) {
        self.projectURL = projectURL
        repositoryURL = projectURL.appendingPathComponent("App", isDirectory: true)
        self.projectID = projectURL.lastPathComponent
        projectNameText = projectName
        projectDescriptionText = AppProjectStore.shared.loadProjectDescription(projectURL: projectURL)
        toolPermissionOverride = AppProjectStore.shared.loadProjectToolPermissionOverride(projectURL: projectURL)
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
        title = String(localized: "project_settings.title")
        tableView.keyboardDismissMode = .onDrag
        tableView.register(SettingsTextInputCell.self, forCellReuseIdentifier: SettingsTextInputCell.reuseIdentifier)
        tableView.register(SettingsCenteredButtonCell.self, forCellReuseIdentifier: SettingsCenteredButtonCell.reuseIdentifier)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "CheckpointCell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ChatSettingCell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProjectSettingCell")

        modelSelectionObserver = modelSelectionStore.addObserver { [weak self] change in
            self?.handleModelSelectionChange(change)
        }

        projectModelSelection = modelSelectionStore.loadProjectDefaultSelection(projectID: projectID)
        tableView.reloadSections(IndexSet(integer: Section.chat.rawValue), with: .none)
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
            case .description:
                let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectSettingCell", for: indexPath)
                var configuration = UIListContentConfiguration.subtitleCell()
                configuration.text = String(
                    localized: "project_settings.field.description_title",
                    defaultValue: "Description"
                )
                configuration.secondaryText = projectDescriptionPreviewText()
                configuration.secondaryTextProperties.color = .secondaryLabel
                configuration.secondaryTextProperties.numberOfLines = 3
                cell.contentConfiguration = configuration
                cell.accessoryType = .disclosureIndicator
                return cell
            }

        case .chat:
            guard let row = ChatRow(rawValue: indexPath.row) else { return UITableViewCell() }
            let cell = tableView.dequeueReusableCell(withIdentifier: "ChatSettingCell", for: indexPath)
            var configuration = cell.defaultContentConfiguration()

            switch row {
            case .defaultModel:
                configuration.text = String(localized: "project_settings.default_model.title")
                if let selection = projectModelSelection {
                    configuration.secondaryText = projectModelDisplayName(for: selection)
                } else {
                    configuration.secondaryText = String(localized: "project_settings.default_model.use_app_default")
                }
                configuration.secondaryTextProperties.color = .secondaryLabel
                cell.contentConfiguration = configuration
                cell.accessoryType = .disclosureIndicator
            case .toolPermission:
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
            }
            return cell

        case .checkpoints:
            guard let row = CheckpointRow(rawValue: indexPath.row) else {
                return UITableViewCell()
            }

            switch row {
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
            return row == .description ? indexPath : nil
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
            guard let row = ProjectRow(rawValue: indexPath.row) else { break }
            switch row {
            case .name:
                break
            case .description:
                presentProjectDescriptionEditor()
            }

        case .chat:
            guard let row = ChatRow(rawValue: indexPath.row) else { break }
            switch row {
            case .defaultModel:
                presentProjectModelSelection()
            case .toolPermission:
                presentToolPermissionPicker()
            }

        case .checkpoints:
            guard let row = CheckpointRow(rawValue: indexPath.row) else { return }
            switch row {
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
        do {
            try ProjectLifecycleCoordinator.shared.renameProject(projectURL: projectURL, newName: name)
            onProjectUpdated?(name)
        } catch {
            // Rename failed — revert text field to persisted name and reload
            // the cell so the visible text matches the persisted value.
            projectNameText = store.loadProjectName(projectURL: projectURL)
            tableView.reloadRows(
                at: [IndexPath(row: ProjectRow.name.rawValue, section: Section.project.rawValue)],
                with: .none
            )
        }
    }

    private func projectDescriptionPreviewText() -> String {
        let trimmed = projectDescriptionText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return String(
                localized: "project_settings.field.description_empty",
                defaultValue: "No description"
            )
        }
        return trimmed.replacingOccurrences(of: "\n", with: " ")
    }

    private func presentProjectDescriptionEditor() {
        let controller = ProjectDescriptionEditorViewController(
            projectURL: projectURL,
            initialDescription: projectDescriptionText
        )
        controller.onDescriptionSaved = { [weak self] savedDescription in
            guard let self else { return }
            self.projectDescriptionText = savedDescription
            self.tableView.reloadRows(
                at: [IndexPath(row: ProjectRow.description.rawValue, section: Section.project.rawValue)],
                with: .none
            )
        }
        navigationController?.pushViewController(controller, animated: true)
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
        store.saveToolPermissionMode(projectURL: projectURL, mode: mode)
        let effective = mode ?? store.loadAppToolPermissionMode()
        onToolPermissionModeChanged?(effective)
        tableView.reloadSections(IndexSet(integer: Section.chat.rawValue), with: .none)
    }

    // MARK: - Project Model Selection

    private func projectModelDisplayName(for selection: ModelSelection) -> String {
        let providerStore = LLMProviderSettingsStore.shared
        let resolution = ModelSelectionResolver.resolve(
            appDefault: nil,
            projectDefault: selection,
            threadSelection: nil,
            availableCredentials: ProviderCredentialResolver.resolveAvailableCredentials(providerStore: providerStore),
            providerStore: providerStore
        )
        guard resolution.state == .valid else {
            return String(
                localized: "project_settings.default_model.invalid",
                defaultValue: "Invalid Project Default"
            )
        }
        let providerLabel = providerStore.loadProvider(id: selection.providerID)?.label ?? selection.providerID
        let modelLabel = providerStore.availableModels(forProviderID: selection.providerID)
            .first(where: { $0.normalizedID == selection.modelRecordID.lowercased() })?
            .effectiveDisplayName ?? selection.modelRecordID
        return "\(providerLabel) · \(modelLabel)"
    }

    private func presentProjectModelSelection() {
        let controller = ProjectModelSelectionViewController(
            projectID: projectID,
            currentSelection: projectModelSelection
        )
        controller.onSelectionChanged = { [weak self] selection in
            guard let self else { return }
            self.projectModelSelection = selection
            self.modelSelectionStore.setProjectDefaultSelectionAsync(
                selection,
                projectID: self.projectID
            )
            self.tableView.reloadSections(IndexSet(integer: Section.chat.rawValue), with: .none)
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    private func handleModelSelectionChange(_ change: ModelSelectionStateStore.Change) {
        switch change.scope {
        case .appDefault:
            guard projectModelSelection == nil else { return }
        case .projectDefault(let changedProjectID):
            guard changedProjectID == projectID else { return }
        case .threadSelection:
            return
        }

        projectModelSelection = modelSelectionStore.loadProjectDefaultSelection(projectID: projectID)
        tableView.reloadSections(IndexSet(integer: Section.chat.rawValue), with: .none)
    }

    // MARK: - Actions

    private func openCheckpointsPage() {
        let controller = ProjectCheckpointsViewController(repositoryURL: repositoryURL)
        controller.onCheckpointRestored = { [weak self] in
            guard let self else { return }
            self.store.touchProjectUpdatedAt(projectID: self.projectID)
            let latestProjectName = self.store.loadProjectName(projectURL: self.projectURL)
            self.projectNameText = latestProjectName
            self.projectDescriptionText = self.store.loadProjectDescription(projectURL: self.projectURL)
            self.onProjectUpdated?(latestProjectName)
            self.tableView.reloadData()
        }
        navigationController?.pushViewController(controller, animated: true)
    }

}

// MARK: - Project Description Editor

private final class ProjectDescriptionEditorViewController: UIViewController, UITextViewDelegate {

    var onDescriptionSaved: ((String) -> Void)?

    private let projectURL: URL
    private let store = AppProjectStore.shared
    private let initialDescription: String

    private lazy var textView: UITextView = {
        let view = UITextView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .secondarySystemGroupedBackground
        view.layer.cornerRadius = 14
        view.layer.cornerCurve = .continuous
        view.font = .systemFont(ofSize: 16)
        view.textContainerInset = UIEdgeInsets(top: 14, left: 12, bottom: 14, right: 12)
        view.delegate = self
        return view
    }()

    private lazy var saveButton = UIBarButtonItem(
        title: String(localized: "common.action.save"),
        style: Self.saveButtonStyle,
        target: self,
        action: #selector(didTapSave)
    )

    private static var saveButtonStyle: UIBarButtonItem.Style {
        if #available(iOS 26.0, *) {
            return .prominent
        }
        return .plain
    }

    init(projectURL: URL, initialDescription: String) {
        self.projectURL = projectURL
        self.initialDescription = initialDescription
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(
            localized: "project_settings.description_editor.title",
            defaultValue: "Project Description"
        )
        view.backgroundColor = .systemGroupedBackground
        navigationItem.rightBarButtonItem = saveButton
        view.addSubview(textView)
        NSLayoutConstraint.activate([
            textView.topAnchor.constraint(equalTo: view.safeAreaLayoutGuide.topAnchor, constant: 16),
            textView.leadingAnchor.constraint(equalTo: view.layoutMarginsGuide.leadingAnchor),
            textView.trailingAnchor.constraint(equalTo: view.layoutMarginsGuide.trailingAnchor),
            textView.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor, constant: -16)
        ])
        textView.text = initialDescription
        updateSaveButtonState()
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        textView.becomeFirstResponder()
    }

    func textViewDidChange(_ textView: UITextView) {
        updateSaveButtonState()
    }

    @objc
    private func didTapSave() {
        let description = textView.text ?? ""
        let normalizedDescription = description.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialNormalizedDescription = initialDescription.trimmingCharacters(in: .whitespacesAndNewlines)

        guard normalizedDescription != initialNormalizedDescription else {
            navigationController?.popViewController(animated: true)
            return
        }

        do {
            try store.updateProjectDescription(projectURL: projectURL, description: description)
            onDescriptionSaved?(normalizedDescription)
            navigationController?.popViewController(animated: true)
        } catch {
            let alert = UIAlertController(
                title: String(
                    localized: "project_settings.description_editor.save_failed.title",
                    defaultValue: "Failed to Save Description"
                ),
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
            present(alert, animated: true)
        }
    }

    private func updateSaveButtonState() {
        let normalizedDescription = (textView.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        let initialNormalizedDescription = initialDescription.trimmingCharacters(in: .whitespacesAndNewlines)
        saveButton.isEnabled = normalizedDescription != initialNormalizedDescription
    }
}

// MARK: - Checkpoint History

private final class ProjectCheckpointsViewController: UITableViewController {

    var onCheckpointRestored: (() -> Void)?

    private let repositoryURL: URL
    private let gitService = ProjectGitService.shared
    private var checkpoints: [ProjectGitService.CheckpointRecord] = []
    private var currentCheckpointID: String?

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "zh_CN")
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    init(repositoryURL: URL) {
        self.repositoryURL = repositoryURL
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
        checkpoints = (try? gitService.listCheckpoints(repositoryURL: repositoryURL)) ?? []
        currentCheckpointID = gitService.currentCheckpointID(repositoryURL: repositoryURL)
        tableView.reloadData()
    }

    private func restoreCheckpoint(_ checkpoint: ProjectGitService.CheckpointRecord) {
        do {
            try gitService.restore(repositoryURL: repositoryURL, checkpointID: checkpoint.id)
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
