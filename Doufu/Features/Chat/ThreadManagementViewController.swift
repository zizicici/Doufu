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

final class ThreadManagementViewController: UIViewController, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    weak var delegate: ThreadManagementViewControllerDelegate?

    private let session: ChatSession
    private var threads: [ProjectChatThreadRecord] = []
    private var currentThreadID: String = ""

    private var diffableDataSource: ThreadManagementDataSource!

    init(session: ChatSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        view.backgroundColor = .doufuBackground
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        title = String(localized: "thread_management.title")
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ThreadCell")

        navigationItem.leftBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(didTapClose)
        )
        navigationItem.rightBarButtonItem = editButtonItem

        configureDiffableDataSource()
        reloadThreads()
    }

    private func reloadThreads() {
        threads = session.threadList
        currentThreadID = session.currentThreadID ?? ""
        applySnapshot()
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
        tableView.setEditing(editing, animated: animated)
    }

    // MARK: - Diffable DataSource

    private func configureDiffableDataSource() {
        let dataSource = ThreadManagementDataSource(
            tableView: tableView
        ) { [weak self] tableView, indexPath, itemID in
            guard let self else { return UITableViewCell() }
            return self.cell(for: tableView, indexPath: indexPath, itemID: itemID)
        }
        dataSource.defaultRowAnimation = .none
        dataSource.moveHandler = { [weak self] sourceIndexPath, destinationIndexPath in
            guard let self, sourceIndexPath != destinationIndexPath else { return }
            let moved = self.threads.remove(at: sourceIndexPath.row)
            self.threads.insert(moved, at: destinationIndexPath.row)
        }
        diffableDataSource = dataSource
    }

    private func cell(
        for tableView: UITableView,
        indexPath: IndexPath,
        itemID: ThreadManagementItemID
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "ThreadCell", for: indexPath)
        guard case .thread(let id, let isCurrent) = itemID else { return cell }
        let thread = threads.first(where: { $0.id == id })
        var config = cell.defaultContentConfiguration()
        config.text = thread?.title ?? id
        if isCurrent {
            config.secondaryText = String(localized: "thread_management.current_thread")
            config.secondaryTextProperties.color = .systemBlue
        }
        cell.contentConfiguration = config
        return cell
    }

    // MARK: - Snapshot

    private func buildSnapshot() -> NSDiffableDataSourceSnapshot<ThreadManagementSectionID, ThreadManagementItemID> {
        var snapshot = NSDiffableDataSourceSnapshot<ThreadManagementSectionID, ThreadManagementItemID>()
        snapshot.appendSections([.threads])
        let items: [ThreadManagementItemID] = threads.map {
            .thread(id: $0.id, isCurrent: $0.id == currentThreadID)
        }
        snapshot.appendItems(items, toSection: .threads)
        return snapshot
    }

    private func applySnapshot() {
        var snapshot = buildSnapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        diffableDataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Delegate: editing style & indentation

    func tableView(_ tableView: UITableView, editingStyleForRowAt indexPath: IndexPath) -> UITableViewCell.EditingStyle {
        .none
    }

    func tableView(_ tableView: UITableView, shouldIndentWhileEditingRowAt indexPath: IndexPath) -> Bool {
        false
    }

    // MARK: - Swipe to delete (non-editing mode)

    func tableView(_ tableView: UITableView, trailingSwipeActionsConfigurationForRowAt indexPath: IndexPath) -> UISwipeActionsConfiguration? {
        guard threads.count > 1 else { return nil }
        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath),
              case .thread(let id, _) = itemID,
              let thread = threads.first(where: { $0.id == id }) else { return nil }
        let deleteAction = UIContextualAction(style: .destructive, title: String(localized: "common.action.delete")) { [weak self] _, _, completion in
            self?.confirmDelete(thread: thread, completion: completion)
        }
        return UISwipeActionsConfiguration(actions: [deleteAction])
    }

    private func confirmDelete(thread: ProjectChatThreadRecord, completion: @escaping (Bool) -> Void) {
        let alert = UIAlertController(
            title: String(localized: "thread_management.delete.title"),
            message: String(format: String(localized: "thread_management.delete.message_format"), thread.title),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.action.cancel"), style: .cancel) { _ in
            completion(false)
        })
        alert.addAction(UIAlertAction(title: String(localized: "common.action.delete"), style: .destructive) { [weak self] _ in
            self?.performDelete(threadID: thread.id)
            completion(true)
        })
        present(alert, animated: true)
    }

    private func performDelete(threadID: String) {
        do {
            try session.deleteThread(threadID: threadID)
            reloadThreads()
            delegate?.threadManagementDidChange()
        } catch {
            let errorAlert = UIAlertController(title: nil, message: error.localizedDescription, preferredStyle: .alert)
            errorAlert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
            present(errorAlert, animated: true)
        }
    }

    // MARK: - Tap to rename

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard !isEditing else { return }
        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath),
              case .thread(let id, _) = itemID,
              let thread = threads.first(where: { $0.id == id }) else { return }
        showRenameAlert(for: thread)
    }

    private func showRenameAlert(for thread: ProjectChatThreadRecord) {
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

// MARK: - Section & Item IDs

nonisolated enum ThreadManagementSectionID: Hashable, Sendable {
    case threads

    var header: String? { nil }

    var footer: String? {
        switch self {
        case .threads:
            return String(localized: "thread_management.footer.hint")
        }
    }
}

nonisolated enum ThreadManagementItemID: Hashable, Sendable {
    case thread(id: String, isCurrent: Bool)
}

// MARK: - DataSource (header/footer + reorder support)

private final class ThreadManagementDataSource: UITableViewDiffableDataSource<ThreadManagementSectionID, ThreadManagementItemID> {
    var moveHandler: ((IndexPath, IndexPath) -> Void)?

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sectionIdentifier(for: section)?.header
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sectionIdentifier(for: section)?.footer
    }

    override func tableView(_ tableView: UITableView, canMoveRowAt indexPath: IndexPath) -> Bool {
        tableView.isEditing
    }

    override func tableView(_ tableView: UITableView, moveRowAt sourceIndexPath: IndexPath, to destinationIndexPath: IndexPath) {
        moveHandler?(sourceIndexPath, destinationIndexPath)
    }
}
