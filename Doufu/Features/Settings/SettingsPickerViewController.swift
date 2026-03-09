//
//  SettingsPickerViewController.swift
//  Doufu
//
//  Created by Claude on 2026/03/09.
//

import UIKit

struct SettingsPickerOption {
    let title: String
    let subtitle: String?

    init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }
}

final class SettingsPickerViewController: UITableViewController {

    private let options: [SettingsPickerOption]
    private let footerText: String?
    private let selectedIndex: () -> Int
    private let onSelect: (Int) -> Void

    init(
        title: String,
        options: [SettingsPickerOption],
        footerText: String? = nil,
        selectedIndex: @escaping () -> Int,
        onSelect: @escaping (Int) -> Void
    ) {
        self.options = options
        self.footerText = footerText
        self.selectedIndex = selectedIndex
        self.onSelect = onSelect
        super.init(style: .insetGrouped)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        tableView.backgroundColor = .doufuBackground
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
    }

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        options.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
        let option = options[indexPath.row]
        var configuration = cell.defaultContentConfiguration()
        configuration.text = option.title
        if let subtitle = option.subtitle {
            configuration.secondaryText = subtitle
            configuration.secondaryTextProperties.color = .secondaryLabel
        }
        cell.contentConfiguration = configuration
        cell.accessoryType = indexPath.row == selectedIndex() ? .checkmark : .none
        return cell
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        footerText
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        onSelect(indexPath.row)
        tableView.reloadData()
    }
}
