//
//  ThreadManagementViewController.swift
//  Doufu
//
//  Created by Claude on 2026/03/09.
//

import UIKit

@MainActor
protocol ThreadManagementViewControllerDelegate: AnyObject {
    func threadManagementDidChange()
}

final class ThreadManagementViewController: UITableViewController {

    weak var delegate: ThreadManagementViewControllerDelegate?

    private let session: ChatSession
    private var threads: [ProjectChatThreadRecord] = []
    private var currentThreadID: String = ""

    init(session: ChatSession) {
        self.session = session
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "thread_management.title")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ThreadCell")

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(didTapClose)
        )
        navigationItem.rightBarButtonItem = editButtonItem

        reloadThreads()
    }

    private func reloadThreads() {
        threads = session.threadList
        currentThreadID = session.currentThreadID ?? ""
        tableView.reloadData()
    }

    // MARK: - Editing mode toggle

    override func setEditing(_ editing: Bool, animated: Bool) {
        if !editing && isEditing {
            // Exiting editing mode — save reorder
            let orderedIDs = threads.map(\.id)
            try? session.reorderThreads(orderedIDs: orderedIDs)
            delegate?.threadManagementDidChange()
        }
        super.setEditing(editing, animated: animated)
    }

    // MARK: - UITableViewDataSource

    override func numberOfSections(in tableView: UITableView) -> Int { 1 }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        threads.count
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ThreadCell", for: indexPath)
        let thread = threads[indexPath.row]
        var config = cell.defaultContentConfiguration()
        config.text = thread.title
        if thread.id == currentThreadID {
            config.secondaryText = String(localized: "thread_management.current_thread")
            config.secondaryTextProperties.color = .systemBlue
        }
        cell.contentConfiguration = config
        return cell
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        String(localized: "thread_management.footer.hint")
    }

    // MARK: - Reorder (editing mode)

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool { true }

    override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        guard sourceIndexPath != destinationIndexPath else { return }
        let moved = threads.remove(at: sourceIndexPath.row)
        threads.insert(moved, at: destinationIndexPath.row)
    }

    override func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        .none
    }

    override func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        false
    }

    // MARK: - Swipe to delete (non-editing mode)

    override func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard threads.count > 1 else { return nil }
        let thread = threads[indexPath.row]
        let deleteAction = UIContextualAction(style: .destructive, title: String(localized: "common.action.delete")) { [weak self] _, _, completion in
            self?.confirmDelete(thread: thread, at: indexPath, completion: completion)
        }
        return UISwipeActionsConfiguration(actions: [deleteAction])
    }

    private func confirmDelete(thread: ProjectChatThreadRecord, at indexPath: IndexPath, completion: @escaping (Bool) -> Void) {
        let alert = UIAlertController(
            title: String(localized: "thread_management.delete.title"),
            message: String(format: String(localized: "thread_management.delete.message_format"), thread.title),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.action.cancel"), style: .cancel) { _ in
            completion(false)
        })
        alert.addAction(UIAlertAction(title: String(localized: "common.action.delete"), style: .destructive) { [weak self] _ in
            self?.performDelete(at: indexPath)
            completion(true)
        })
        present(alert, animated: true)
    }

    private func performDelete(at indexPath: IndexPath) {
        let thread = threads[indexPath.row]
        do {
            try session.deleteThread(threadID: thread.id)
            reloadThreads()
            delegate?.threadManagementDidChange()
        } catch {
            let errorAlert = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
            errorAlert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
            present(errorAlert, animated: true)
        }
    }

    // MARK: - Tap to rename

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isEditing else { return }
        let thread = threads[indexPath.row]
        showRenameAlert(for: thread, at: indexPath)
    }

    private func showRenameAlert(for thread: ProjectChatThreadRecord, at indexPath: IndexPath) {
        let alert = UIAlertController(
            title: String(localized: "thread_management.rename.title"),
            message: nil,
            preferredStyle: .alert
        )
        alert.addTextField { textField in
            textField.text = thread.title
            textField.clearButtonMode = .whileEditing
        }
        alert.addAction(UIAlertAction(title: String(localized: "common.action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "common.action.done"), style: .default) { [weak self, weak alert] _ in
            guard let self,
                  let newTitle = alert?.textFields?.first?.text?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !newTitle.isEmpty else { return }
            do {
                try self.session.renameThread(threadID: thread.id, newTitle: newTitle)
                self.reloadThreads()
                self.delegate?.threadManagementDidChange()
            } catch {
                let errorAlert = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
                errorAlert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
                self.present(errorAlert, animated: true)
            }
        })
        present(alert, animated: true)
    }

    // MARK: - Actions

    @objc private func didTapClose() {
        dismiss(animated: true)
    }
}
