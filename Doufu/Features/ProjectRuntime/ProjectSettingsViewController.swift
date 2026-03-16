//
//  ProjectSettingsViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import UIKit

@MainActor
final class ProjectSettingsViewController: UITableViewController {

    private let projectURL: URL
    private let repositoryURL: URL
    private let projectID: String
    private let doufuBridge: DoufuBridge?
    private let store = AppProjectStore.shared
    private let gitService = ProjectGitService.shared
    private let modelSelectionStore = ModelSelectionStateStore.shared

    private let capabilityStore = ProjectCapabilityStore.shared

    private var projectNameText: String
    private var projectDescriptionText: String
    /// nil means "use app default"
    private var toolPermissionOverride: ToolPermissionMode?
    private var projectModelSelection: ModelSelection?
    private var projectCapabilities: [(type: CapabilityType, state: CapabilityState)] = []
    private var modelSelectionObserver: NSObjectProtocol?
    private var projectChangeObserver: NSObjectProtocol?

    /// Called after localStorage or IndexedDB is cleared so the workspace can reload its webView.
    var onStorageCleared: (() -> Void)?

    private var diffableDataSource: UITableViewDiffableDataSource<ProjectSettingsSectionID, ProjectSettingsItemID>!

    init(projectURL: URL, projectName: String, doufuBridge: DoufuBridge? = nil) {
        self.projectURL = projectURL
        repositoryURL = projectURL.appendingPathComponent("App", isDirectory: true)
        self.projectID = projectURL.lastPathComponent
        self.doufuBridge = doufuBridge
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
        if let projectChangeObserver {
            NotificationCenter.default.removeObserver(projectChangeObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "project_settings.title")
        tableView.backgroundColor = .doufuBackground
        tableView.keyboardDismissMode = .onDrag
        tableView.register(SettingsTextInputCell.self, forCellReuseIdentifier: SettingsTextInputCell.reuseIdentifier)
        tableView.register(SettingsCenteredButtonCell.self, forCellReuseIdentifier: SettingsCenteredButtonCell.reuseIdentifier)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "CheckpointCell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ChatSettingCell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProjectSettingCell")
        tableView.register(CapabilitySwitchCell.self, forCellReuseIdentifier: CapabilitySwitchCell.reuseIdentifier)

        configureDiffableDataSource()

        modelSelectionObserver = modelSelectionStore.addObserver { [weak self] change in
            self?.handleModelSelectionChange(change)
        }
        projectChangeObserver = ProjectChangeCenter.shared.addObserver(projectID: projectID) { [weak self] change in
            self?.handleProjectChange(change)
        }

        projectModelSelection = modelSelectionStore.loadProjectDefaultSelection(projectID: projectID)
        projectCapabilities = capabilityStore.loadRequestedCapabilities(projectID: projectID)
        applySnapshot()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        refreshProjectSnapshotFromStore()
    }

    // MARK: - Diffable DataSource

    private func configureDiffableDataSource() {
        diffableDataSource = ProjectSettingsDataSource(
            tableView: tableView
        ) { [weak self] tableView, indexPath, itemID in
            guard let self else { return UITableViewCell() }
            return self.cell(for: tableView, indexPath: indexPath, itemID: itemID)
        }
        diffableDataSource.defaultRowAnimation = .none
    }

    private func cell(
        for tableView: UITableView,
        indexPath: IndexPath,
        itemID: ProjectSettingsItemID
    ) -> UITableViewCell {
        switch itemID {
        case .projectName:
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

        case .projectDescription:
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

        case .defaultModel:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ChatSettingCell", for: indexPath)
            var configuration = cell.defaultContentConfiguration()
            configuration.text = String(localized: "project_settings.default_model.title")
            if let selection = projectModelSelection {
                configuration.secondaryText = projectModelDisplayName(for: selection)
            } else {
                configuration.secondaryText = String(localized: "project_settings.default_model.use_app_default")
            }
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.accessoryType = .disclosureIndicator
            return cell

        case .toolPermission:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ChatSettingCell", for: indexPath)
            var configuration = cell.defaultContentConfiguration()
            configuration.text = String(localized: "project_settings.chat.tool_permission.title")
            if let override = toolPermissionOverride {
                configuration.secondaryText = ToolPermissionPickerViewController.displayName(for: override)
            } else {
                let appDefault = store.loadAppToolPermissionMode()
                configuration.secondaryText = String(
                    format: String(localized: "project_settings.chat.tool_permission.default_format"),
                    ToolPermissionPickerViewController.displayName(for: appDefault)
                )
            }
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.accessoryType = .disclosureIndicator
            return cell

        case .capability(let typeKey, let isAllowed):
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: CapabilitySwitchCell.reuseIdentifier,
                for: indexPath
            ) as? CapabilitySwitchCell else {
                return UITableViewCell()
            }
            let capType = CapabilityType.from(dbKey: typeKey)
            cell.configure(
                title: capType?.displayName ?? typeKey,
                isOn: isAllowed
            ) { [weak self] newValue in
                guard let self, let capType else { return }
                let newState: CapabilityState = newValue ? .allowed : .denied
                self.capabilityStore.saveCapability(
                    projectID: self.projectID,
                    type: capType,
                    state: newState
                )
                CapabilityActivityStore.shared.recordEvent(
                    projectID: self.projectID,
                    capability: capType,
                    event: .changed,
                    detail: newValue ? CapabilityActivityDetail.allowed : CapabilityActivityDetail.denied
                )
                self.projectCapabilities = self.capabilityStore.loadRequestedCapabilities(projectID: self.projectID)
                self.applySnapshot()
            }
            return cell

        case .codeScan:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectSettingCell", for: indexPath)
            var configuration = cell.defaultContentConfiguration()
            configuration.text = String(
                localized: "project_settings.code_scan.title",
                defaultValue: "Code Review"
            )
            configuration.secondaryText = String(
                localized: "project_settings.code_scan.subtitle",
                defaultValue: "Static analysis and LLM review"
            )
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.accessoryType = .disclosureIndicator
            return cell

        case .capabilityActivityLog:
            let cell = tableView.dequeueReusableCell(withIdentifier: "CheckpointCell", for: indexPath)
            var configuration = cell.defaultContentConfiguration()
            configuration.text = String(localized: "capability.activity_log.title")
            cell.contentConfiguration = configuration
            cell.accessoryType = .disclosureIndicator
            return cell

        case .checkpointHistory:
            let cell = tableView.dequeueReusableCell(withIdentifier: "CheckpointCell", for: indexPath)
            var configuration = cell.defaultContentConfiguration()
            configuration.text = String(localized: "project_settings.checkpoint.history_title")
            configuration.secondaryText = String(localized: "project_settings.checkpoint.history_subtitle")
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.accessoryType = .disclosureIndicator
            return cell

        case .clearLocalStorage:
            guard
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: SettingsCenteredButtonCell.reuseIdentifier,
                    for: indexPath
                ) as? SettingsCenteredButtonCell
            else {
                return UITableViewCell()
            }
            cell.configure(
                title: String(
                    localized: "project_settings.storage.clear_local_storage",
                    defaultValue: "Clear localStorage"
                ),
                tintColor: .systemRed
            )
            return cell

        case .clearIndexedDB:
            guard
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: SettingsCenteredButtonCell.reuseIdentifier,
                    for: indexPath
                ) as? SettingsCenteredButtonCell
            else {
                return UITableViewCell()
            }
            cell.configure(
                title: String(
                    localized: "project_settings.storage.clear_indexeddb",
                    defaultValue: "Clear IndexedDB"
                ),
                tintColor: .systemRed
            )
            return cell
        }
    }

    // MARK: - Snapshot

    private func buildSnapshot() -> NSDiffableDataSourceSnapshot<ProjectSettingsSectionID, ProjectSettingsItemID> {
        var snapshot = NSDiffableDataSourceSnapshot<ProjectSettingsSectionID, ProjectSettingsItemID>()
        var sections: [ProjectSettingsSectionID] = [.project, .chat]
        if !projectCapabilities.isEmpty { sections.append(.capabilities) }
        sections.append(.codeScan)
        sections.append(.checkpoints)
        if doufuBridge != nil { sections.append(.storage) }
        snapshot.appendSections(sections)
        snapshot.appendItems([.projectName, .projectDescription], toSection: .project)
        snapshot.appendItems([.defaultModel, .toolPermission], toSection: .chat)
        if !projectCapabilities.isEmpty {
            let items = projectCapabilities.map { entry in
                ProjectSettingsItemID.capability(
                    type: entry.type.dbKey,
                    isAllowed: entry.state == .allowed
                )
            }
            snapshot.appendItems(items, toSection: .capabilities)
            snapshot.appendItems([.capabilityActivityLog], toSection: .capabilities)
        }
        snapshot.appendItems([.codeScan], toSection: .codeScan)
        snapshot.appendItems([.checkpointHistory], toSection: .checkpoints)
        if doufuBridge != nil {
            snapshot.appendItems([.clearLocalStorage, .clearIndexedDB], toSection: .storage)
        }
        return snapshot
    }

    private func applySnapshot() {
        var snapshot = buildSnapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        diffableDataSource.apply(snapshot, animatingDifferences: false)
    }

    // Section headers & footers are handled by ProjectSettingsDataSource.

    // MARK: - Selection

    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath) else { return nil }
        switch itemID {
        case .projectName, .capability:
            return nil
        case .projectDescription, .defaultModel, .toolPermission, .codeScan, .checkpointHistory,
             .clearLocalStorage, .clearIndexedDB, .capabilityActivityLog:
            return indexPath
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath) else { return }

        switch itemID {
        case .projectName, .capability:
            break
        case .projectDescription:
            presentProjectDescriptionEditor()
        case .defaultModel:
            presentProjectModelSelection()
        case .toolPermission:
            presentToolPermissionPicker()
        case .codeScan:
            presentCodeScan()
        case .capabilityActivityLog:
            let vc = CapabilityActivityLogViewController(filter: .project(id: projectID))
            navigationController?.pushViewController(vc, animated: true)
        case .checkpointHistory:
            openCheckpointsPage()
        case .clearLocalStorage:
            confirmClearLocalStorage()
        case .clearIndexedDB:
            confirmClearIndexedDB()
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
        } catch {
            projectNameText = store.loadProjectName(projectURL: projectURL)
            applySnapshot()
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
            self.applySnapshot()
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    // MARK: - Tool Permission Picker

    private func presentToolPermissionPicker() {
        let currentMode = toolPermissionOverride ?? store.loadAppToolPermissionMode()
        let controller = ToolPermissionPickerViewController(
            currentMode: currentMode,
            showsUseDefault: true,
            isUsingDefault: toolPermissionOverride == nil
        )
        controller.onSelectionChanged = { [weak self] mode in
            self?.applyToolPermissionOverride(mode)
        }
        navigationController?.pushViewController(controller, animated: true)
    }

    private func applyToolPermissionOverride(_ mode: ToolPermissionMode?) {
        toolPermissionOverride = mode
        store.saveToolPermissionMode(projectURL: projectURL, mode: mode)
        ProjectChangeCenter.shared.notifyToolPermissionChanged(projectID: projectID)
        applySnapshot()
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
            self.applySnapshot()
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
        applySnapshot()
    }

    private func handleProjectChange(_ change: ProjectChangeCenter.Change) {
        guard change.kind == .checkpointRestored else { return }
        refreshProjectSnapshotFromStore()
    }

    private func refreshProjectSnapshotFromStore() {
        projectNameText = store.loadProjectName(projectURL: projectURL)
        projectDescriptionText = store.loadProjectDescription(projectURL: projectURL)
        toolPermissionOverride = store.loadProjectToolPermissionOverride(projectURL: projectURL)
        projectCapabilities = capabilityStore.loadRequestedCapabilities(projectID: projectID)
        applySnapshot()
    }

    // MARK: - Clear Storage

    private func confirmClearLocalStorage() {
        let alert = UIAlertController(
            title: String(
                localized: "project_settings.storage.clear_local_storage.alert.title",
                defaultValue: "Clear localStorage"
            ),
            message: String(
                localized: "project_settings.storage.clear_local_storage.alert.message",
                defaultValue: "All localStorage data for this project will be deleted. The web page will reload."
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(
            title: String(localized: "project_settings.storage.clear", defaultValue: "Clear"),
            style: .destructive
        ) { [weak self] _ in
            self?.doufuBridge?.clearLocalStorage()
            self?.onStorageCleared?()
        })
        present(alert, animated: true)
    }

    private func confirmClearIndexedDB() {
        let alert = UIAlertController(
            title: String(
                localized: "project_settings.storage.clear_indexeddb.alert.title",
                defaultValue: "Clear IndexedDB"
            ),
            message: String(
                localized: "project_settings.storage.clear_indexeddb.alert.message",
                defaultValue: "All IndexedDB data for this project will be deleted. The web page will reload."
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(
            title: String(localized: "project_settings.storage.clear", defaultValue: "Clear"),
            style: .destructive
        ) { [weak self] _ in
            self?.doufuBridge?.clearIndexedDB()
            self?.onStorageCleared?()
        })
        present(alert, animated: true)
    }

    // MARK: - Code Scan

    private func presentCodeScan() {
        let appURL = projectURL.appendingPathComponent("App", isDirectory: true)
        let scanVC = ImportScanViewController(appURL: appURL, projectURL: projectURL, projectName: projectNameText)
        let nav = UINavigationController(rootViewController: scanVC)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    // MARK: - Actions

    private func openCheckpointsPage() {
        let controller = ProjectCheckpointsViewController(
            repositoryURL: repositoryURL,
            projectID: projectID
        )
        navigationController?.pushViewController(controller, animated: true)
    }

}

// MARK: - DataSource (header/footer support)

private final class ProjectSettingsDataSource: UITableViewDiffableDataSource<ProjectSettingsSectionID, ProjectSettingsItemID> {
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sectionIdentifier(for: section)?.header
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sectionIdentifier(for: section)?.footer
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
        view.backgroundColor = .doufuBackground
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
            ProjectChangeCenter.shared.notifyProjectDescriptionChanged(projectID: projectURL.lastPathComponent)
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
    private let repositoryURL: URL
    private let projectID: String
    private let gitService = ProjectGitService.shared
    private var checkpoints: [ProjectGitService.CheckpointRecord] = []
    private var currentCheckpointID: String?

    private var diffableDataSource: UITableViewDiffableDataSource<CheckpointSectionID, CheckpointItemID>!

    private lazy var dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale.autoupdatingCurrent
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter
    }()

    init(repositoryURL: URL, projectID: String) {
        self.repositoryURL = repositoryURL
        self.projectID = projectID
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "checkpoint_list.title")
        tableView.backgroundColor = .doufuBackground
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "CheckpointRow")
        configureDiffableDataSource()
        applySnapshot()
        reloadCheckpoints()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadCheckpoints()
    }

    // MARK: - Diffable DataSource

    private func configureDiffableDataSource() {
        diffableDataSource = UITableViewDiffableDataSource<CheckpointSectionID, CheckpointItemID>(
            tableView: tableView
        ) { [weak self] tableView, indexPath, itemID in
            guard let self else { return UITableViewCell() }
            return self.cell(for: tableView, indexPath: indexPath, itemID: itemID)
        }
        diffableDataSource.defaultRowAnimation = .none
    }

    private func cell(
        for tableView: UITableView,
        indexPath: IndexPath,
        itemID: CheckpointItemID
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "CheckpointRow", for: indexPath)
        var configuration = cell.defaultContentConfiguration()

        switch itemID {
        case .empty:
            configuration.text = String(localized: "checkpoint_list.empty")
            configuration.textProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.selectionStyle = .none
            cell.accessoryType = .none
            return cell

        case .checkpoint(let id, let isCurrent):
            guard let checkpoint = checkpoints.first(where: { $0.id == id }) else {
                cell.contentConfiguration = configuration
                return cell
            }
            configuration.text = checkpoint.userMessage.isEmpty
                ? dateFormatter.string(from: checkpoint.date)
                : checkpoint.userMessage
            configuration.secondaryText = dateFormatter.string(from: checkpoint.date)
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.selectionStyle = .default
            cell.accessoryType = isCurrent ? .checkmark : .none
            return cell
        }
    }

    // MARK: - Snapshot

    private func buildSnapshot() -> NSDiffableDataSourceSnapshot<CheckpointSectionID, CheckpointItemID> {
        var snapshot = NSDiffableDataSourceSnapshot<CheckpointSectionID, CheckpointItemID>()
        snapshot.appendSections([.checkpoints])

        if checkpoints.isEmpty {
            snapshot.appendItems([.empty], toSection: .checkpoints)
        } else {
            let items = checkpoints.map { checkpoint in
                CheckpointItemID.checkpoint(
                    id: checkpoint.id,
                    isCurrent: checkpoint.id == currentCheckpointID
                )
            }
            snapshot.appendItems(items, toSection: .checkpoints)
        }
        return snapshot
    }

    private func applySnapshot() {
        var snapshot = buildSnapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        diffableDataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Selection

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath) else { return }

        switch itemID {
        case .empty:
            return
        case .checkpoint(let id, _):
            guard let checkpoint = checkpoints.first(where: { $0.id == id }) else { return }
            presentRestoreAlert(for: checkpoint)
        }
    }

    private func presentRestoreAlert(for checkpoint: ProjectGitService.CheckpointRecord) {
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

    // MARK: - Data Loading

    private var isRestoring = false
    private var reloadTask: Task<Void, Never>?

    private func reloadCheckpoints() {
        reloadTask?.cancel()
        let repositoryURL = self.repositoryURL
        let gitService = self.gitService
        reloadTask = Task { [weak self] in
            let (checkpoints, currentID) = await Task.detached(priority: .userInitiated) {
                let list = (try? gitService.listCheckpoints(repositoryURL: repositoryURL)) ?? []
                let current = gitService.currentCheckpointID(repositoryURL: repositoryURL)
                return (list, current)
            }.value
            guard !Task.isCancelled, let self else { return }
            self.checkpoints = checkpoints
            self.currentCheckpointID = currentID
            self.applySnapshot()
        }
    }

    private func restoreCheckpoint(_ checkpoint: ProjectGitService.CheckpointRecord) {
        guard !isRestoring else { return }
        isRestoring = true
        tableView.isUserInteractionEnabled = false

        let repositoryURL = self.repositoryURL
        let gitService = self.gitService
        let projectID = self.projectID
        let checkpointID = checkpoint.id

        Task { [weak self] in
            let error: Error? = await Task.detached(priority: .userInitiated) {
                do {
                    try gitService.restore(repositoryURL: repositoryURL, checkpointID: checkpointID)
                    return nil
                } catch {
                    return error
                }
            }.value

            if error == nil {
                ProjectChangeCenter.shared.notifyCheckpointRestored(projectID: projectID)
            }

            guard let self else { return }
            self.isRestoring = false
            self.tableView.isUserInteractionEnabled = true

            if let error {
                let alert = UIAlertController(
                    title: String(localized: "checkpoint_list.alert.restore_failed.title"),
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
                self.present(alert, animated: true)
            } else {
                self.reloadCheckpoints()

                let alert = UIAlertController(
                    title: String(localized: "checkpoint_list.alert.restored.title"),
                    message: String(localized: "checkpoint_list.alert.restored.message"),
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default) { [weak self] _ in
                    self?.navigationController?.popViewController(animated: true)
                })
                self.present(alert, animated: true)
            }
        }
    }
}
