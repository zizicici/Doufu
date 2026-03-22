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

final class SettingsPickerViewController: UIViewController, UITableViewDelegate {
    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private var diffableDataSource: SettingsPickerDataSource!

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
        super.init(nibName: nil, bundle: nil)
        self.title = title
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
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
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")

        configureDiffableDataSource()
        applySnapshot()
    }

    // MARK: - Diffable DataSource

    private func configureDiffableDataSource() {
        diffableDataSource = SettingsPickerDataSource(
            tableView: tableView
        ) { [weak self] tableView, indexPath, itemID in
            guard let self else { return UITableViewCell() }
            let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
            guard case .option(let index, let selected) = itemID else { return cell }
            let option = self.options[index]
            var configuration = cell.defaultContentConfiguration()
            configuration.text = option.title
            if let subtitle = option.subtitle {
                configuration.secondaryText = subtitle
                configuration.secondaryTextProperties.color = .secondaryLabel
            }
            cell.contentConfiguration = configuration
            cell.accessoryType = selected ? .checkmark : .none
            return cell
        }
        diffableDataSource.defaultRowAnimation = .none
        diffableDataSource.footerProvider = { [weak self] sectionID in
            self?.footerText
        }
    }

    // MARK: - Snapshot

    private func buildSnapshot() -> NSDiffableDataSourceSnapshot<SettingsPickerSectionID, SettingsPickerItemID> {
        var snapshot = NSDiffableDataSourceSnapshot<SettingsPickerSectionID, SettingsPickerItemID>()
        snapshot.appendSections([.options])
        let selected = selectedIndex()
        let items: [SettingsPickerItemID] = options.indices.map { .option(index: $0, selected: $0 == selected) }
        snapshot.appendItems(items, toSection: .options)
        return snapshot
    }

    private func applySnapshot() {
        var snapshot = buildSnapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        diffableDataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Selection

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard case .option(let index, _) = diffableDataSource.itemIdentifier(for: indexPath) else { return }
        onSelect(index)
        applySnapshot()
    }
}

// MARK: - Section & Item IDs

nonisolated enum SettingsPickerSectionID: Hashable, Sendable {
    case options

    var header: String? {
        nil
    }

    var footer: String? {
        nil
    }
}

nonisolated enum SettingsPickerItemID: Hashable, Sendable {
    case option(index: Int, selected: Bool)
}

// MARK: - DataSource (header/footer support)

private final class SettingsPickerDataSource: UITableViewDiffableDataSource<SettingsPickerSectionID, SettingsPickerItemID> {
    var footerProvider: ((SettingsPickerSectionID) -> String?)?

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sectionIdentifier(for: section)?.header
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let sectionID = sectionIdentifier(for: section) else { return nil }
        return footerProvider?(sectionID) ?? sectionID.footer
    }
}
