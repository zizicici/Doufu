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
        case future
        case action
    }

    private enum FutureRow: Int, CaseIterable {
        case runMode
        case buildPipeline
    }

    private let projectURL: URL
    private let store = AppProjectStore.shared

    private let initialProjectName: String
    private var projectNameText: String

    private var canSave: Bool {
        let trimmed = projectNameText.trimmingCharacters(in: .whitespacesAndNewlines)
        let initialTrimmed = initialProjectName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return false
        }
        return trimmed != initialTrimmed
    }

    init(projectURL: URL, projectName: String) {
        self.projectURL = projectURL
        initialProjectName = projectName
        projectNameText = projectName
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = "项目设置"
        tableView.keyboardDismissMode = .onDrag
        tableView.register(SettingsTextInputCell.self, forCellReuseIdentifier: SettingsTextInputCell.reuseIdentifier)
        tableView.register(SettingsCenteredButtonCell.self, forCellReuseIdentifier: SettingsCenteredButtonCell.reuseIdentifier)
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProjectFutureCell")

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
            return "Project"
        case .future:
            return "Coming Soon"
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
            return "项目名称会用于首页和项目信息展示。"
        case .future:
            return "这里会逐步增加运行配置、构建选项和更多项目能力。"
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
                title: "Name",
                text: projectNameText,
                placeholder: "项目名称",
                autocapitalizationType: .words
            ) { [weak self] text in
                self?.projectNameText = text
                self?.refreshSaveButton()
            }
            return cell

        case .future:
            guard let row = FutureRow(rawValue: indexPath.row) else {
                return UITableViewCell()
            }
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectFutureCell", for: indexPath)
            var configuration = cell.defaultContentConfiguration()
            switch row {
            case .runMode:
                configuration.text = "Run Mode"
                configuration.secondaryText = "默认沙盒运行（即将支持切换）"
            case .buildPipeline:
                configuration.text = "Build Pipeline"
                configuration.secondaryText = "代码检查与预构建流程（规划中）"
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
            cell.configure(title: "Save", isEnabled: canSave)
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard Section(rawValue: indexPath.section) == .action else {
            return nil
        }
        return canSave ? indexPath : nil
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard Section(rawValue: indexPath.section) == .action else {
            return
        }
        guard canSave else {
            return
        }
        saveProjectSettings()
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
            onProjectUpdated?(normalizedName)
            dismiss(animated: true)
        } catch {
            let alert = UIAlertController(title: "保存失败", message: error.localizedDescription, preferredStyle: .alert)
            alert.addAction(UIAlertAction(title: "知道了", style: .default))
            present(alert, animated: true)
        }
    }
}
