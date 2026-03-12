//
//  SettingsViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import AppInfo
import SafariServices
import StoreKit
import UIKit

@MainActor
final class SettingsViewController: UITableViewController {

    static let supportEmail = "doufu@zi.ci"
    static let appStoreID = "6760194187"

    private enum Section: Int, CaseIterable {
        case general
        case llmProviders
        case project
        case contact
        case appjun
        case about
    }

    private enum GeneralRow: Int, CaseIterable {
        case language
    }

    private enum ProjectRow: Int, CaseIterable {
        case toolPermission
        case pipProgress
    }

    private enum LLMProvidersRow: Int, CaseIterable {
        case manageProviders
        case defaultModel
        case tokenUsage
    }

    private enum ContactRow: Int, CaseIterable {
        case email
        case xiaohongshu
        case bilibili

        var title: String {
            switch self {
            case .email:
                return String(localized: "settings.contact.email")
            case .xiaohongshu:
                return String(localized: "settings.contact.xiaohongshu")
            case .bilibili:
                return String(localized: "settings.contact.bilibili")
            }
        }

        var value: String? {
            switch self {
            case .email:
                return SettingsViewController.supportEmail
            case .xiaohongshu, .bilibili:
                return "@App\u{541b}"
            }
        }
    }

    private enum AboutRow: Int, CaseIterable {
        case specifications
        case share
        case review
        case eula
        case privacyPolicy

        var title: String {
            switch self {
            case .specifications:
                return String(localized: "settings.about.specifications")
            case .share:
                return String(localized: "settings.about.share")
            case .review:
                return String(localized: "settings.about.review")
            case .eula:
                return String(localized: "settings.about.eula")
            case .privacyPolicy:
                return String(localized: "settings.about.privacy_policy")
            }
        }
    }

    private enum AppJunRow: Hashable {
        case app(AppInfo.App)
        case more

        var title: String {
            switch self {
            case .app:
                return ""
            case .more:
                return String(localized: "settings.appjun.more")
            }
        }
    }

    private let store = LLMProviderSettingsStore.shared
    private let projectStore = AppProjectStore.shared
    private let modelSelectionStore = ModelSelectionStateStore.shared
    private var modelSelectionObserver: NSObjectProtocol?
    private var appJunRows: [AppJunRow] = []
    private var aboutRows: [AboutRow] = [.specifications, .eula, .privacyPolicy]

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
        modelSelectionObserver = modelSelectionStore.addObserver { [weak self] change in
            guard case .appDefault = change.scope else { return }
            self?.reloadDefaultModelRow()
        }
        refreshAppJunRows()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        tableView.reloadData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else { return 0 }
        switch section {
        case .general:
            return GeneralRow.allCases.count
        case .llmProviders:
            return LLMProvidersRow.allCases.count
        case .project:
            return ProjectRow.allCases.count
        case .contact:
            return ContactRow.allCases.count
        case .appjun:
            return appJunRows.count
        case .about:
            return aboutRows.count
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .general:
            return String(localized: "settings.section.general")
        case .llmProviders:
            return String(localized: "settings.section.llm_providers")
        case .project:
            return String(localized: "settings.section.project")
        case .contact:
            return String(localized: "settings.section.contact")
        case .appjun:
            return String(localized: "settings.section.appjun")
        case .about:
            return String(localized: "settings.section.about")
        }
    }

    override func tableView(_ tableView: UITableView, titleForFooterInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else { return nil }
        switch section {
        case .llmProviders:
            return String(localized: "settings.section.llm_providers.footer")
        case .general, .project, .contact, .appjun, .about:
            return nil
        }
    }

    override func tableView(
        _ tableView: UITableView,
        cellForRowAt indexPath: IndexPath
    ) -> UITableViewCell {
        guard let section = Section(rawValue: indexPath.section) else {
            return tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
        }

        switch section {
        case .general:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = String(localized: "settings.general.language.title")
            configuration.secondaryText = currentLanguageDisplayName()
            cell.contentConfiguration = configuration
            return cell

        case .llmProviders:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            guard let row = LLMProvidersRow(rawValue: indexPath.row) else { return cell }
            var configuration = UIListContentConfiguration.valueCell()
            switch row {
            case .manageProviders:
                let providersCount = store.loadProviders().count
                configuration.text = String(localized: "settings.providers.title")
                configuration.secondaryText = String(
                    format: String(localized: "settings.manage_providers.configured_count_format"),
                    providersCount
                )
            case .defaultModel:
                configuration.text = String(localized: "settings.default_model.title")
                configuration.secondaryText = defaultModelDisplayName()
            case .tokenUsage:
                configuration.text = String(localized: "providers.manage.item.token_usage")
            }
            cell.contentConfiguration = configuration
            return cell

        case .project:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            guard let row = ProjectRow(rawValue: indexPath.row) else { return cell }
            var configuration = UIListContentConfiguration.valueCell()
            switch row {
            case .toolPermission:
                let mode = projectStore.loadAppToolPermissionMode()
                configuration.text = String(localized: "settings.chat.tool_permission.title")
                configuration.secondaryText = displayName(for: mode)
            case .pipProgress:
                configuration.text = String(localized: "settings.chat.pip_progress.title")
                configuration.secondaryText = PiPProgressManager.shared.isEnabled
                    ? String(localized: "settings.common.on")
                    : String(localized: "settings.common.off")
            }
            cell.contentConfiguration = configuration
            return cell

        case .contact:
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            guard let row = ContactRow(rawValue: indexPath.row) else { return cell }
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = row.title
            configuration.secondaryText = row.value
            cell.contentConfiguration = configuration
            return cell

        case .appjun:
            let item = appJunRows[indexPath.row]
            switch item {
            case .app(let app):
                let cell = tableView.dequeueReusableCell(withIdentifier: "AppCell", for: indexPath)
                if let appCell = cell as? AppCell {
                    appCell.update(app)
                }
                cell.accessoryType = .disclosureIndicator
                return cell
            case .more:
                let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
                cell.accessoryType = .disclosureIndicator
                var configuration = UIListContentConfiguration.valueCell()
                configuration.text = item.title
                cell.contentConfiguration = configuration
                return cell
            }

        case .about:
            let row = aboutRows[indexPath.row]
            let cell = tableView.dequeueReusableCell(withIdentifier: "SettingsCell", for: indexPath)
            cell.accessoryType = .disclosureIndicator
            var configuration = UIListContentConfiguration.valueCell()
            configuration.text = row.title
            cell.contentConfiguration = configuration
            return cell
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        tableView.deselectRow(at: indexPath, animated: true)
        guard let section = Section(rawValue: indexPath.section) else { return }

        switch section {
        case .general:
            if let url = URL(string: UIApplication.openSettingsURLString) {
                UIApplication.shared.open(url)
            }

        case .llmProviders:
            guard let row = LLMProvidersRow(rawValue: indexPath.row) else { return }
            switch row {
            case .manageProviders:
                let controller = ManageProvidersViewController()
                navigationController?.pushViewController(controller, animated: true)
            case .defaultModel:
                let controller = DefaultModelSelectionViewController()
                navigationController?.pushViewController(controller, animated: true)
            case .tokenUsage:
                let controller = TokenUsageViewController()
                navigationController?.pushViewController(controller, animated: true)
            }

        case .project:
            guard let row = ProjectRow(rawValue: indexPath.row) else { return }
            switch row {
            case .toolPermission:
                let controller = makeToolPermissionPicker()
                navigationController?.pushViewController(controller, animated: true)
            case .pipProgress:
                let controller = makePiPProgressPicker()
                navigationController?.pushViewController(controller, animated: true)
            }

        case .contact:
            guard let row = ContactRow(rawValue: indexPath.row) else { return }
            handleContact(row)

        case .appjun:
            let item = appJunRows[indexPath.row]
            switch item {
            case .app(let app):
                openStorePage(for: app)
            case .more:
                openStoreDeveloperPage()
            }

        case .about:
            guard let row = AboutRow(rawValue: indexPath.row) else { return }
            handleAbout(row)
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

    private func reloadDefaultModelRow() {
        guard isViewLoaded else { return }
        let indexPath = IndexPath(
            row: LLMProvidersRow.defaultModel.rawValue,
            section: Section.llmProviders.rawValue
        )
        guard tableView.numberOfSections > indexPath.section,
              tableView.numberOfRows(inSection: indexPath.section) > indexPath.row
        else {
            return
        }
        tableView.reloadRows(at: [indexPath], with: .none)
    }

    // MARK: - Language

    private func currentLanguageDisplayName() -> String {
        let langCode = Bundle.main.preferredLocalizations.first ?? "en"
        let locale = Locale(identifier: langCode)
        return locale.localizedString(forIdentifier: langCode)?.localizedCapitalized ?? langCode
    }

    // MARK: - Pickers

    private func makeToolPermissionPicker() -> SettingsPickerViewController {
        let modes = ToolPermissionMode.allCases
        return SettingsPickerViewController(
            title: String(localized: "settings.chat.tool_permission.title"),
            options: modes.map { SettingsPickerOption(displayName(for: $0), subtitle: subtitle(for: $0)) },
            footerText: String(localized: "settings.chat.tool_permission.footer"),
            selectedIndex: { [projectStore] in
                let current = projectStore.loadAppToolPermissionMode()
                return modes.firstIndex(of: current) ?? 0
            },
            onSelect: { [projectStore] index in projectStore.saveAppToolPermissionMode(modes[index]) }
        )
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

    private func displayName(for mode: ToolPermissionMode) -> String {
        switch mode {
        case .standard:
            return String(localized: "tool_permission.mode.standard")
        case .autoApproveNonDestructive:
            return String(localized: "tool_permission.mode.auto_non_destructive")
        case .fullAutoApprove:
            return String(localized: "tool_permission.mode.full_auto")
        }
    }

    private func subtitle(for mode: ToolPermissionMode) -> String {
        switch mode {
        case .standard:
            return String(localized: "tool_permission.mode.standard.subtitle")
        case .autoApproveNonDestructive:
            return String(localized: "tool_permission.mode.auto_non_destructive.subtitle")
        case .fullAutoApprove:
            return String(localized: "tool_permission.mode.full_auto.subtitle")
        }
    }

    // MARK: - App Jun

    private func refreshAppJunRows() {
        let allApps: [AppInfo.App] = [.moontake, .lemon, .offDay, .one, .pigeon, .pin, .coconut, .tagDay]
        let selected = Array(allApps.shuffled().prefix(3))
        appJunRows = selected.map { .app($0) } + [.more]
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

    private func handleContact(_ row: ContactRow) {
        switch row {
        case .email:
            guard let encoded = "mailto:\(Self.supportEmail)".addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed),
                  let url = URL(string: encoded),
                  UIApplication.shared.canOpenURL(url) else { return }
            UIApplication.shared.open(url)
        case .xiaohongshu:
            guard let url = URL(string: "https://www.xiaohongshu.com/user/profile/63f05fc5000000001001e524") else { return }
            let safari = SFSafariViewController(url: url)
            present(safari, animated: true)
        case .bilibili:
            guard let url = URL(string: "https://space.bilibili.com/4969209") else { return }
            let safari = SFSafariViewController(url: url)
            present(safari, animated: true)
        }
    }

    // MARK: - About

    private func handleAbout(_ row: AboutRow) {
        switch row {
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
}

// MARK: - SKStoreProductViewControllerDelegate

extension SettingsViewController: SKStoreProductViewControllerDelegate {
    func productViewControllerDidFinish(_ viewController: SKStoreProductViewController) {
        viewController.dismiss(animated: true)
    }
}
