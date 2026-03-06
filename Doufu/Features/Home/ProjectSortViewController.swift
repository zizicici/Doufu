//
//  ProjectSortViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import UIKit

final class ProjectSortViewController: UITableViewController {

    struct Item: Hashable {
        let id: String
        let name: String
    }

    var onDone: (([String]) -> Void)?

    private var items: [Item]

    init(items: [Item]) {
        self.items = items
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "project_sort.title")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "SortItemCell")
        tableView.allowsSelection = false
        tableView.isEditing = true

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(didTapClose)
        )
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            title: String(localized: "common.action.done"),
            style: .done,
            target: self,
            action: #selector(didTapDone)
        )
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        1
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        items.count
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        String(localized: "project_sort.footer.hint")
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "SortItemCell", for: indexPath)
        var configuration = cell.defaultContentConfiguration()
        configuration.text = items[indexPath.row].name
        configuration.textProperties.numberOfLines = 1
        cell.contentConfiguration = configuration
        return cell
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        true
    }

    override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        guard sourceIndexPath != destinationIndexPath else {
            return
        }

        let movedItem = items.remove(at: sourceIndexPath.row)
        items.insert(movedItem, at: destinationIndexPath.row)
    }

    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        .none
    }

    override func tableView(
        _ tableView: UITableView,
        shouldIndentWhileEditingRowAt indexPath: IndexPath
    ) -> Bool {
        false
    }

    @objc
    private func didTapClose() {
        dismiss(animated: true)
    }

    @objc
    private func didTapDone() {
        onDone?(items.map(\.id))
        dismiss(animated: true)
    }
}
