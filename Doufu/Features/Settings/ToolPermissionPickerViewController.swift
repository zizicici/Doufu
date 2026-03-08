//
//  ToolPermissionPickerViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/08.
//

import UIKit

final class ToolPermissionPickerViewController: UITableViewController {

    private let projectStore = AppProjectStore.shared
    private let modes = ToolPermissionMode.allCases

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "settings.chat.tool_permission.title")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
    }

    // MARK: - Data Source

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        modes.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        let mode = modes[indexPath.row]
        let current = projectStore.loadAppToolPermissionMode()

        var configuration = cell.defaultContentConfiguration()
        configuration.text = displayName(for: mode)
        configuration.secondaryText = subtitle(for: mode)
        configuration.secondaryTextProperties.color = .secondaryLabel
        cell.contentConfiguration = configuration
        cell.accessoryType = mode == current ? .checkmark : .none

        return cell
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        String(localized: "settings.chat.tool_permission.footer")
    }

    // MARK: - Delegate

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        let mode = modes[indexPath.row]
        projectStore.saveAppToolPermissionMode(mode)
        tableView.reloadData()
    }

    // MARK: - Helpers

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
