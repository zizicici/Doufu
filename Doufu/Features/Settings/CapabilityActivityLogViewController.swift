//
//  CapabilityActivityLogViewController.swift
//  Doufu
//

import UIKit

@MainActor
final class CapabilityActivityLogViewController: UIViewController, UITableViewDelegate {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    private let filter: ActivityLogFilter
    private let store = CapabilityActivityStore.shared
    private var entriesByID: [Int64: CapabilityActivityEntry] = [:]
    private var groupedEntries: [(dateString: String, entries: [CapabilityActivityEntry])] = []

    private var diffableDataSource: UITableViewDiffableDataSource<ActivityLogSectionID, ActivityLogItemID>!

    private lazy var timeFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .none
        f.timeStyle = .medium
        return f
    }()

    private lazy var dateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .none
        return f
    }()

    init(filter: ActivityLogFilter) {
        self.filter = filter
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "capability.activity_log.title")
        view.backgroundColor = .doufuBackground
        tableView.backgroundColor = .doufuBackground
        tableView.delegate = self
        tableView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(tableView)
        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "Cell")
        configureDiffableDataSource()
        reloadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadData()
    }

    // MARK: - Data

    private func reloadData() {
        let entries: [CapabilityActivityEntry]
        switch filter {
        case .project(let id):
            entries = store.loadActivities(projectID: id)
        case .capability(let type):
            entries = store.loadActivities(capability: type)
        }
        entriesByID = Dictionary(uniqueKeysWithValues: entries.map { ($0.id, $0) })
        groupedEntries = groupByDate(entries)
        applySnapshot()
    }

    private func groupByDate(_ entries: [CapabilityActivityEntry]) -> [(dateString: String, entries: [CapabilityActivityEntry])] {
        let calendar = Calendar.current
        var groups: [(dateString: String, entries: [CapabilityActivityEntry])] = []
        var currentDateString: String?
        var currentGroup: [CapabilityActivityEntry] = []

        for entry in entries {
            let startOfDay = calendar.startOfDay(for: entry.createdAt)
            let ds = dateFormatter.string(from: startOfDay)
            if ds != currentDateString {
                if let prev = currentDateString, !currentGroup.isEmpty {
                    groups.append((dateString: prev, entries: currentGroup))
                }
                currentDateString = ds
                currentGroup = [entry]
            } else {
                currentGroup.append(entry)
            }
        }
        if let last = currentDateString, !currentGroup.isEmpty {
            groups.append((dateString: last, entries: currentGroup))
        }
        return groups
    }

    // MARK: - Diffable DataSource

    private func configureDiffableDataSource() {
        diffableDataSource = ActivityLogDataSource(
            tableView: tableView
        ) { [weak self] tableView, indexPath, itemID in
            guard let self else { return UITableViewCell() }
            return self.cell(for: tableView, indexPath: indexPath, itemID: itemID)
        }
        diffableDataSource.defaultRowAnimation = .none
    }

    private func cell(
        for tableView: UITableView,
        indexPath: IndexPath,
        itemID: ActivityLogItemID
    ) -> UITableViewCell {
        let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)

        switch itemID {
        case .activity(let id):
            guard let entry = entriesByID[id] else {
                return cell
            }

            var configuration = UIListContentConfiguration.subtitleCell()

            // Primary text: event type + context (capability name or project name)
            let eventLabel = eventTypeLabel(entry.eventType)
            switch filter {
            case .project:
                configuration.text = "\(eventLabel) · \(entry.capability.displayName)"
            case .capability:
                configuration.text = "\(eventLabel) · \(entry.projectName)"
            }

            // Secondary text: detail + time
            let time = timeFormatter.string(from: entry.createdAt)
            if let detail = entry.detail, !detail.isEmpty {
                let detailDisplay = localizedDetail(detail, eventType: entry.eventType)
                configuration.secondaryText = "\(detailDisplay) · \(time)"
            } else {
                configuration.secondaryText = time
            }
            configuration.secondaryTextProperties.color = .secondaryLabel

            // Image
            configuration.image = eventTypeImage(entry.eventType)
            configuration.imageProperties.tintColor = eventTypeTintColor(entry.eventType)

            cell.contentConfiguration = configuration
            cell.selectionStyle = .none

        case .empty:
            var configuration = UIListContentConfiguration.cell()
            configuration.text = String(localized: "capability.activity_log.empty")
            configuration.textProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.selectionStyle = .none
        }

        return cell
    }

    // MARK: - Snapshot

    private func applySnapshot() {
        var snapshot = NSDiffableDataSourceSnapshot<ActivityLogSectionID, ActivityLogItemID>()

        if groupedEntries.isEmpty {
            snapshot.appendSections([.empty])
            snapshot.appendItems([.empty], toSection: .empty)
        } else {
            for group in groupedEntries {
                let sectionID = ActivityLogSectionID.date(group.dateString)
                snapshot.appendSections([sectionID])
                let items = group.entries.map { ActivityLogItemID.activity(id: $0.id) }
                snapshot.appendItems(items, toSection: sectionID)
            }
        }

        diffableDataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Selection

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        nil
    }

    // MARK: - Helpers

    private func eventTypeLabel(_ type: CapabilityActivityEventType) -> String {
        switch type {
        case .requested:
            return String(localized: "capability.activity_log.event.requested")
        case .changed:
            return String(localized: "capability.activity_log.event.changed")
        case .serviceUsed:
            return String(localized: "capability.activity_log.event.service_used")
        }
    }

    private func eventTypeImage(_ type: CapabilityActivityEventType) -> UIImage? {
        switch type {
        case .requested:
            return UIImage(systemName: "questionmark.circle")
        case .changed:
            return UIImage(systemName: "arrow.triangle.2.circlepath")
        case .serviceUsed:
            return UIImage(systemName: "play.circle")
        }
    }

    private func eventTypeTintColor(_ type: CapabilityActivityEventType) -> UIColor {
        switch type {
        case .requested: return .systemOrange
        case .changed: return .systemBlue
        case .serviceUsed: return .systemGreen
        }
    }

    private func localizedDetail(_ detail: String, eventType: CapabilityActivityEventType) -> String {
        switch eventType {
        case .requested, .changed:
            switch detail {
            case CapabilityActivityDetail.allowed:
                return String(localized: "capability.activity_log.detail.allowed")
            case CapabilityActivityDetail.denied:
                return String(localized: "capability.activity_log.detail.denied")
            default:
                return detail
            }
        case .serviceUsed:
            return detail
        }
    }
}

// MARK: - DataSource (header)

private final class ActivityLogDataSource: UITableViewDiffableDataSource<ActivityLogSectionID, ActivityLogItemID> {
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let sectionID = sectionIdentifier(for: section) else { return nil }
        switch sectionID {
        case .date(let dateString):
            return dateString
        case .empty:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        nil
    }
}
