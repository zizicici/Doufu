//
//  SettingsViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import AppInfo
import AVFoundation
import CoreLocation
import SafariServices
import StoreKit
import UIKit

@MainActor
final class SettingsViewController: UITableViewController {

    static let supportEmail = "doufu@zi.ci"
    static let appStoreID = "6760194187"

    private let store = LLMProviderSettingsStore.shared
    private let projectStore = AppProjectStore.shared
    private let modelSelectionStore = ModelSelectionStateStore.shared
    private var modelSelectionObserver: NSObjectProtocol?
    private var appJunApps: [AppInfo.App] = []
    private var aboutRows: [SettingsItemID] = [.specifications, .eula, .privacyPolicy]

    private var diffableDataSource: UITableViewDiffableDataSource<SettingsSectionID, SettingsItemID>!

    init() {
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        if let modelSelectionObserver {
            NotificationCenter.default.removeObserver(modelSelectionObserver)
        }
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = String(localized: "settings.title")
        tableView.backgroundColor = .doufuBackground
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "SettingsCell")
        tableView.register(AppCell.self, forCellReuseIdentifier: "AppCell")
        tableView.rowHeight = UITableView.automaticDimension
        tableView.estimatedRowHeight = 50.0

        configureDiffableDataSource()

        modelSelectionObserver = modelSelectionStore.addObserver { [weak self] change in
            guard case .appDefault = change.scope else { return }
            self?.applySnapshot()
        }
        refreshAppJunApps()
        applySnapshot()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        applySnapshot()
    }

    // MARK: - Diffable DataSource

    private func configureDiffableDataSource() {
        diffableDataSource = SettingsDataSource(
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
        itemID: SettingsItemID
    ) -> UITableViewCell {
        switch itemID {
        case .language(let secondaryText):
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = String(localized: "settings.general.language.title")
            configuration.secondaryText = secondaryText
            cell.contentConfiguration = configuration
            return cell

        case .cameraPermission(let secondaryText):
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = String(localized: "settings.permissions.camera")
            configuration.secondaryText = secondaryText
            cell.contentConfiguration = configuration
            return cell

        case .microphonePermission(let secondaryText):
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = String(localized: "settings.permissions.microphone")
            configuration.secondaryText = secondaryText
            cell.contentConfiguration = configuration
            return cell

        case .locationPermission(let secondaryText):
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = String(localized: "settings.permissions.location")
            configuration.secondaryText = secondaryText
            cell.contentConfiguration = configuration
            return cell

        case .manageProviders(let secondaryText):
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = String(localized: "settings.providers.title")
            configuration.secondaryText = secondaryText
            cell.contentConfiguration = configuration
            return cell

        case .defaultModel(let secondaryText):
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = String(localized: "settings.default_model.title")
            configuration.secondaryText = secondaryText
            cell.contentConfiguration = configuration
            return cell

        case .tokenUsage:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = String(localized: "providers.manage.item.token_usage")
            cell.contentConfiguration = configuration
            return cell

        case .toolPermission(let secondaryText):
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = String(localized: "settings.chat.tool_permission.title")
            configuration.secondaryText = secondaryText
            cell.contentConfiguration = configuration
            return cell

        case .pipProgress(let secondaryText):
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = String(localized: "settings.chat.pip_progress.title")
            configuration.secondaryText = secondaryText
            cell.contentConfiguration = configuration
            return cell

        case .email:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = String(localized: "settings.contact.email")
            configuration.secondaryText = Self.supportEmail
            cell.contentConfiguration = configuration
            return cell

        case .xiaohongshu:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = String(localized: "settings.contact.xiaohongshu")
            configuration.secondaryText = "@App\u{541b}"
            cell.contentConfiguration = configuration
            return cell

        case .bilibili:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = String(localized: "settings.contact.bilibili")
            configuration.secondaryText = "@App\u{541b}"
            cell.contentConfiguration = configuration
            return cell

        case .app(let storeId):
            let cell = tableView.dequeueReusableCell(withIdentifier: "AppCell", for: indexPath)
            if let appCell = cell as? AppCell,
               let app = appJunApps.first(where: { $0.storeId == storeId }) {
                appCell.update(app)
            }
            cell.accessoryType = .disclosureIndicator
            return cell

        case .moreApps:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = String(localized: "settings.appjun.more")
            cell.contentConfiguration = configuration
            return cell

        case .specifications:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = String(localized: "settings.about.specifications")
            cell.contentConfiguration = configuration
            return cell

        case .share:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = String(localized: "settings.about.share")
            cell.contentConfiguration = configuration
            return cell

        case .review:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = String(localized: "settings.about.review")
            cell.contentConfiguration = configuration
            return cell

        case .eula:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = String(localized: "settings.about.eula")
            cell.contentConfiguration = configuration
            return cell

        case .privacyPolicy:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = String(localized: "settings.about.privacy_policy")
            cell.contentConfiguration = configuration
            return cell
        }
    }

    // MARK: - Snapshot

    private func buildSnapshot() -> NSDiffableDataSourceSnapshot<SettingsSectionID, SettingsItemID> {
        var snapshot = NSDiffableDataSourceSnapshot<SettingsSectionID, SettingsItemID>()
        snapshot.appendSections([.general, .llmProviders, .project, .permissions, .contact, .appjun, .about])

        // General
        snapshot.appendItems([
            .language(secondaryText: currentLanguageDisplayName()),
        ], toSection: .general)

        // LLM Providers
        let providersCount = store.loadProviders().count
        snapshot.appendItems([
            .manageProviders(secondaryText: String(
                format: String(localized: "settings.manage_providers.configured_count_format"),
                providersCount
            )),
            .defaultModel(secondaryText: defaultModelDisplayName()),
            .tokenUsage,
        ], toSection: .llmProviders)

        // Project
        let mode = projectStore.loadAppToolPermissionMode()
        snapshot.appendItems([
            .toolPermission(secondaryText: ToolPermissionPickerViewController.displayName(for: mode)),
            .pipProgress(secondaryText: PiPProgressManager.shared.isEnabled
                ? String(localized: "settings.common.on")
                : String(localized: "settings.common.off")),
        ], toSection: .project)

        // Permissions
        snapshot.appendItems([
            .cameraPermission(secondaryText: cameraPermissionStatus()),
            .microphonePermission(secondaryText: microphonePermissionStatus()),
            .locationPermission(secondaryText: locationPermissionStatus()),
        ], toSection: .permissions)

        // Contact
        snapshot.appendItems([.email, .xiaohongshu, .bilibili], toSection: .contact)

        // App Jun
        var appJunItems: [SettingsItemID] = appJunApps.map { .app(storeId: $0.storeId) }
        appJunItems.append(.moreApps)
        snapshot.appendItems(appJunItems, toSection: .appjun)

        // About
        snapshot.appendItems(aboutRows, toSection: .about)

        return snapshot
    }

    private func applySnapshot() {
        var snapshot = buildSnapshot()
        snapshot.reconfigureItems(snapshot.itemIdentifiers)
        diffableDataSource.apply(snapshot, animatingDifferences: false)
    }

    // MARK: - Selection

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let itemID = diffableDataSource.itemIdentifier(for: indexPath) else { return }

        switch itemID {
        case .language:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }

        case .cameraPermission:
            handlePermissionTap(mediaType: .video)

        case .microphonePermission:
            handlePermissionTap(mediaType: .audio)

        case .locationPermission:
            handleLocationPermissionTap()

        case .manageProviders:
            let controller = ManageProvidersViewController()
            navigationController?.pushViewController(controller, animated: true)

        case .defaultModel:
            let controller = DefaultModelSelectionViewController()
            navigationController?.pushViewController(controller, animated: true)

        case .tokenUsage:
            let controller = TokenUsageViewController()
            navigationController?.pushViewController(controller, animated: true)

        case .toolPermission:
            let controller = makeToolPermissionPicker()
            navigationController?.pushViewController(controller, animated: true)

        case .pipProgress:
            let controller = makePiPProgressPicker()
            navigationController?.pushViewController(controller, animated: true)

        case .email:
            handleContactEmail()

        case .xiaohongshu:
            handleContactXiaohongshu()

        case .bilibili:
            handleContactBilibili()

        case .app(let storeId):
            if let app = appJunApps.first(where: { $0.storeId == storeId }) {
                openStorePage(for: app)
            }

        case .moreApps:
            openStoreDeveloperPage()

        case .specifications:
            let controller = SettingsSpecificationsViewController()
            navigationController?.pushViewController(controller, animated: true)

        case .share:
            guard let url = URL(string: "https://apps.apple.com/app/id\(Self.appStoreID)") else { return }
            let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
            present(activityVC, animated: true)

        case .review:
            guard let url = URL(string: "itms-apps://itunes.apple.com/app/id\(Self.appStoreID)?action=write-review"),
                  UIApplication.shared.canOpenURL(url) else { return }
            UIApplication.shared.open(url)

        case .eula:
            guard let url = URL(string: "https://www.apple.com/legal/internet-services/itunes/dev/stdeula/") else { return }
            let safari = SFSafariViewController(url: url)
            present(safari, animated: true)

        case .privacyPolicy:
            guard let url = URL(string: "https://medium.com/@zizicici/privacy-policy-for-doufu-app-68ccda0d3190") else { return }
            let safari = SFSafariViewController(url: url)
            present(safari, animated: true)
        }
    }

    // MARK: - Default Model

    private func defaultModelDisplayName() -> String {
        guard let selection = modelSelectionStore.loadAppDefaultSelection() else {
            return String(localized: "settings.default_model.not_set")
        }
        let resolution = ModelSelectionResolver.resolve(
            appDefault: selection,
            projectDefault: nil,
            threadSelection: nil,
            availableCredentials: ProviderCredentialResolver.resolveAvailableCredentials(providerStore: store),
            providerStore: store
        )
        guard resolution.state == .valid,
              let provider = store.loadProvider(id: selection.providerID)
        else {
            return String(
                localized: "settings.default_model.invalid",
                defaultValue: "Invalid App Default"
            )
        }
        let model = provider.availableModels.first(where: {
            $0.id.caseInsensitiveCompare(selection.modelRecordID) == .orderedSame
        })
        let modelName = model?.effectiveDisplayName ?? selection.modelRecordID
        return provider.label + " · " + modelName
    }

    // MARK: - Language

    private func currentLanguageDisplayName() -> String {
        let langCode = Bundle.main.preferredLocalizations.first ?? "en"
        let locale = Locale(identifier: langCode)
        return locale.localizedString(forIdentifier: langCode)?.localizedCapitalized ?? langCode
    }

    // MARK: - Pickers

    private func makeToolPermissionPicker() -> ToolPermissionPickerViewController {
        let currentMode = projectStore.loadAppToolPermissionMode()
        let controller = ToolPermissionPickerViewController(
            currentMode: currentMode,
            showsUseDefault: false
        )
        controller.onSelectionChanged = { [projectStore] mode in
            if let mode {
                projectStore.saveAppToolPermissionMode(mode)
            }
        }
        return controller
    }

    private func makePiPProgressPicker() -> SettingsPickerViewController {
        let onLabel = String(localized: "settings.common.on")
        let offLabel = String(localized: "settings.common.off")
        return SettingsPickerViewController(
            title: String(localized: "settings.chat.pip_progress.title"),
            options: [SettingsPickerOption(onLabel), SettingsPickerOption(offLabel)],
            footerText: String(localized: "settings.chat.pip_progress.footer"),
            selectedIndex: { PiPProgressManager.shared.isEnabled ? 0 : 1 },
            onSelect: { index in PiPProgressManager.shared.isEnabled = (index == 0) }
        )
    }

    // MARK: - Permission Status

    private func cameraPermissionStatus() -> String {
        permissionStatusText(for: AVCaptureDevice.authorizationStatus(for: .video))
    }

    private func microphonePermissionStatus() -> String {
        permissionStatusText(for: AVCaptureDevice.authorizationStatus(for: .audio))
    }

    private func locationPermissionStatus() -> String {
        let status = CLLocationManager().authorizationStatus
        switch status {
        case .notDetermined:
            return String(localized: "settings.permissions.status.not_requested")
        case .authorizedWhenInUse, .authorizedAlways:
            return String(localized: "settings.permissions.status.allowed")
        case .denied:
            return String(localized: "settings.permissions.status.denied")
        case .restricted:
            return String(localized: "settings.permissions.status.restricted")
        @unknown default:
            return String(localized: "settings.permissions.status.not_requested")
        }
    }

    private func permissionStatusText(for status: AVAuthorizationStatus) -> String {
        switch status {
        case .notDetermined:
            return String(localized: "settings.permissions.status.not_requested")
        case .authorized:
            return String(localized: "settings.permissions.status.allowed")
        case .denied:
            return String(localized: "settings.permissions.status.denied")
        case .restricted:
            return String(localized: "settings.permissions.status.restricted")
        @unknown default:
            return String(localized: "settings.permissions.status.not_requested")
        }
    }

    // MARK: - Permission Requests

    private func handlePermissionTap(mediaType: AVMediaType) {
        let status = AVCaptureDevice.authorizationStatus(for: mediaType)
        switch status {
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: mediaType) { [weak self] _ in
                Task { @MainActor in self?.applySnapshot() }
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

    private func openSystemSettings() {
        guard let url = URL(string: UIApplication.openSettingsURLString) else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - App Jun

    private func refreshAppJunApps() {
        let allApps: [AppInfo.App] = [.moontake, .lemon, .offDay, .one, .pigeon, .pin, .coconut, .tagDay]
        appJunApps = Array(allApps.shuffled().prefix(3))
    }

    private func openStorePage(for app: AppInfo.App) {
        let storeVC = SKStoreProductViewController()
        storeVC.delegate = self
        let params: [String: Any] = [SKStoreProductParameterITunesItemIdentifier: app.storeId]
        storeVC.loadProduct(withParameters: params) { [weak self] loaded, error in
            if loaded {
                self?.present(storeVC, animated: true)
            } else {
                guard let url = URL(string: "itms-apps://itunes.apple.com/app/" + app.storeId),
                      UIApplication.shared.canOpenURL(url) else { return }
                UIApplication.shared.open(url)
            }
        }
    }

    private func openStoreDeveloperPage() {
        guard let url = URL(string: "https://apps.apple.com/developer/zizicici-limited/id1564555697") else { return }
        UIApplication.shared.open(url)
    }

    // MARK: - Contact

    private func handleContactEmail() {
        guard let encoded = "mailto:\(Self.supportEmail)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
              let url = URL(string: encoded),
              UIApplication.shared.canOpenURL(url) else { return }
        UIApplication.shared.open(url)
    }

    private func handleContactXiaohongshu() {
        guard let url = URL(string: "https://www.xiaohongshu.com/user/profile/63f05fc5000000001001e524") else { return }
        let safari = SFSafariViewController(url: url)
        present(safari, animated: true)
    }

    private func handleContactBilibili() {
        guard let url = URL(string: "https://space.bilibili.com/4969209") else { return }
        let safari = SFSafariViewController(url: url)
        present(safari, animated: true)
    }
}

// MARK: - DataSource (header/footer support)

private final class SettingsDataSource: UITableViewDiffableDataSource<SettingsSectionID, SettingsItemID> {
    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        sectionIdentifier(for: section)?.header
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        sectionIdentifier(for: section)?.footer
    }
}

// MARK: - CLLocationManagerDelegate

extension SettingsViewController: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        applySnapshot()
    }
}

// MARK: - SKStoreProductViewControllerDelegate

extension SettingsViewController: SKStoreProductViewControllerDelegate {
    func productViewControllerDidFinish(_ viewController: SKStoreProductViewController) {
        viewController.dismiss(animated: true)
    }
}
