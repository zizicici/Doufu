//
//  SettingsViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/04.
//

import AVFoundation
import CoreLocation
@preconcurrency import MoreKit
import Photos
import UIKit

@MainActor
final class SettingsViewController: UIViewController {

    static let supportEmail = "doufu@zi.ci"
    static let appStoreID = "6760194187"

    private let settingsDataSource = SettingsMoreDataSource()
    private lazy var moreViewController: MoreViewController = {
        MoreViewController(
            configuration: Self.makeMoreConfiguration(),
            dataSource: settingsDataSource
        )
    }()

    init() {
        super.init(nibName: nil, bundle: nil)
        title = String(localized: "settings.title")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()

        view.backgroundColor = .doufuBackground
        addChild(moreViewController)
        moreViewController.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(moreViewController.view)
        NSLayoutConstraint.activate([
            moreViewController.view.topAnchor.constraint(equalTo: view.topAnchor),
            moreViewController.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            moreViewController.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            moreViewController.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        moreViewController.didMove(toParent: self)
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        moreViewController.reloadData()
    }

    private static func makeMoreConfiguration() -> MoreViewControllerConfiguration {
        MoreViewControllerConfiguration(
            title: String(localized: "settings.title"),
            email: supportEmail,
            appStoreId: appStoreID,
            privacyPolicyURL: "https://medium.com/@zizicici/privacy-policy-for-doufu-app-68ccda0d3190",
            specificationsConfig: makeSpecificationsConfiguration(),
            appShowcase: AppShowcaseConfiguration(
                apps: [.moontake, .lemon, .offDay, .one, .pigeon, .pin, .coconut, .tagDay],
                displayCount: 3,
                developerPageURL: AppInfo.Developer.pageURL
            )
        )
    }

    private static func makeSpecificationsConfiguration() -> SpecificationsConfiguration {
        SpecificationsConfiguration(
            summaryItems: [
                .init(type: .name, value: appName()),
                .init(type: .version, value: appVersion()),
                .init(type: .manufacturer, value: "@App君"),
                .init(type: .publisher, value: "ZIZICICI LIMITED"),
                .init(type: .dateOfProduction, value: "2026/06/15"),
                .init(type: .license, value: "闽ICP备2023015823号"),
            ],
            thirdPartyLibraries: [
                .init(name: "GRDB", version: "7.10.0", urlString: "https://github.com/groue/GRDB.swift"),
                .init(name: "Runestone", version: "0.5.2", urlString: "https://github.com/simonbs/Runestone"),
                .init(name: "SwiftGitX", version: "0.4.0", urlString: "https://github.com/ibrahimcetin/SwiftGitX"),
                .init(name: "Swift Markdown", version: "0.7.3", urlString: "https://github.com/apple/swift-markdown"),
            ],
            title: String(localized: "settings.specifications.title")
        )
    }

    private static func appName() -> String {
        Bundle.main.localizedInfoDictionary?["CFBundleDisplayName"] as? String
            ?? Bundle.main.infoDictionary?["CFBundleDisplayName"] as? String
            ?? "Doufu"
    }

    private static func appVersion() -> String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? ""
    }
}

private final class SettingsMoreDataSource: MoreViewControllerDataSource {

    private enum ItemID {
        static let camera = "settings.permissions.camera"
        static let defaultModel = "settings.default_model"
        static let location = "settings.permissions.location"
        static let manageProviders = "settings.manage_providers"
        static let microphone = "settings.permissions.microphone"
        static let panelDockedOpacity = "settings.project.panel_opacity"
        static let photoSave = "settings.permissions.photo_save"
        static let pipProgress = "settings.chat.pip_progress"
        static let pipSound = "settings.chat.pip_sound"
        static let searxngURL = "settings.project.searxng"
        static let tokenUsage = "settings.providers.token_usage"
        static let toolPermission = "settings.chat.tool_permission"
        static let clipboardRead = "settings.permissions.clipboard_read"
        static let clipboardWrite = "settings.permissions.clipboard_write"
    }

    private let store = LLMProviderSettingsStore.shared
    private let projectStore = AppProjectStore.shared
    private let modelSelectionStore = ModelSelectionStateStore.shared

    func sections(for controller: MoreViewController) -> [MoreSectionType] {
        [
            .custom(generalSection()),
            .custom(llmProvidersSection()),
            .custom(projectSection()),
            .custom(agentToolSection()),
            .custom(pipSection()),
            .custom(permissionsSection()),
            .contact,
            .appjun,
            .about,
        ]
    }

    func moreViewController(_ controller: MoreViewController, didSelectCustomItem item: MoreCustomItem) {
        switch item.id {
        case MoreCustomItem.languageSettingsID:
            return

        case ItemID.manageProviders:
            controller.pushViewController(ManageProvidersViewController())

        case ItemID.defaultModel:
            controller.pushViewController(DefaultModelSelectionViewController())

        case ItemID.tokenUsage:
            controller.pushViewController(TokenUsageViewController())

        case ItemID.pipProgress:
            controller.pushViewController(makePiPProgressPicker())

        case ItemID.pipSound:
            controller.pushViewController(makePiPSoundPicker())

        case ItemID.panelDockedOpacity:
            controller.pushViewController(makePanelDockedOpacityPicker())

        case ItemID.toolPermission:
            controller.pushViewController(makeToolPermissionPicker())

        case ItemID.searxngURL:
            controller.pushViewController(SearXNGURLEditorViewController())

        case ItemID.camera:
            controller.pushViewController(CapabilityDetailViewController(capabilityType: .camera))

        case ItemID.microphone:
            controller.pushViewController(CapabilityDetailViewController(capabilityType: .microphone))

        case ItemID.location:
            controller.pushViewController(CapabilityDetailViewController(capabilityType: .location))

        case ItemID.photoSave:
            controller.pushViewController(CapabilityDetailViewController(capabilityType: .photoSave))

        case ItemID.clipboardRead:
            controller.pushViewController(CapabilityDetailViewController(capabilityType: .clipboardRead))

        case ItemID.clipboardWrite:
            controller.pushViewController(CapabilityDetailViewController(capabilityType: .clipboardWrite))

        default:
            break
        }
    }

    private func generalSection() -> MoreCustomSection {
        MoreCustomSection(
            id: "settings.section.general",
            header: String(localized: "settings.section.general"),
            items: [
                .languageSettings(
                    title: String(localized: "settings.general.language.title"),
                    value: currentLanguageDisplayName()
                ),
            ]
        )
    }

    private func llmProvidersSection() -> MoreCustomSection {
        let providersCount = store.loadProviders().count
        return MoreCustomSection(
            id: "settings.section.llm_providers",
            header: String(localized: "settings.section.llm_providers"),
            footer: String(localized: "settings.section.llm_providers.footer"),
            items: [
                MoreCustomItem(
                    id: ItemID.manageProviders,
                    title: String(localized: "settings.providers.title"),
                    value: String(
                        format: String(localized: "settings.manage_providers.configured_count_format"),
                        providersCount
                    )
                ),
                MoreCustomItem(
                    id: ItemID.defaultModel,
                    title: String(localized: "settings.default_model.title"),
                    value: defaultModelDisplayName()
                ),
                MoreCustomItem(
                    id: ItemID.tokenUsage,
                    title: String(localized: "providers.manage.item.token_usage")
                ),
            ]
        )
    }

    private func projectSection() -> MoreCustomSection {
        MoreCustomSection(
            id: "settings.section.project",
            header: String(localized: "settings.section.project"),
            items: [
                MoreCustomItem(
                    id: ItemID.panelDockedOpacity,
                    title: String(localized: "settings.project.panel_opacity.title"),
                    value: PanelDockedOpacity.current.displayName
                ),
            ]
        )
    }

    private func pipSection() -> MoreCustomSection {
        var items = [
            MoreCustomItem(
                id: ItemID.pipProgress,
                title: String(localized: "settings.chat.pip_progress.title"),
                value: PiPProgressManager.shared.isEnabled
                    ? String(localized: "settings.common.on")
                    : String(localized: "settings.common.off")
            ),
        ]
        if PiPProgressManager.shared.isEnabled {
            items.append(MoreCustomItem(
                id: ItemID.pipSound,
                title: String(localized: "settings.chat.pip_sound.title"),
                value: PiPProgressSoundSetting.current.displayName
            ))
        }

        return MoreCustomSection(
            id: "settings.section.pip",
            header: String(localized: "settings.section.pip"),
            items: items
        )
    }

    private func agentToolSection() -> MoreCustomSection {
        let mode = projectStore.loadAppToolPermissionMode()
        return MoreCustomSection(
            id: "settings.section.agent_tool",
            header: String(localized: "settings.section.agent_tool"),
            items: [
                MoreCustomItem(
                    id: ItemID.toolPermission,
                    title: String(localized: "settings.chat.tool_permission.title"),
                    value: ToolPermissionPickerViewController.displayName(for: mode)
                ),
                MoreCustomItem(
                    id: ItemID.searxngURL,
                    title: String(localized: "settings.project.searxng.title"),
                    value: projectStore.searxngBaseURL ?? ""
                ),
            ]
        )
    }

    private func permissionsSection() -> MoreCustomSection {
        MoreCustomSection(
            id: "settings.section.permissions",
            header: String(localized: "settings.section.permissions"),
            footer: String(localized: "settings.section.permissions.footer"),
            items: [
                MoreCustomItem(
                    id: ItemID.camera,
                    title: String(localized: "settings.permissions.camera"),
                    value: cameraPermissionStatus()
                ),
                MoreCustomItem(
                    id: ItemID.microphone,
                    title: String(localized: "settings.permissions.microphone"),
                    value: microphonePermissionStatus()
                ),
                MoreCustomItem(
                    id: ItemID.location,
                    title: String(localized: "settings.permissions.location"),
                    value: locationPermissionStatus()
                ),
                MoreCustomItem(
                    id: ItemID.photoSave,
                    title: String(localized: "settings.permissions.photo_save"),
                    value: photoSavePermissionStatus()
                ),
                MoreCustomItem(
                    id: ItemID.clipboardRead,
                    title: String(localized: "settings.permissions.clipboard_read"),
                    value: projectPermissionSummary(for: .clipboardRead)
                ),
                MoreCustomItem(
                    id: ItemID.clipboardWrite,
                    title: String(localized: "settings.permissions.clipboard_write"),
                    value: projectPermissionSummary(for: .clipboardWrite)
                ),
            ]
        )
    }

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
              let resolvedProviderID = resolution.providerID,
              let provider = store.loadProvider(id: resolvedProviderID)
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

    private func currentLanguageDisplayName() -> String {
        let langCode = Bundle.main.preferredLocalizations.first ?? "en"
        let locale = Locale(identifier: langCode)
        return locale.localizedString(forIdentifier: langCode)?.localizedCapitalized ?? langCode
    }

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

    private func makePiPSoundPicker() -> SettingsPickerViewController {
        let options = PiPProgressSoundSetting.allCases
        return SettingsPickerViewController(
            title: String(localized: "settings.chat.pip_sound.title"),
            options: options.map { SettingsPickerOption($0.displayName) },
            footerText: String(localized: "settings.chat.pip_sound.footer"),
            selectedIndex: { options.firstIndex(of: PiPProgressSoundSetting.current) ?? 0 },
            onSelect: { index in
                guard options.indices.contains(index) else { return }
                PiPProgressSoundSetting.current = options[index]
                PiPProgressManager.shared.soundSettingDidChange()
            }
        )
    }

    private func makePanelDockedOpacityPicker() -> SettingsPickerViewController {
        let allCases = PanelDockedOpacity.allCases
        return SettingsPickerViewController(
            title: String(localized: "settings.project.panel_opacity.title"),
            options: allCases.map { SettingsPickerOption($0.displayName) },
            footerText: String(localized: "settings.project.panel_opacity.footer"),
            selectedIndex: { PanelDockedOpacity.current.rawValue },
            onSelect: { index in
                if let opacity = PanelDockedOpacity(rawValue: index) {
                    PanelDockedOpacity.current = opacity
                }
            }
        )
    }

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

    private func photoSavePermissionStatus() -> String {
        let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
        switch status {
        case .notDetermined:
            return String(localized: "settings.permissions.status.not_requested")
        case .authorized, .limited:
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

    private func projectPermissionSummary(for type: CapabilityType) -> String {
        let entries = ProjectCapabilityStore.shared.loadProjectsWithCapability(type: type)
        if entries.isEmpty { return "" }
        return String(
            format: String(localized: "settings.permissions.project_count_format"),
            entries.count
        )
    }
}
