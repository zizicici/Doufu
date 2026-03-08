//
//  AutoCollapsePanelPickerViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/08.
//

import UIKit

final class AutoCollapsePanelPickerViewController: UITableViewController {

    private enum Row: Int, CaseIterable {
        case on
        case off
    }

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
        title = String(localized: "settings.project.auto_collapse_panel.title")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        Row.allCases.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        guard let row = Row(rawValue: indexPath.row) else { return cell }
        let isEnabled = projectStore.isAutoCollapsePanelEnabled

        var configuration = cell.defaultContentConfiguration()
        switch row {
        case .on:
            configuration.text = String(localized: "settings.common.on")
            cell.accessoryType = isEnabled ? .checkmark : .none
        case .off:
            configuration.text = String(localized: "settings.common.off")
            cell.accessoryType = !isEnabled ? .checkmark : .none
        }
        cell.contentConfiguration = configuration
        return cell
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        String(localized: "settings.project.auto_collapse_panel.footer")
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let row = Row(rawValue: indexPath.row) else { return }
        projectStore.isAutoCollapsePanelEnabled = (row == .on)
        tableView.reloadData()
    }
}
