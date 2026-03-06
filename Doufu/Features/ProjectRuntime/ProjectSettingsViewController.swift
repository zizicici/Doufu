//
//  ProjectSettingsViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import UIKit

final class ProjectSettingsViewController: UITableViewController {

    var onProjectUpdated: ((String) -> Void)?

    private enum Section: Int, CaseIterable {
        case project
        case snapshots
        case future
        case action
    }

    private enum SnapshotRow: Int, CaseIterable {
        case save
        case load
    }

    private enum FutureRow: Int, CaseIterable {
        case runMode
        case buildPipeline
    }

    private let projectURL: URL
    private let store = AppProjectStore.shared

    private var baselineProjectName: String
    private var projectNameText: String

    private var canSave: Bool {
        let trimmed = projectNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialTrimmed = baselineProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        return trimmed != initialTrimmed
    }

    init(projectURL: URL, projectName: String) {
        self.projectURL = projectURL
        baselineProjectName = projectName
        projectNameText = projectName
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
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProjectFutureCell")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "SnapshotCell")

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
        guard let section = Section(rawValue: section) else {
            return 0
        }

        switch section {
        case .project, .action:
            return 1
        case .snapshots:
            return SnapshotRow.allCases.count
        case .future:
            return FutureRow.allCases.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else {
            return nil
        }
        switch section {
        case .project:
            return String(localized: "project_settings.section.project")
        case .snapshots:
            return String(localized: "project_settings.section.snapshots")
        case .future:
            return String(localized: "project_settings.section.coming_soon")
        case .action:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else {
            return nil
        }

        switch section {
        case .project:
            return String(localized: "project_settings.footer.project_name_usage")
        case .snapshots:
            return String(localized: "project_settings.footer.snapshot_limit")
        case .future:
            return String(localized: "project_settings.footer.future_features")
        case .action:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let section = Section(rawValue: indexPath.section) else {
            return UITableViewCell()
        }

        switch section {
        case .project:
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
                self?.refreshSaveButton()
            }
            return cell

        case .snapshots:
            guard let row = SnapshotRow(rawValue: indexPath.row) else {
                return UITableViewCell()
            }

            switch row {
            case .save:
                guard
                    let cell = tableView.dequeueReusableCell(
                        withIdentifier: SettingsCenteredButtonCell.reuseIdentifier,
                        for: indexPath
                    ) as? SettingsCenteredButtonCell
                else {
                    return UITableViewCell()
                }
                cell.configure(title: String(localized: "project_settings.snapshot.save_button"))
                return cell

            case .load:
                let cell = tableView.dequeueReusableCell(withIdentifier: "SnapshotCell", for: indexPath)
                var configuration = cell.defaultContentConfiguration()
                configuration.text = String(localized: "project_settings.snapshot.load_title")
                configuration.secondaryText = String(localized: "project_settings.snapshot.load_subtitle")
                configuration.secondaryTextProperties.color = .secondaryLabel
                cell.contentConfiguration = configuration
                cell.accessoryType = .disclosureIndicator
                return cell
            }

        case .future:
            guard let row = FutureRow(rawValue: indexPath.row) else {
                return UITableViewCell()
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectFutureCell", for: indexPath)
            var configuration = cell.defaultContentConfiguration()
            switch row {
            case .runMode:
                configuration.text = String(localized: "project_settings.future.run_mode.title")
                configuration.secondaryText = String(localized: "project_settings.future.run_mode.subtitle")
            case .buildPipeline:
                configuration.text = String(localized: "project_settings.future.build_pipeline.title")
                configuration.secondaryText = String(localized: "project_settings.future.build_pipeline.subtitle")
            }
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.selectionStyle = .none
            return cell

        case .action:
            guard
                let cell = tableView.dequeueReusableCell(
                    withIdentifier: SettingsCenteredButtonCell.reuseIdentifier,
                    for: indexPath
                ) as? SettingsCenteredButtonCell
            else {
                return UITableViewCell()
            }
            cell.configure(title: String(localized: "project_settings.action.save"), isEnabled: canSave)
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard let section = Section(rawValue: indexPath.section) else {
            return nil
        }
        switch section {
        case .snapshots:
            return indexPath
        case .action:
            return canSave ? indexPath : nil
        case .project, .future:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard let section = Section(rawValue: indexPath.section) else {
            return
        }

        switch section {
        case .snapshots:
            guard let row = SnapshotRow(rawValue: indexPath.row) else {
                return
            }
            switch row {
            case .save:
                saveManualSnapshot()
            case .load:
                openSnapshotsPage()
            }

        case .action:
            guard canSave else {
                return
            }
            saveProjectSettings()

        case .project, .future:
            return
        }
    }

    @objc
    private func didTapClose() {
        dismiss(animated: true)
    }

    private func refreshSaveButton() {
        let sectionIndex = Section.action.rawValue
        guard tableView.numberOfSections > sectionIndex else {
            return
        }
        guard tableView.numberOfRows(inSection: sectionIndex) > 0 else {
            return
        }
        tableView.reloadRows(at: [IndexPath(row: 0, section: sectionIndex)], with: .none)
    }

    private func saveProjectSettings() {
        let normalizedName = projectNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            try store.updateProjectName(projectURL: projectURL, name: normalizedName)
            baselineProjectName = normalizedName
            onProjectUpdated?(normalizedName)
            dismiss(animated: true)
        } catch {
            let alert = UIAlertController(
                title: String(localized: "project_settings.alert.save_failed.title"),
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
            present(alert, animated: true)
        }
    }

    private func saveManualSnapshot() {
        do {
            _ = try store.createSnapshot(projectURL: projectURL, kind: .manual)
            let alert = UIAlertController(
                title: String(localized: "snapshot.alert.saved.title"),
                message: String(localized: "snapshot.alert.saved.message"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
            present(alert, animated: true)
        } catch {
            let alert = UIAlertController(
                title: String(localized: "project_settings.alert.save_failed.title"),
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
            present(alert, animated: true)
        }
    }

    private func openSnapshotsPage() {
        let controller = ProjectSnapshotsViewController(projectURL: projectURL)
        controller.onSnapshotLoaded = { [weak self] in
            guard let self else { return }
            let latestProjectName = self.store.loadProjectName(projectURL: self.projectURL)
            self.baselineProjectName = latestProjectName
            self.projectNameText = latestProjectName
            self.onProjectUpdated?(latestProjectName)
            self.tableView.reloadData()
        }
        navigationController?.pushViewController(controller, animated: true)
    }
}

private final class ProjectSnapshotsViewController: UITableViewController {

    var onSnapshotLoaded: (() -> Void)?

    private enum Section: Int, CaseIterable {
        case manual
        case auto

        var kind: AppProjectSnapshotKind {
            switch self {
            case .manual:
                return .manual
            case .auto:
                return .auto
            }
        }
    }

    private let projectURL: URL
    private let store = AppProjectStore.shared
    private var manualSnapshots: [AppProjectSnapshotRecord] = []
    private var autoSnapshots: [AppProjectSnapshotRecord] = []

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
        title = String(localized: "snapshot_list.title")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProjectSnapshotRow")
        reloadSnapshots(showError: true)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadSnapshots(showError: false)
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else {
            return 0
        }
        let snapshots = snapshots(for: section)
        return max(1, snapshots.count)
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else {
            return nil
        }
        return section.kind.displayName
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else {
            return nil
        }
        switch section {
        case .manual:
            return String(localized: "snapshot_list.footer.manual_limit")
        case .auto:
            return String(localized: "snapshot_list.footer.auto_limit")
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectSnapshotRow", for: indexPath)
        cell.accessoryType = .none
        cell.selectionStyle = .none

        guard
            let section = Section(rawValue: indexPath.section),
            let snapshot = snapshot(at: indexPath, section: section)
        else {
            var configuration = cell.defaultContentConfiguration()
            configuration.text = String(localized: "snapshot_list.empty")
            configuration.textProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            return cell
        }

        var configuration = cell.defaultContentConfiguration()
        configuration.text = dateFormatter.string(from: snapshot.createdAt)
        configuration.secondaryText = snapshot.id
        configuration.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = configuration
        cell.selectionStyle = .default
        return cell
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }

        guard
            let section = Section(rawValue: indexPath.section),
            let snapshot = snapshot(at: indexPath, section: section)
        else {
            return
        }

        let alert = UIAlertController(
            title: String(localized: "snapshot_list.alert.load.title"),
            message: String(
                format: String(localized: "snapshot_list.alert.load.message_format"),
                dateFormatter.string(from: snapshot.createdAt)
            ),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "snapshot_list.action.load"), style: .destructive, handler: { [weak self] _ in
            self?.restoreSnapshot(snapshot)
        }))
        present(alert, animated: true)
    }

    private func snapshots(for section: Section) -> [AppProjectSnapshotRecord] {
        switch section {
        case .manual:
            return manualSnapshots
        case .auto:
            return autoSnapshots
        }
    }

    private func snapshot(at indexPath: IndexPath, section: Section) -> AppProjectSnapshotRecord? {
        let snapshots = snapshots(for: section)
        guard !snapshots.isEmpty, indexPath.row < snapshots.count else {
            return nil
        }
        return snapshots[indexPath.row]
    }

    private func reloadSnapshots(showError: Bool) {
        do {
            let snapshots = try store.loadSnapshots(projectURL: projectURL)
            manualSnapshots = snapshots.filter { $0.kind == .manual }
            autoSnapshots = snapshots.filter { $0.kind == .auto }
            tableView.reloadData()
        } catch {
            if showError {
                let alert = UIAlertController(
                    title: String(localized: "snapshot_list.alert.read_failed.title"),
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
                present(alert, animated: true)
            }
        }
    }

    private func restoreSnapshot(_ snapshot: AppProjectSnapshotRecord) {
        do {
            try store.restoreSnapshot(projectURL: projectURL, snapshot: snapshot)
            onSnapshotLoaded?()
            reloadSnapshots(showError: false)

            let alert = UIAlertController(
                title: String(localized: "snapshot_list.alert.loaded.title"),
                message: String(localized: "snapshot_list.alert.loaded.message"),
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default, handler: { [weak self] _ in
                self?.navigationController?.popViewController(animated: true)
            }))
            present(alert, animated: true)
        } catch {
            let alert = UIAlertController(
                title: String(localized: "snapshot_list.alert.restore_failed.title"),
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
            present(alert, animated: true)
        }
    }
}
