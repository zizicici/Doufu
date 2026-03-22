//
//  ToolPermissionPickerViewController.swift
//  Doufu

import UIKit

@MainActor
final class ToolPermissionPickerViewController: UIViewController, UITableViewDelegate {

    var onSelectionChanged: ((ToolPermissionMode?) -> Void)?

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let showsUseDefault: Bool
    private var selectedMode: ToolPermissionMode?
    private var isUsingDefault: Bool

    private var diffableDataSource: ToolPermissionPickerDataSource!

    /// - Parameters:
    ///   - currentMode: The currently active mode (resolved, not nil).
    ///   - showsUseDefault: Whether to show a "Use Default" row (project level).
    ///   - isUsingDefault: Whether the current selection is "Use Default" (no explicit override).
    init(
        currentMode: ToolPermissionMode,
        showsUseDefault: Bool,
        isUsingDefault: Bool = false
    ) {
        self.showsUseDefault = showsUseDefault
        self.selectedMode = isUsingDefault ? nil : currentMode
        self.isUsingDefault = isUsingDefault
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "settings.chat.tool_permission.title")
        view.backgroundColor = .doufuBackground
        tableView.backgroundColor = .doufuBackground
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "PermissionCell")
        configureDiffableDataSource()
        applySnapshot()
    }

    // MARK: - Diffable DataSource

    private func configureDiffableDataSource() {
        diffableDataSource = ToolPermissionPickerDataSource(
            tableView: tableView
        ) { [weak self] tableView, indexPath, itemID in
            guard let self else { return UITableViewCell() }
            return self.cell(for: tableView, indexPath: indexPath, itemID: itemID)
        }
        diffableDataSource.defaultRowAnimation = .none
        diffableDataSource.footerProvider = { [weak self] sectionID in
            self?.sectionFooter(for: sectionID)
        }
    }

    private func cell(
        for tableView: UITableView,
        indexPath: IndexPath,
        itemID: ToolPermissionPickerItemID
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "PermissionCell", for: indexPath)
        var configuration = cell.defaultContentConfiguration()

        switch itemID {
        case .useDefault:
            configuration.text = String(localized: "project_settings.chat.tool_permission.use_default")
            let appDefault = AppProjectStore.shared.loadAppToolPermissionMode()
            configuration.secondaryText = Self.displayName(for: appDefault)
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.accessoryType = isUsingDefault ? .checkmark : .none

        case .mode(let rawValue):
            guard let mode = ToolPermissionMode(rawValue: rawValue) else {
                cell.contentConfiguration = configuration
                return cell
            }
            configuration.text = Self.displayName(for: mode)
            configuration.secondaryText = Self.subtitle(for: mode)
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.accessoryType = (!isUsingDefault && selectedMode == mode) ? .checkmark : .none
        }

        cell.contentConfiguration = configuration
        return cell
    }

    // MARK: - Snapshot

    private func buildSnapshot() -> NSDiffableDataSourceSnapshot<ToolPermissionPickerSectionID, ToolPermissionPickerItemID> {
        var snapshot = NSDiffableDataSourceSnapshot<ToolPermissionPickerSectionID, ToolPermissionPickerItemID>()
        snapshot.appendSections([.options])

        var items: [ToolPermissionPickerItemID] = []
        if showsUseDefault {
            items.append(.useDefault)
        }
        for mode in ToolPermissionMode.allCases {
            items.append(.mode(mode.rawValue))
        }
        snapshot.appendItems(items, toSection: .options)
        return snapshot
    }

    private func applySnapshot() {
        var snapshot = buildSnapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        diffableDataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Section Footer

    private func sectionFooter(for sectionID: ToolPermissionPickerSectionID) -> String? {
        switch sectionID {
        case .options:
            return String(localized: "settings.chat.tool_permission.footer")
        }
    }

    // MARK: - Selection

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath) else { return }

        switch itemID {
        case .useDefault:
            guard !isUsingDefault else { return }
            isUsingDefault = true
            selectedMode = nil
            onSelectionChanged?(nil)

        case .mode(let rawValue):
            guard let mode = ToolPermissionMode(rawValue: rawValue) else { return }
            guard isUsingDefault || selectedMode != mode else { return }
            isUsingDefault = false
            selectedMode = mode
            onSelectionChanged?(mode)
        }

        applySnapshot()
    }

    // MARK: - Display Names

    static func displayName(for mode: ToolPermissionMode) -> String {
        switch mode {
        case .standard:
            return String(localized: "tool_permission.mode.standard")
        case .autoApproveNonDestructive:
            return String(localized: "tool_permission.mode.auto_non_destructive")
        case .fullAutoApprove:
            return String(localized: "tool_permission.mode.full_auto")
        }
    }

    static func subtitle(for mode: ToolPermissionMode) -> String {
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

// MARK: - ToolPermissionPickerDataSource

private final class ToolPermissionPickerDataSource: UITableViewDiffableDataSource<ToolPermissionPickerSectionID, ToolPermissionPickerItemID> {

    var footerProvider: ((ToolPermissionPickerSectionID) -> String?)?

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let sectionID = sectionIdentifier(for: section) else { return nil }
        return footerProvider?(sectionID)
    }
}
