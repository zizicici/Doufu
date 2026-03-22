//
//  CapabilityDetailViewController.swift
//  Doufu
//

import AVFoundation
import CoreLocation
import Photos
import UIKit

// MARK: - Section / Item IDs

nonisolated enum CapabilityDetailSectionID: Hashable, Sendable {
    case systemPermission
    case projects
    case activityLog
}

nonisolated enum CapabilityDetailItemID: Hashable, Sendable {
    case systemPermission(statusText: String)
    case project(id: String, name: String, isAllowed: Bool)
    case emptyProjects
    case activityLog
}

// MARK: - ViewController

@MainActor
final class CapabilityDetailViewController: UIViewController, UITableViewDelegate {

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)

    private let capabilityType: CapabilityType
    private let capabilityStore = ProjectCapabilityStore.shared
    private var projectEntries: [(projectID: String, projectName: String, state: CapabilityState)] = []

    private var diffableDataSource: UITableViewDiffableDataSource<CapabilityDetailSectionID, CapabilityDetailItemID>!

    init(capabilityType: CapabilityType) {
        self.capabilityType = capabilityType
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = capabilityType.displayName
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
        tableView.register(CapabilitySwitchCell.self, forCellReuseIdentifier: CapabilitySwitchCell.reuseIdentifier)
        configureDiffableDataSource()
        reloadData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadData()
    }

    // MARK: - Data

    private func reloadData() {
        projectEntries = capabilityStore.loadProjectsWithCapability(type: capabilityType)
        applySnapshot()
    }

    // MARK: - Diffable DataSource

    private func configureDiffableDataSource() {
        diffableDataSource = CapabilityDetailDataSource(
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
        itemID: CapabilityDetailItemID
    ) -> UITableViewCell {
        switch itemID {
        case .systemPermission(let statusText):
            let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = String(localized: "capability.detail.system_permission")
            configuration.secondaryText = statusText
            cell.contentConfiguration = configuration
            cell.accessoryType = .disclosureIndicator
            return cell

        case .project(let id, let name, let isAllowed):
            guard let cell = tableView.dequeueReusableCell(
                withIdentifier: CapabilitySwitchCell.reuseIdentifier,
                for: indexPath
            ) as? CapabilitySwitchCell else {
                return UITableViewCell()
            }
            cell.configure(title: name, isOn: isAllowed) { [weak self] newValue in
                guard let self else { return }
                let newState: CapabilityState = newValue ? .allowed : .denied
                self.capabilityStore.saveCapability(
                    projectID: id,
                    type: self.capabilityType,
                    state: newState
                )
                CapabilityActivityStore.shared.recordEvent(
                    projectID: id,
                    capability: self.capabilityType,
                    event: .changed,
                    detail: newValue ? CapabilityActivityDetail.allowed : CapabilityActivityDetail.denied
                )
                self.reloadData()
            }
            return cell

        case .emptyProjects:
            let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
            var configuration = UIListContentConfiguration.cell()
            configuration.text = String(localized: "capability.detail.no_projects")
            configuration.textProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.selectionStyle = .none
            return cell

        case .activityLog:
            let cell = tableView.dequeueReusableCell(withIdentifier: "Cell", for: indexPath)
            var configuration = cell.defaultContentConfiguration()
            configuration.text = String(localized: "capability.activity_log.title")
            cell.contentConfiguration = configuration
            cell.accessoryType = .disclosureIndicator
            return cell
        }
    }

    // MARK: - Snapshot

    private func buildSnapshot() -> NSDiffableDataSourceSnapshot<CapabilityDetailSectionID, CapabilityDetailItemID> {
        var snapshot = NSDiffableDataSourceSnapshot<CapabilityDetailSectionID, CapabilityDetailItemID>()

        if capabilityType.hasSystemPermission {
            snapshot.appendSections([.systemPermission])
            snapshot.appendItems([.systemPermission(statusText: systemPermissionStatusText())], toSection: .systemPermission)
        }

        snapshot.appendSections([.projects])
        if projectEntries.isEmpty {
            snapshot.appendItems([.emptyProjects], toSection: .projects)
        } else {
            let items = projectEntries.map { entry in
                CapabilityDetailItemID.project(
                    id: entry.projectID,
                    name: entry.projectName,
                    isAllowed: entry.state == .allowed
                )
            }
            snapshot.appendItems(items, toSection: .projects)
        }

        snapshot.appendSections([.activityLog])
        snapshot.appendItems([.activityLog], toSection: .activityLog)

        return snapshot
    }

    private func applySnapshot() {
        var snapshot = buildSnapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        diffableDataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Selection

    func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath) else { return nil }
        switch itemID {
        case .systemPermission, .activityLog: return indexPath
        case .project, .emptyProjects: return nil
        }
    }

    func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath) else { return }

        switch itemID {
        case .systemPermission:
            handleSystemPermissionTap()
        case .activityLog:
            let vc = CapabilityActivityLogViewController(filter: .capability(type: capabilityType))
            navigationController?.pushViewController(vc, animated: true)
        case .project, .emptyProjects:
            break
        }
    }

    // MARK: - System Permission

    private func systemPermissionStatusText() -> String {
        switch capabilityType {
        case .camera:
            return permissionStatusText(for: AVCaptureDevice.authorizationStatus(for: .video))
        case .microphone:
            return permissionStatusText(for: AVCaptureDevice.authorizationStatus(for: .audio))
        case .location:
            return locationPermissionStatusText()
        case .photoSave:
            return photoSavePermissionStatusText()
        case .clipboardRead, .clipboardWrite:
            return ""
        }
    }

    private func permissionStatusText(for status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined: return String(localized: "settings.permissions.status.not_requested")
        case .authorized: return String(localized: "settings.permissions.status.allowed")
        case .denied: return String(localized: "settings.permissions.status.denied")
        case .restricted: return String(localized: "settings.permissions.status.restricted")
        @unknown default: return String(localized: "settings.permissions.status.not_requested")
        }
    }

    private func locationPermissionStatusText() -> String {
        let status = CLLocationManager().authorizationStatus
        switch status {
        case .notDetermined: return String(localized: "settings.permissions.status.not_requested")
        case .authorizedWhenInUse, .authorizedAlways: return String(localized: "settings.permissions.status.allowed")
        case .denied: return String(localized: "settings.permissions.status.denied")
        case .restricted: return String(localized: "settings.permissions.status.restricted")
        @unknown default: return String(localized: "settings.permissions.status.not_requested")
        }
    }

    private func handleSystemPermissionTap() {
        switch capabilityType {
        case .camera:
            handleMediaPermissionTap(mediaType: .video)
        case .microphone:
            handleMediaPermissionTap(mediaType: .audio)
        case .location:
            handleLocationPermissionTap()
        case .photoSave:
            handlePhotoSavePermissionTap()
        case .clipboardRead, .clipboardWrite:
            break
        }
    }

    private func handleMediaPermissionTap(mediaType: AVMediaType) {
        let status = AVCaptureDevice.authorizationStatus(for: mediaType)
        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: mediaType) { [weak self] _ in
                Task { @MainActor in self?.reloadData() }
            }
        case .denied, .restricted:
            openSystemSettings()
        case .authorized:
            break
        @unknown default:
            break
        }
    }

    private lazy var locationManager = CLLocationManager()

    private func handleLocationPermissionTap() {
        let status = locationManager.authorizationStatus
        switch status {
        case .notDetermined:
            locationManager.delegate = self
            locationManager.requestWhenInUseAuthorization()
        case .denied, .restricted:
            openSystemSettings()
        case .authorizedWhenInUse, .authorizedAlways:
            break
        @unknown default:
            break
        }
    }

    private func photoSavePermissionStatusText() -> String {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .notDetermined: return String(localized: "settings.permissions.status.not_requested")
        case .authorized, .limited: return String(localized: "settings.permissions.status.allowed")
        case .denied: return String(localized: "settings.permissions.status.denied")
        case .restricted: return String(localized: "settings.permissions.status.restricted")
        @unknown default: return String(localized: "settings.permissions.status.not_requested")
        }
    }

    private func handlePhotoSavePermissionTap() {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .notDetermined:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { [weak self] _ in
                Task { @MainActor in self?.reloadData() }
            }
        case .denied, .restricted:
            openSystemSettings()
        case .authorized, .limited:
            break
        @unknown default:
            break
        }
    }

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }
}

// MARK: - DataSource (header/footer)

private final class CapabilityDetailDataSource: UITableViewDiffableDataSource<CapabilityDetailSectionID, CapabilityDetailItemID> {
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let sectionID = sectionIdentifier(for: section) else { return nil }
        switch sectionID {
        case .systemPermission:
            return String(localized: "capability.detail.section.system")
        case .projects:
            return String(localized: "capability.detail.section.projects")
        case .activityLog:
            return nil
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        nil
    }
}

// MARK: - CLLocationManagerDelegate

extension CapabilityDetailViewController: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        reloadData()
    }
}

// MARK: - Switch Cell

final class CapabilitySwitchCell: UITableViewCell {
    static let reuseIdentifier = "CapabilitySwitchCell"

    private var onToggle: ((Bool) -> Void)?

    private lazy var toggle: UISwitch = {
        let toggle = UISwitch()
        toggle.addTarget(self, action: #selector(switchChanged), for: .valueChanged)
        return toggle
    }()

    func configure(title: String, isOn: Bool, onToggle: @escaping (Bool) -> Void) {
        var configuration = defaultContentConfiguration()
        configuration.text = title
        contentConfiguration = configuration
        accessoryView = toggle
        toggle.isOn = isOn
        self.onToggle = onToggle
        selectionStyle = .none
    }

    @objc
    private func switchChanged() {
        onToggle?(toggle.isOn)
    }
}
