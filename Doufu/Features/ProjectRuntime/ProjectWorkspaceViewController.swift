//
//  ProjectWorkspaceViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import AVFoundation
import CoreLocation
import Photos
import PhotosUI
import UIKit
import WebKit

class ProjectWebView: WKWebView {
    /// Called before every reload so the caller can refresh injected user scripts.
    var onBeforeReload: (() -> Void)?

    override var inputAccessoryView: UIView? {
        return nil
    }

    @discardableResult
    override func reload() -> WKNavigation? {
        onBeforeReload?()
        return super.reload()
    }
}

final class ProjectWorkspaceViewController: UIViewController {

    private struct ChatEntryState {
        let appDefaultSelection: ModelSelection?
        let selectionResolution: ModelSelectionResolution
    }

    private enum PanelPresentationState {
        case expanded
        case collapsed
    }

    enum InitialRoute: Equatable {
        case workspace
        case chat
    }

    private(set) var project: AppProjectRecord
    private let projectStore = AppProjectStore.shared
    private let projectActivityStore = ProjectActivityStore.shared
    private let projectChangeCenter = ProjectChangeCenter.shared
    private let coordinator = ProjectLifecycleCoordinator.shared
    var onDismissed: (() -> Void)?
    private let jsErrorHandlerName = "jsError"
    private var lastPresentedJSErrorSignature: String?
    private lazy var jsErrorMessageProxy = WeakScriptMessageHandler(target: self)

    private let panelExpandedWidth: CGFloat = 230
    private let panelHeight: CGFloat = 52
    private let handleWidth: CGFloat = 28
    private let panelMargin: CGFloat = 10
    private let panelAutoCollapseDelay: TimeInterval = 2.4
    private let panelAnimationDuration: TimeInterval = 0.22
    private let exitTargetSize: CGFloat = 56
    private var hasInitializedPanelPosition = false
    private var panelState: PanelPresentationState = .collapsed
    private var panelPanStartFrame: CGRect = .zero
    private var autoCollapseWorkItem: DispatchWorkItem?
    private var chatNavigationController: UINavigationController?
    private var webLoadingCover: UIView?
    private let webServer: LocalWebServer
    private let doufuBridge: DoufuBridge
    private var chatPresentationTask: Task<Void, Never>?
    private var pendingInitialRoute: InitialRoute
    private var projectChangeObserver: NSObjectProtocol?
    private var appDidBecomeActiveObserver: NSObjectProtocol?
    private var isDraggingPanel = false
    private var isOverExitTargetPrevious = false
    private lazy var capabilityLocationManager = CLLocationManager()
    /// Batches concurrent system permission requests per capability type.
    private var pendingSystemPermissionCallbacks: [CapabilityType: [(Bool) -> Void]] = [:]
    /// Batches concurrent project permission prompts per capability type.
    private var pendingProjectPermissionWaiters: [CapabilityType: [(Bool) -> Void]] = [:]

    // Location service (separate from capabilityLocationManager which is only for permission requests)
    private var _locationService: CLLocationManager?
    private var locationService: CLLocationManager {
        if _locationService == nil {
            let m = CLLocationManager()
            m.desiredAccuracy = kCLLocationAccuracyBest
            _locationService = m
        }
        return _locationService!
    }
    private var locationGetCompletions: [(Result<String, DoufuBridgeCapabilityError>) -> Void] = []
    private var activeWatchIDs: Set<String> = []
    private var nextWatchID: Int = 1
    private var activeToasts: [CapabilityType: CapabilityToastView] = [:]
    private var toastDismissTimers: [CapabilityType: DispatchWorkItem] = [:]
    private var persistentToastTypes: Set<CapabilityType> = []
    private var toastGroupOffset: CGPoint = .zero
    private var toastPanStartOffset: CGPoint = .zero
    private lazy var mediaSessionManager: MediaSessionManager = {
        let m = MediaSessionManager()
        m.bridge = doufuBridge
        return m
    }()
    private var photoPickContext: (multiple: Bool, completion: (Result<String, DoufuBridgeCapabilityError>) -> Void)?
    private var capabilityPromptQueue: [(type: CapabilityType, completion: (Bool) -> Void)] = []
    private var isShowingCapabilityPrompt = false

    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // Allow <video> to play inline (without this, iOS forces native full-screen player).
        configuration.allowsInlineMediaPlayback = true
        // Allow autoplay without requiring a user gesture (needed for camera preview).
        configuration.mediaTypesRequiringUserActionForPlayback = []
        // Per-project data store: cookies and cache are isolated per project.
        // (IndexedDB and localStorage are handled by DoufuBridge → AppData/)
        if let storeID = UUID(uuidString: projectIdentifier) {
            configuration.websiteDataStore = WKWebsiteDataStore(forIdentifier: storeID)
        }
        // Doufu Bridge (fetch proxy + localStorage persistence) — must be first
        doufuBridge.register(on: configuration)
        // JS error capture
        let script = WKUserScript(
            source: jsErrorBridgeScriptSource(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(script)
        configuration.userContentController.add(jsErrorMessageProxy, name: jsErrorHandlerName)
        let view = ProjectWebView(frame: .zero, configuration: configuration)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.navigationDelegate = self
        view.uiDelegate = self
        view.backgroundColor = .systemBackground
        view.scrollView.contentInsetAdjustmentBehavior = .never
        view.setKeyboardRequiresUserInteraction(false)
        view.onBeforeReload = { [weak self] in
            guard let self else { return }
            self.doufuBridge.refreshStorageScript(on: configuration)
            let errorScript = WKUserScript(
                source: self.jsErrorBridgeScriptSource(),
                injectionTime: .atDocumentStart,
                forMainFrameOnly: false
            )
            configuration.userContentController.addUserScript(errorScript)
        }
        return view
    }()

    private lazy var panelContainer: UIVisualEffectView = {
        let blur = UIBlurEffect(style: .systemThinMaterial)
        let view = UIVisualEffectView(effect: blur)
        view.layer.cornerRadius = 16
        view.layer.cornerCurve = .continuous
        view.layer.masksToBounds = true
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor
        view.translatesAutoresizingMaskIntoConstraints = true
        return view
    }()

    private lazy var handleArea: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        return view
    }()

    private lazy var handleIndicator: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .tertiaryLabel
        view.layer.cornerRadius = 1.5
        view.layer.cornerCurve = .continuous
        view.alpha = 0.9
        return view
    }()

    private lazy var exitTargetView: UIView = {
        let view = UIView()
        view.backgroundColor = UIColor.systemRed.withAlphaComponent(0.85)
        view.layer.cornerRadius = exitTargetSize / 2
        view.layer.cornerCurve = .continuous
        view.alpha = 0
        view.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = true
        let imageView = UIImageView(
            image: UIImage(
                systemName: "xmark",
                withConfiguration: UIImage.SymbolConfiguration(pointSize: 22, weight: .bold)
            )
        )
        imageView.tintColor = .white
        imageView.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(imageView)
        NSLayoutConstraint.activate([
            imageView.centerXAnchor.constraint(equalTo: view.centerXAnchor),
            imageView.centerYAnchor.constraint(equalTo: view.centerYAnchor),
        ])
        return view
    }()

    private lazy var exitHintLabel: UILabel = {
        let label = UILabel()
        label.text = String(localized: "workspace.panel.exit_hint", defaultValue: "松开退出")
        label.font = .systemFont(ofSize: 17, weight: .semibold)
        label.textColor = .systemRed
        label.textAlignment = .center
        label.adjustsFontSizeToFitWidth = true
        label.minimumScaleFactor = 0.6
        label.translatesAutoresizingMaskIntoConstraints = false
        label.alpha = 0
        label.isHidden = true
        return label
    }()

    private weak var buttonStackView: UIStackView?

    private lazy var refreshButton: UIButton = {
        let button = makePanelIconButton(systemName: "arrow.clockwise", tintColor: nil)
        button.accessibilityLabel = String(localized: "workspace.panel.refresh")
        button.addTarget(self, action: #selector(didTapRefresh), for: .touchUpInside)
        return button
    }()

    private lazy var chatButton: UIButton = {
        let button = makePanelIconButton(systemName: "bubble.right", tintColor: nil)
        button.accessibilityLabel = String(localized: "workspace.panel.chat")
        button.addTarget(self, action: #selector(didTapChat), for: .touchUpInside)
        return button
    }()

    private lazy var settingsButton: UIButton = {
        let button = makePanelIconButton(systemName: "gearshape", tintColor: nil)
        button.accessibilityLabel = String(localized: "workspace.panel.settings")
        button.addTarget(self, action: #selector(didTapSettings), for: .touchUpInside)
        return button
    }()

    private lazy var filesButton: UIButton = {
        let button = makePanelIconButton(systemName: "folder", tintColor: nil)
        button.accessibilityLabel = String(localized: "workspace.panel.files")
        button.addTarget(self, action: #selector(didTapFiles), for: .touchUpInside)
        return button
    }()

    private lazy var exitButton: UIButton = {
        let button = makePanelIconButton(systemName: "xmark.circle", tintColor: .systemRed)
        button.accessibilityLabel = String(localized: "workspace.panel.exit")
        button.addTarget(self, action: #selector(didTapExit), for: .touchUpInside)
        return button
    }()

    private var projectIdentifier: String { project.id }
    private var projectName: String { project.name }
    private var projectURL: URL { project.projectURL }

    init(project: AppProjectRecord, initialRoute: InitialRoute = .workspace) {
        self.project = project
        self.webServer = LocalWebServer(projectURL: project.appURL, projectID: project.id)
        self.doufuBridge = DoufuBridge(
            projectURL: project.appURL,
            projectID: project.id,
            projectName: project.name
        )
        self.pendingInitialRoute = initialRoute
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        autoCollapseWorkItem?.cancel()
        if let projectChangeObserver {
            NotificationCenter.default.removeObserver(projectChangeObserver)
        }
        if let appDidBecomeActiveObserver {
            NotificationCenter.default.removeObserver(appDidBecomeActiveObserver)
        }
        webServer.stop()
        MainActor.assumeIsolated {
            mediaSessionManager.stopAll()
            cleanUpPhotosTmp()
        }
        stopLocationServices()
        doufuBridge.unregister(from: webView.configuration)
        webView.configuration.userContentController.removeScriptMessageHandler(forName: jsErrorHandlerName)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = projectName
        view.backgroundColor = .systemBackground
        configureLayout()
        installWebLoadingCover()
        configureFloatingPanel()
        doufuBridge.capabilityDelegate = self
        doufuBridge.mediaDelegate = mediaSessionManager
        doufuBridge.webView = webView
        projectChangeObserver = projectChangeCenter.addObserver(projectID: project.id) { [weak self] change in
            self?.handleProjectChange(change)
        }
        appDidBecomeActiveObserver = NotificationCenter.default.addObserver(
            forName: UIApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.consumeVisibleProjectUpdateIfNeeded()
        }
        loadProjectPage()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed {
            coordinator.closeProject(projectID: project.id)
            onDismissed?()
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        consumeVisibleProjectUpdateIfNeeded()
        guard pendingInitialRoute == .chat else { return }
        pendingInitialRoute = .workspace
        didTapChat()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        if !hasInitializedPanelPosition {
            panelContainer.frame = panelCollapsedFrame()
            panelState = .collapsed
            panelContainer.alpha = 1
            panelContainer.isHidden = false
            hasInitializedPanelPosition = true
        } else if !isDraggingPanel {
            relayoutPanelForCurrentState()
        }
    }

    private func configureLayout() {
        view.addSubview(webView)
        NSLayoutConstraint.activate([
            webView.topAnchor.constraint(equalTo: view.topAnchor),
            webView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            webView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            webView.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
    }

    private func installWebLoadingCover() {
        let cover = UIView()
        cover.translatesAutoresizingMaskIntoConstraints = false
        cover.backgroundColor = .systemBackground
        view.insertSubview(cover, aboveSubview: webView)
        NSLayoutConstraint.activate([
            cover.topAnchor.constraint(equalTo: webView.topAnchor),
            cover.leadingAnchor.constraint(equalTo: webView.leadingAnchor),
            cover.trailingAnchor.constraint(equalTo: webView.trailingAnchor),
            cover.bottomAnchor.constraint(equalTo: webView.bottomAnchor),
        ])
        webLoadingCover = cover
    }

    private func removeWebLoadingCover() {
        guard let cover = webLoadingCover else { return }
        webLoadingCover = nil
        UIView.animate(withDuration: 0.18) {
            cover.alpha = 0
        } completion: { _ in
            cover.removeFromSuperview()
        }
    }

    private func configureFloatingPanel() {
        view.addSubview(exitTargetView)
        view.addSubview(panelContainer)

        let stackView = UIStackView(arrangedSubviews: [refreshButton, chatButton, filesButton, settingsButton, exitButton])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .horizontal
        stackView.spacing = 0
        stackView.distribution = .fillEqually

        panelContainer.contentView.addSubview(stackView)
        panelContainer.contentView.addSubview(exitHintLabel)
        panelContainer.contentView.addSubview(handleArea)
        handleArea.addSubview(handleIndicator)
        buttonStackView = stackView

        NSLayoutConstraint.activate([
            handleArea.trailingAnchor.constraint(equalTo: panelContainer.contentView.trailingAnchor),
            handleArea.topAnchor.constraint(equalTo: panelContainer.contentView.topAnchor),
            handleArea.bottomAnchor.constraint(equalTo: panelContainer.contentView.bottomAnchor),
            handleArea.widthAnchor.constraint(equalToConstant: handleWidth),

            handleIndicator.centerXAnchor.constraint(equalTo: handleArea.centerXAnchor),
            handleIndicator.centerYAnchor.constraint(equalTo: handleArea.centerYAnchor),
            handleIndicator.widthAnchor.constraint(equalToConstant: 3),
            handleIndicator.heightAnchor.constraint(equalToConstant: 20),

            stackView.leadingAnchor.constraint(equalTo: panelContainer.contentView.leadingAnchor, constant: 8),
            stackView.topAnchor.constraint(equalTo: panelContainer.contentView.topAnchor, constant: 6),
            stackView.trailingAnchor.constraint(equalTo: handleArea.leadingAnchor, constant: -2),
            stackView.bottomAnchor.constraint(equalTo: panelContainer.contentView.bottomAnchor, constant: -6),

            exitHintLabel.leadingAnchor.constraint(equalTo: panelContainer.contentView.leadingAnchor, constant: 8),
            exitHintLabel.trailingAnchor.constraint(equalTo: handleArea.leadingAnchor, constant: -2),
            exitHintLabel.centerYAnchor.constraint(equalTo: panelContainer.contentView.centerYAnchor),
        ])

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePanelPan(_:)))
        panelContainer.addGestureRecognizer(panGesture)

        let tapGesture = UITapGestureRecognizer(target: self, action: #selector(didTapPanel(_:)))
        tapGesture.require(toFail: panGesture)
        panelContainer.addGestureRecognizer(tapGesture)
    }

    private func makePanelIconButton(systemName: String, tintColor: UIColor?) -> UIButton {
        let symbolConfig = UIImage.SymbolConfiguration(pointSize: 17, weight: .semibold)
        let image = UIImage(systemName: systemName, withConfiguration: symbolConfig)
        var configuration = UIButton.Configuration.plain()
        configuration.image = image
        configuration.title = nil
        configuration.imagePlacement = .all
        configuration.baseForegroundColor = tintColor ?? .label
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 2, bottom: 4, trailing: 2)
        let button = UIButton(configuration: configuration)
        return button
    }

    private func loadProjectPage() {
        let appURL = project.appURL
        let entryPath = appURL.appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: entryPath.path) else {
            showLoadError(String(localized: "workspace.load_error.entry_missing"))
            return
        }

        do {
            webServer.tmpDirectoryURL = projectURL.appendingPathComponent("tmp", isDirectory: true)
            try webServer.start()
            guard let url = webServer.baseURL else {
                throw LocalWebServer.ServerError.failedToStart
            }
            webView.load(URLRequest(url: url))
        } catch {
            // Fallback to file:// if the server fails to start.
            webView.loadFileURL(entryPath, allowingReadAccessTo: appURL)
        }
    }

    private func currentSafeFrame() -> CGRect {
        view.safeAreaLayoutGuide.layoutFrame.insetBy(dx: panelMargin, dy: panelMargin)
    }

    private let panelBottomOffset: CGFloat = 50

    private func panelCollapsedFrame() -> CGRect {
        let safe = currentSafeFrame()
        let y = safe.maxY - panelHeight - panelBottomOffset
        let x = -panelExpandedWidth + handleWidth
        return CGRect(x: x, y: y, width: panelExpandedWidth, height: panelHeight)
    }

    private func panelExpandedFrame() -> CGRect {
        let safe = currentSafeFrame()
        let y = safe.maxY - panelHeight - panelBottomOffset
        let x = safe.minX
        return CGRect(x: x, y: y, width: panelExpandedWidth, height: panelHeight)
    }

    private func relayoutPanelForCurrentState() {
        switch panelState {
        case .expanded:
            panelContainer.frame = panelExpandedFrame()
        case .collapsed:
            panelContainer.frame = panelCollapsedFrame()
        }
    }

    private func expandPanel(animated: Bool, scheduleAutoCollapseAfter: Bool) {
        cancelAutoCollapse()
        panelState = .expanded
        let target = panelExpandedFrame()

        if animated {
            UIView.animate(
                withDuration: panelAnimationDuration,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState]
            ) {
                self.panelContainer.frame = target
            } completion: { _ in
                if scheduleAutoCollapseAfter {
                    self.scheduleAutoCollapse()
                }
            }
        } else {
            panelContainer.frame = target
            if scheduleAutoCollapseAfter {
                scheduleAutoCollapse()
            }
        }
    }

    private func collapsePanel(animated: Bool) {
        cancelAutoCollapse()
        panelState = .collapsed
        let target = panelCollapsedFrame()

        if animated {
            UIView.animate(
                withDuration: panelAnimationDuration,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState]
            ) {
                self.panelContainer.frame = target
            }
        } else {
            panelContainer.frame = target
        }
    }

    private func scheduleAutoCollapse() {
        cancelAutoCollapse()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self, case .expanded = self.panelState else { return }
            self.collapsePanel(animated: true)
        }
        autoCollapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + panelAutoCollapseDelay, execute: workItem)
    }

    private func cancelAutoCollapse() {
        autoCollapseWorkItem?.cancel()
        autoCollapseWorkItem = nil
    }

    // MARK: - Exit Target

    private func exitTargetCenter() -> CGPoint {
        let safe = currentSafeFrame()
        return CGPoint(x: safe.maxX - exitTargetSize / 2, y: panelContainer.frame.midY)
    }

    private func updateExitTarget(for panelFrame: CGRect) {
        let expandedMaxX = panelExpandedFrame().maxX
        let dragDistance = panelFrame.maxX - expandedMaxX
        let threshold: CGFloat = 40
        guard dragDistance > threshold else {
            if exitTargetView.alpha > 0 {
                exitTargetView.alpha = 0
                exitTargetView.isHidden = true
                exitTargetView.transform = .identity
            }
            if isOverExitTargetPrevious {
                isOverExitTargetPrevious = false
                let generator = UIImpactFeedbackGenerator(style: .light)
                generator.impactOccurred()
            }
            return
        }

        let center = exitTargetCenter()
        exitTargetView.bounds = CGRect(x: 0, y: 0, width: exitTargetSize, height: exitTargetSize)
        exitTargetView.center = center
        exitTargetView.isHidden = false

        let progress = min((dragDistance - threshold) / 100, 1.0)
        exitTargetView.alpha = progress

        let isOver = isOverExitTarget(panelFrame: panelFrame)
        if isOver != isOverExitTargetPrevious {
            isOverExitTargetPrevious = isOver
            let generator = UIImpactFeedbackGenerator(style: isOver ? .heavy : .light)
            generator.impactOccurred()
        }

        if isOver {
            UIView.animate(withDuration: 0.15) {
                self.exitTargetView.transform = CGAffineTransform(scaleX: 1.3, y: 1.3)
                self.buttonStackView?.alpha = 0
                self.exitHintLabel.isHidden = false
                self.exitHintLabel.alpha = 1
            }
        } else {
            UIView.animate(withDuration: 0.15) {
                self.exitTargetView.transform = .identity
                self.buttonStackView?.alpha = 1
                self.exitHintLabel.alpha = 0
            } completion: { _ in
                if !self.isOverExitTargetPrevious {
                    self.exitHintLabel.isHidden = true
                }
            }
        }
    }

    private func isOverExitTarget(panelFrame: CGRect) -> Bool {
        let center = exitTargetCenter()
        let targetLeftEdge = center.x - exitTargetSize / 2
        return panelFrame.maxX >= targetLeftEdge
    }

    private func hideExitTarget(animated: Bool) {
        if animated {
            UIView.animate(withDuration: 0.2) {
                self.exitTargetView.alpha = 0
                self.exitTargetView.transform = .identity
                self.buttonStackView?.alpha = 1
                self.exitHintLabel.alpha = 0
            } completion: { _ in
                self.exitTargetView.isHidden = true
                self.exitHintLabel.isHidden = true
            }
        } else {
            exitTargetView.alpha = 0
            exitTargetView.isHidden = true
            exitTargetView.transform = .identity
            buttonStackView?.alpha = 1
            exitHintLabel.alpha = 0
            exitHintLabel.isHidden = true
        }
    }

    // MARK: - Panel Gestures

    @objc
    private func didTapPanel(_ gesture: UITapGestureRecognizer) {
        if case .collapsed = panelState {
            expandPanel(animated: true, scheduleAutoCollapseAfter: true)
        }
    }

    @objc
    private func handlePanelPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            cancelAutoCollapse()
            isDraggingPanel = true
            panelState = .expanded
            panelPanStartFrame = panelContainer.frame
        case .changed:
            let translation = gesture.translation(in: view)
            var frame = panelPanStartFrame
            frame.origin.x += translation.x
            let minX = panelCollapsedFrame().origin.x
            frame.origin.x = max(frame.origin.x, minX)
            panelContainer.frame = frame
            updateExitTarget(for: frame)
        case .ended, .cancelled, .failed:
            isDraggingPanel = false
            isOverExitTargetPrevious = false
            if isOverExitTarget(panelFrame: panelContainer.frame) {
                hideExitTarget(animated: false)
                dismiss(animated: true)
            } else {
                hideExitTarget(animated: true)
                let collapsedX = panelCollapsedFrame().origin.x
                let expandedX = panelExpandedFrame().origin.x
                let midPoint = (collapsedX + expandedX) / 2
                if panelContainer.frame.origin.x < midPoint {
                    collapsePanel(animated: true)
                } else {
                    expandPanel(animated: true, scheduleAutoCollapseAfter: true)
                }
            }
        default:
            break
        }
    }

    @objc
    private func didTapRefresh() {
        scheduleAutoCollapse()
        webView.reload()
    }

    @objc
    private func didTapChat() {
        scheduleAutoCollapse()
        guard presentedViewController == nil, chatPresentationTask == nil else { return }

        chatPresentationTask = Task { [weak self] in
            guard let self else { return }
            defer { self.chatPresentationTask = nil }
            await self.handleChatTap()
        }
    }

    private func handleChatTap() async {
        let entryState = await resolveChatEntryState()
        guard presentedViewController == nil else { return }

        if entryState.appDefaultSelection == nil {
            presentMissingAppDefaultModelAlert()
            return
        }

        if let chatNavigationController {
            if let chatVC = chatNavigationController.viewControllers.first as? ChatViewController {
                if chatVC.isReadOnly, entryState.selectionResolution.hasUsableProviderEnvironment {
                    self.chatNavigationController = nil
                    presentChatController(readOnly: false)
                    return
                }
                if !chatVC.isReadOnly, !entryState.selectionResolution.hasUsableProviderEnvironment {
                    self.chatNavigationController = nil
                    presentLLMSetupAlert(hasConfiguredProviders: hasConfiguredProviders())
                    return
                }
            }
            present(chatNavigationController, animated: true)
            return
        }

        if !entryState.selectionResolution.hasUsableProviderEnvironment {
            presentLLMSetupAlert(hasConfiguredProviders: hasConfiguredProviders())
            return
        }

        presentChatController(readOnly: false)
    }

    private func resolveChatEntryState() async -> ChatEntryState {
        let store = LLMProviderSettingsStore.shared
        let credentials = ProviderCredentialResolver.resolveAvailableCredentials(providerStore: store)
        let projectDefault = await ModelSelectionStateStore.projectDefaultSelection(projectID: project.id)
        let threadSelection: ModelSelection? = {
            let threadID: String? = coordinator.existingSession(projectID: project.id)?.currentThreadID
                ?? (try? ChatDataStore.shared.loadIndex(projectID: project.id))?.currentThreadID
            guard let threadID else { return nil }
            return ModelSelectionStateStore.shared.loadThreadSelection(
                projectID: project.id, threadID: threadID
            )
        }()
        let appDefault = await ModelSelectionStateStore.appDefaultSelection()

        return ChatEntryState(
            appDefaultSelection: appDefault,
            selectionResolution: ModelSelectionResolver.resolve(
                appDefault: appDefault,
                projectDefault: projectDefault,
                threadSelection: threadSelection,
                availableCredentials: credentials,
                providerStore: store
            )
        )
    }

    private func presentMissingAppDefaultModelAlert() {
        guard !(presentedViewController is UIAlertController) else { return }

        let alert = UIAlertController(
            title: String(localized: "chat.alert.no_default_model.title"),
            message: String(localized: "chat.alert.no_default_model.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: String(localized: "chat.setup_alert.action.setup"),
            style: .default
        ) { [weak self] _ in
            self?.presentLLMQuickSetup()
        })
        alert.addAction(UIAlertAction(
            title: String(localized: "chat.setup_alert.action.read_only"),
            style: .default
        ) { [weak self] _ in
            self?.presentChatController(readOnly: true)
        })
        alert.addAction(UIAlertAction(
            title: String(localized: "common.action.cancel"),
            style: .cancel
        ))
        present(alert, animated: true)
    }

    private func presentLLMSetupAlert(hasConfiguredProviders: Bool) {
        let message: String
        if hasConfiguredProviders {
            message = String(
                localized: "chat.setup_alert.message.credentials_unavailable",
                defaultValue: "Configured providers were found, but their credentials are unavailable. Open Setup to fix them, or continue in read-only mode."
            )
        } else {
            message = String(localized: "chat.setup_alert.message")
        }
        let alert = UIAlertController(
            title: String(localized: "chat.setup_alert.title"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(
            title: String(localized: "chat.setup_alert.action.setup"),
            style: .default
        ) { [weak self] _ in
            self?.presentLLMQuickSetup()
        })
        alert.addAction(UIAlertAction(
            title: String(localized: "chat.setup_alert.action.read_only"),
            style: .default
        ) { [weak self] _ in
            self?.presentChatController(readOnly: true)
        })
        alert.addAction(UIAlertAction(
            title: String(localized: "common.action.cancel"),
            style: .cancel
        ))
        present(alert, animated: true)
    }

    private func hasConfiguredProviders() -> Bool {
        !LLMProviderSettingsStore.shared.loadProviders().isEmpty
    }

    private func presentLLMQuickSetup() {
        let setup = LLMQuickSetupViewController()
        let nav = UINavigationController(rootViewController: setup)
        nav.modalPresentationStyle = .pageSheet
        if let sheet = nav.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(nav, animated: true)
    }

    private func presentChatController(readOnly: Bool) {
        let session = coordinator.session(for: project)
        let chatController = ChatViewController(session: session)
        chatController.isReadOnly = readOnly
        chatController.validationServerBaseURL = webServer.baseURL
        // Use a temp bridge for validation so localStorage writes don't pollute real user data.
        let tempStorageDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("doufu_validation", isDirectory: true)
            .appendingPathComponent(projectIdentifier, isDirectory: true)
        chatController.validationBridge = DoufuBridge(projectURL: projectURL, storageDirectoryOverride: tempStorageDir)

        let navigationController = UINavigationController(rootViewController: chatController)
        navigationController.modalPresentationStyle = .pageSheet
        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        navigationController.presentationController?.delegate = self
        chatNavigationController = navigationController
        present(navigationController, animated: true)
    }

    @objc
    private func didTapSettings() {
        scheduleAutoCollapse()
        if coordinator.isExecuting(projectID: project.id) {
            presentExecutionBlockedAlert()
            return
        }
        let settingsController = ProjectSettingsViewController(
            projectURL: projectURL,
            projectName: projectName,
            doufuBridge: doufuBridge
        )
        settingsController.onStorageCleared = { [weak self] in
            guard let self else { return }
            self.doufuBridge.refreshStorageScript(on: self.webView.configuration)
            self.webView.reload()
        }
        let navigationController = UINavigationController(rootViewController: settingsController)
        navigationController.modalPresentationStyle = .pageSheet
        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        navigationController.presentationController?.delegate = self
        present(navigationController, animated: true)
    }

    @objc
    private func didTapFiles() {
        scheduleAutoCollapse()
        if coordinator.isExecuting(projectID: project.id) {
            presentExecutionBlockedAlert()
            return
        }
        let controller = ProjectFileBrowserViewController(
            projectName: projectName,
            rootURL: project.appURL,
            projectRootURL: project.projectURL
        )
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .pageSheet
        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        navigationController.presentationController?.delegate = self
        present(navigationController, animated: true)
    }

    @objc
    private func didTapExit() {
        scheduleAutoCollapse()
        dismiss(animated: true)
    }

    private func presentExecutionBlockedAlert() {
        let alert = UIAlertController(
            title: String(localized: "workspace.alert.execution_blocked.title"),
            message: String(localized: "workspace.alert.execution_blocked.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
        present(alert, animated: true)
    }

    private func handleProjectChange(_ change: ProjectChangeCenter.Change) {
        refreshProjectRecordFromStore()

        switch change.kind {
        case .filesChanged, .checkpointRestored:
            webView.reload()
            consumeVisibleProjectUpdateIfNeeded()
        case .renamed:
            webView.reload()
        case .descriptionChanged, .toolPermissionChanged, .modelSelectionChanged:
            break
        }
    }

    private func consumeVisibleProjectUpdateIfNeeded() {
        guard isActivelyViewingWorkspace else { return }
        projectActivityStore.markProjectViewed(projectID: project.id)
    }

    private var isActivelyViewingWorkspace: Bool {
        isViewLoaded
            && view.window != nil
            && presentedViewController == nil
            && UIApplication.shared.applicationState == .active
    }

    private func refreshProjectRecordFromStore() {
        guard let metadata = projectStore.loadProjectMetadata(projectURL: projectURL) else {
            return
        }
        project = AppProjectRecord(
            id: project.id,
            name: metadata.name,
            projectURL: project.projectURL,
            createdAt: project.createdAt,
            updatedAt: metadata.updatedAt
        )
        title = project.name
    }

    private func showLoadError(_ message: String) {
        let alert = UIAlertController(
            title: String(localized: "workspace.alert.load_failed.title"),
            message: message,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
        present(alert, animated: true)
    }

    private func jsErrorBridgeScriptSource() -> String {
        """
        (function () {
          function postError(payload) {
            try {
              window.webkit.messageHandlers.\(jsErrorHandlerName).postMessage(payload);
            } catch (_) {}
          }

          window.addEventListener('error', function (event) {
            postError({
              message: String(event.message || 'Unknown JS error'),
              source: String(event.filename || ''),
              line: Number(event.lineno || 0),
              column: Number(event.colno || 0)
            });
          });

          window.addEventListener('unhandledrejection', function (event) {
            var reason = event.reason;
            var text = '';
            if (typeof reason === 'string') {
              text = reason;
            } else if (reason && typeof reason.message === 'string') {
              text = reason.message;
            } else {
              text = 'Unhandled promise rejection';
            }

            postError({
              message: text,
              source: 'promise',
              line: 0,
              column: 0
            });
          });
        })();
        """
    }

    private func handleJavaScriptErrorPayload(_ payload: [String: Any]) {
        let message = (payload["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
            ?? String(localized: "workspace.js_error.unknown")
        let source = (payload["source"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let line = intValue(from: payload["line"]) ?? 0
        let column = intValue(from: payload["column"]) ?? 0

        let signature = "\(message)|\(source)|\(line)|\(column)"
        guard signature != lastPresentedJSErrorSignature else {
            return
        }
        lastPresentedJSErrorSignature = signature

        var details = message
        if !source.isEmpty {
            details += String(format: String(localized: "workspace.js_error.source_format"), source)
        }
        if line > 0 || column > 0 {
            details += String(format: String(localized: "workspace.js_error.location_format"), line, column)
        }

        guard presentedViewController == nil else {
            return
        }
        let alert = UIAlertController(
            title: String(localized: "workspace.alert.js_error.title"),
            message: details,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
        present(alert, animated: true)
    }

    private func intValue(from anyValue: Any?) -> Int? {
        if let value = anyValue as? Int {
            return value
        }
        if let value = anyValue as? Double {
            return Int(value)
        }
        if let value = anyValue as? NSNumber {
            return value.intValue
        }
        if let value = anyValue as? String {
            return Int(value)
        }
        return nil
    }

    private func captureProjectPreviewIfNeeded() {
        let snapshotConfiguration = WKSnapshotConfiguration()
        snapshotConfiguration.afterScreenUpdates = true
        snapshotConfiguration.snapshotWidth = NSNumber(value: 360)
        webView.takeSnapshot(with: snapshotConfiguration) { [weak self] image, _ in
            guard let self, let image else {
                return
            }
            guard let imageData = image.jpegData(compressionQuality: 0.5) else {
                return
            }
            let previewURL = self.projectURL.appendingPathComponent("preview.jpg")
            try? imageData.write(to: previewURL, options: .atomic)
        }
    }
}

extension ProjectWorkspaceViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if presentationController.presentedViewController === chatNavigationController {
            chatNavigationController = nil
        }
        consumeVisibleProjectUpdateIfNeeded()
    }
}

extension ProjectWorkspaceViewController: WKUIDelegate {
    func webView(
        _ webView: WKWebView,
        requestMediaCapturePermissionFor origin: WKSecurityOrigin,
        initiatedByFrame frame: WKFrameInfo,
        type: WKMediaCaptureType,
        decisionHandler: @escaping (WKPermissionDecision) -> Void
    ) {
        decisionHandler(.deny)
    }
}

extension ProjectWorkspaceViewController: WKNavigationDelegate {
    func webView(
        _ webView: WKWebView,
        decidePolicyFor navigationAction: WKNavigationAction,
        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
    ) {
        // Only allow main-frame navigations to the local web server or file:// URLs.
        // This prevents project JS from navigating the top frame to an external URL
        // that would inherit the native bridge and all granted capabilities.
        if navigationAction.targetFrame?.isMainFrame == true {
            if let url = navigationAction.request.url {
                let isLocal = url.scheme == "file"
                    || (url.host == "localhost" && url.port == Int(webServer.port))
                if !isLocal {
                    decisionHandler(.cancel)
                    return
                }
            }
        }
        decisionHandler(.allow)
    }

    func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
        mediaSessionManager.stopAll()
        stopLocationServices()
        cleanUpPhotosTmp()
        clearAllCapabilityToasts()
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastPresentedJSErrorSignature = nil
        removeWebLoadingCover()
        captureProjectPreviewIfNeeded()
    }

    func webView(
        _ webView: WKWebView,
        didFail navigation: WKNavigation!,
        withError error: Error
    ) {
        showLoadError(error.localizedDescription)
    }

    func webView(
        _ webView: WKWebView,
        didFailProvisionalNavigation navigation: WKNavigation!,
        withError error: Error
    ) {
        showLoadError(error.localizedDescription)
    }
}

extension ProjectWorkspaceViewController: WKScriptMessageHandler {
    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        guard message.name == jsErrorHandlerName else {
            return
        }
        guard let payload = message.body as? [String: Any] else {
            return
        }
        handleJavaScriptErrorPayload(payload)
    }
}

// MARK: - DoufuBridgeCapabilityDelegate

extension ProjectWorkspaceViewController: DoufuBridgeCapabilityDelegate {
    func bridge(
        _ bridge: DoufuBridge,
        didRequestPhotoPick options: [String: Any],
        completion: @escaping (Result<String, DoufuBridgeCapabilityError>) -> Void
    ) {
        executePhotoPick(options: options, completion: completion)
    }

    func bridge(
        _ bridge: DoufuBridge,
        didRequestCapability type: CapabilityType,
        action: String,
        options: [String: Any],
        completion: @escaping (Result<String, DoufuBridgeCapabilityError>) -> Void
    ) {
        print("[Capability] request: type=\(type.dbKey) action=\(action)")

        // Teardown and control actions bypass permission checks — they operate
        // on an already-authorized session and must not re-prompt.
        let bypassActions: Set<String> = ["stop", "clearWatch", "focus", "exposure", "torch", "zoom", "mirror"]
        if bypassActions.contains(action) {
            executeCapability(type: type, action: action, options: options, completion: completion)
            return
        }

        // Layer 1: System permission check (camera/mic/location only)
        if type.hasSystemPermission {
            checkSystemPermission(for: type) { [weak self] systemResult in
                guard let self else { return }
                switch systemResult {
                case .authorized:
                    self.checkProjectPermission(type: type, action: action, options: options, completion: completion)
                case .notDetermined:
                    self.requestSystemPermission(for: type) { [weak self] granted in
                        guard let self else { return }
                        if granted {
                            self.checkProjectPermission(type: type, action: action, options: options, completion: completion)
                        } else {
                            let name = type.displayName
                            completion(.failure(DoufuBridgeCapabilityError(
                                message: String(
                                    format: String(localized: "capability.error.system_denied_format"),
                                    name
                                ),
                                name: "NotAllowedError"
                            )))
                        }
                    }
                case .denied:
                    let name = type.displayName
                    completion(.failure(DoufuBridgeCapabilityError(
                        message: String(
                            format: String(localized: "capability.error.system_denied_format"),
                            name
                        ),
                        name: "NotAllowedError"
                    )))
                }
            }
        } else {
            // Clipboard: no system permission needed
            checkProjectPermission(type: type, action: action, options: options, completion: completion)
        }
    }

    private enum SystemPermissionResult {
        case authorized
        case notDetermined
        case denied
    }

    private func checkSystemPermission(
        for type: CapabilityType,
        completion: @escaping (SystemPermissionResult) -> Void
    ) {
        switch type {
        case .camera:
            let status = AVCaptureDevice.authorizationStatus(for: .video)
            completion(mapAVStatus(status))
        case .microphone:
            let status = AVCaptureDevice.authorizationStatus(for: .audio)
            completion(mapAVStatus(status))
        case .location:
            let status = CLLocationManager().authorizationStatus
            switch status {
            case .notDetermined: completion(.notDetermined)
            case .authorizedWhenInUse, .authorizedAlways: completion(.authorized)
            default: completion(.denied)
            }
        case .photoSave:
            let status = PHPhotoLibrary.authorizationStatus(for: .addOnly)
            switch status {
            case .notDetermined: completion(.notDetermined)
            case .authorized, .limited: completion(.authorized)
            default: completion(.denied)
            }
        case .clipboardRead, .clipboardWrite:
            completion(.authorized)
        }
    }

    private func mapAVStatus(_ status: AVAuthorizationStatus) -> SystemPermissionResult {
        switch status {
        case .authorized: return .authorized
        case .notDetermined: return .notDetermined
        default: return .denied
        }
    }

    private func requestSystemPermission(
        for type: CapabilityType,
        completion: @escaping (Bool) -> Void
    ) {
        // Dedup: if a system permission request for this type is already inflight,
        // piggyback on it instead of triggering a redundant dialog.
        if pendingSystemPermissionCallbacks[type] != nil {
            pendingSystemPermissionCallbacks[type]!.append(completion)
            return
        }
        pendingSystemPermissionCallbacks[type] = [completion]

        let resolveAll: @MainActor (Bool) -> Void = { [weak self] granted in
            let callbacks = self?.pendingSystemPermissionCallbacks.removeValue(forKey: type) ?? []
            for cb in callbacks { cb(granted) }
        }

        switch type {
        case .camera:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                Task { @MainActor in resolveAll(granted) }
            }
        case .microphone:
            AVCaptureDevice.requestAccess(for: .audio) { granted in
                Task { @MainActor in resolveAll(granted) }
            }
        case .location:
            capabilityLocationManager.delegate = self
            capabilityLocationManager.requestWhenInUseAuthorization()
            // locationManagerDidChangeAuthorization drains via pendingSystemPermissionCallbacks
        case .photoSave:
            PHPhotoLibrary.requestAuthorization(for: .addOnly) { status in
                Task { @MainActor in
                    resolveAll(status == .authorized || status == .limited)
                }
            }
        default:
            resolveAll(true)
        }
    }

    private func checkProjectPermission(
        type: CapabilityType,
        action: String,
        options: [String: Any],
        completion: @escaping (Result<String, DoufuBridgeCapabilityError>) -> Void
    ) {
        print("[Capability] checkProjectPermission: type=\(type.dbKey) action=\(action)")
        let store = ProjectCapabilityStore.shared
        let state = store.loadCapability(projectID: project.id, type: type)

        switch state {
        case .notRequested:
            // Build the callback that maps the prompt result → execute or reject
            let waiter: (Bool) -> Void = { [weak self] userAllowed in
                guard let self else { return }
                if userAllowed {
                    self.executeCapability(type: type, action: action, options: options, completion: completion)
                } else {
                    completion(.failure(DoufuBridgeCapabilityError(
                        message: String(localized: "capability.error.project_denied"),
                        name: "NotAllowedError"
                    )))
                }
            }

            // Dedup: if a project prompt for this type is already queued/showing,
            // piggyback instead of enqueuing a duplicate alert.
            if pendingProjectPermissionWaiters[type] != nil {
                pendingProjectPermissionWaiters[type]!.append(waiter)
                return
            }
            pendingProjectPermissionWaiters[type] = [waiter]

            presentCapabilityPrompt(type: type) { [weak self] userAllowed in
                guard let self else { return }
                store.saveCapability(
                    projectID: self.project.id,
                    type: type,
                    state: userAllowed ? .allowed : .denied
                )
                let stateDetail = userAllowed ? CapabilityActivityDetail.allowed : CapabilityActivityDetail.denied
                let activityStore = CapabilityActivityStore.shared
                activityStore.recordEvent(projectID: self.project.id, capability: type, event: .requested, detail: stateDetail)
                activityStore.recordEvent(projectID: self.project.id, capability: type, event: .changed, detail: stateDetail)
                let waiters = self.pendingProjectPermissionWaiters.removeValue(forKey: type) ?? []
                for w in waiters { w(userAllowed) }
            }
        case .allowed:
            executeCapability(type: type, action: action, options: options, completion: completion)
        case .denied:
            completion(.failure(DoufuBridgeCapabilityError(
                message: String(localized: "capability.error.project_denied"),
                name: "NotAllowedError"
            )))
        }
    }

    // MARK: - Capability Toast

    private static let toastSpacing: CGFloat = 6

    private func showCapabilityToast(type: CapabilityType, persistent: Bool) {
        // Cancel any existing dismiss timer for this type
        toastDismissTimers[type]?.cancel()
        toastDismissTimers[type] = nil

        if persistent {
            persistentToastTypes.insert(type)
        }

        if activeToasts[type] == nil {
            let toast = CapabilityToastView(capabilityType: type)
            toast.alpha = 0
            let pan = UIPanGestureRecognizer(target: self, action: #selector(handleToastPan(_:)))
            toast.addGestureRecognizer(pan)
            view.addSubview(toast)
            activeToasts[type] = toast
            layoutToasts()

            UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
                toast.alpha = 1
            }
        }

        // Only schedule auto-dismiss if this type is not persistently active
        if !persistent && !persistentToastTypes.contains(type) {
            let work = DispatchWorkItem { [weak self] in
                self?.hideCapabilityToast(type: type)
            }
            toastDismissTimers[type] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2.0, execute: work)
        }
    }

    private func hideCapabilityToast(type: CapabilityType) {
        toastDismissTimers[type]?.cancel()
        toastDismissTimers[type] = nil
        persistentToastTypes.remove(type)

        guard let toast = activeToasts.removeValue(forKey: type) else { return }
        UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut, animations: {
            toast.alpha = 0
        }) { _ in
            toast.removeFromSuperview()
        }
        layoutToasts()
    }

    private func clearAllCapabilityToasts() {
        for (type, _) in activeToasts {
            toastDismissTimers[type]?.cancel()
            toastDismissTimers[type] = nil
        }
        for (_, toast) in activeToasts {
            toast.removeFromSuperview()
        }
        activeToasts.removeAll()
        toastDismissTimers.removeAll()
        persistentToastTypes.removeAll()
        toastGroupOffset = .zero
    }

    private func layoutToasts(animated: Bool = true) {
        let safe = currentSafeFrame()
        var y = safe.minY + toastGroupOffset.y

        // Sort by CapabilityType for stable ordering
        let sortedTypes = activeToasts.keys.sorted { $0.dbKey < $1.dbKey }
        for type in sortedTypes {
            guard let toast = activeToasts[type] else { continue }
            let size = toast.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
            let x = safe.midX - size.width / 2 + toastGroupOffset.x
            let frame = CGRect(x: x, y: y, width: size.width, height: size.height)
            if !animated || toast.frame == .zero {
                toast.frame = frame
            } else {
                UIView.animate(withDuration: 0.2, delay: 0, options: .curveEaseOut) {
                    toast.frame = frame
                }
            }
            y += size.height + Self.toastSpacing
        }
    }

    @objc
    private func handleToastPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            toastPanStartOffset = toastGroupOffset
        case .changed:
            let translation = gesture.translation(in: view)
            toastGroupOffset = CGPoint(
                x: toastPanStartOffset.x + translation.x,
                y: toastPanStartOffset.y + translation.y
            )
            layoutToasts(animated: false)
        case .ended, .cancelled:
            clampToastOffset()
        default:
            break
        }
    }

    private func clampToastOffset() {
        let safe = currentSafeFrame()
        guard let firstToast = activeToasts.values.first else { return }
        let size = firstToast.systemLayoutSizeFitting(UIView.layoutFittingCompressedSize)
        let totalHeight = CGFloat(activeToasts.count) * size.height
            + CGFloat(max(0, activeToasts.count - 1)) * Self.toastSpacing

        // Default position is top-center: x = safe.midX - size.width/2, y = safe.minY
        // Clamp so at least half remains visible within safe area
        let minOffsetX = safe.minX - safe.midX + size.width / 2 - size.width / 2
        let maxOffsetX = safe.maxX - safe.midX + size.width / 2 - size.width / 2
        let minOffsetY = -totalHeight / 2
        let maxOffsetY = safe.height - totalHeight / 2

        let clamped = CGPoint(
            x: min(max(toastGroupOffset.x, minOffsetX), maxOffsetX),
            y: min(max(toastGroupOffset.y, minOffsetY), maxOffsetY)
        )

        guard clamped != toastGroupOffset else { return }
        toastGroupOffset = clamped
        layoutToasts(animated: true)
    }

    // MARK: - Capability Execution

    /// Actions that represent meaningful service usage (not control/teardown).
    private static let recordableActions: [CapabilityType: Set<String>] = [
        .camera: ["start", "switch", ""],
        .microphone: ["start", ""],
        .location: ["get", "watch"],
        .clipboardRead: ["read", ""],
        .clipboardWrite: ["write", ""],
        .photoSave: ["save", "savePhoto", "saveVideo", ""],
    ]

    private func executeCapability(
        type: CapabilityType,
        action: String,
        options: [String: Any],
        completion: @escaping (Result<String, DoufuBridgeCapabilityError>) -> Void
    ) {
        if Self.recordableActions[type]?.contains(action) == true {
            let effectiveAction: String
            if action.isEmpty {
                switch type {
                case .clipboardRead: effectiveAction = "read"
                case .clipboardWrite: effectiveAction = "write"
                default: effectiveAction = "start"
                }
            } else {
                effectiveAction = action
            }
            CapabilityActivityStore.shared.recordEvent(
                projectID: project.id, capability: type, event: .serviceUsed, detail: effectiveAction
            )
        }
        switch type {
        case .clipboardRead:
            showCapabilityToast(type: .clipboardRead, persistent: false)
            executeClipboardRead(completion: completion)
        case .clipboardWrite:
            showCapabilityToast(type: .clipboardWrite, persistent: false)
            executeClipboardWrite(options: options, completion: completion)
        case .location:
            executeLocation(action: action, options: options, completion: completion)
        case .camera:
            switch action {
            case "stop":
                hideCapabilityToast(type: .camera)
                mediaSessionManager.stopCamera()
                completion(.success("null"))
            case "focus":
                let x = options["x"] as? Double ?? 0.5
                let y = options["y"] as? Double ?? 0.5
                completeCameraControl(mediaSessionManager.focus(x: x, y: y), completion: completion)
            case "exposure":
                let bias = Float(options["bias"] as? Double ?? 0.0)
                completeCameraControl(mediaSessionManager.setExposure(bias: bias), completion: completion)
            case "torch":
                let mode = options["mode"] as? String ?? "off"
                completeCameraControl(mediaSessionManager.setTorch(mode: mode), completion: completion)
            case "zoom":
                let factor = options["factor"] as? Double ?? 1.0
                completeCameraControl(mediaSessionManager.setZoom(factor: factor), completion: completion)
            case "mirror":
                let enabled = options["enabled"] as? Bool ?? true
                mediaSessionManager.setMirrorState(enabled)
                completion(.success("null"))
            default: // "start"
                let facing = options["facing"] as? String ?? "user"
                mediaSessionManager.startCamera(facing: facing, options: options) { [weak self] result in
                    switch result {
                    case .success:
                        if self?.mediaSessionManager.isCameraActive == true {
                            self?.showCapabilityToast(type: .camera, persistent: true)
                        }
                        completion(.success("null"))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }
        case .microphone:
            if action == "stop" {
                hideCapabilityToast(type: .microphone)
                mediaSessionManager.stopMicrophone()
                completion(.success("null"))
            } else {
                mediaSessionManager.startMicrophone { [weak self] result in
                    switch result {
                    case .success:
                        if self?.mediaSessionManager.isMicActive == true {
                            self?.showCapabilityToast(type: .microphone, persistent: true)
                        }
                        completion(.success("null"))
                    case .failure(let error):
                        completion(.failure(error))
                    }
                }
            }
        case .photoSave:
            showCapabilityToast(type: .photoSave, persistent: false)
            switch action {
            case "saveVideo":
                executeVideoSave(options: options, completion: completion)
            default: // "savePhoto"
                executePhotoSave(options: options, completion: completion)
            }
        }
    }

    // MARK: - Photos (Pick + Save)

    private func executePhotoPick(
        options: [String: Any],
        completion: @escaping (Result<String, DoufuBridgeCapabilityError>) -> Void
    ) {
        let multiple = options["multiple"] as? Bool ?? false
        let limit = options["limit"] as? Int ?? (multiple ? 9 : 1)

        var config = PHPickerConfiguration()
        config.selectionLimit = multiple ? limit : 1
        config.filter = .images

        let picker = PHPickerViewController(configuration: config)
        picker.delegate = self
        photoPickContext = (multiple: multiple, completion: completion)
        present(picker, animated: true)
    }

    private func executePhotoSave(
        options: [String: Any],
        completion: @escaping (Result<String, DoufuBridgeCapabilityError>) -> Void
    ) {
        guard let dataUrl = options["data"] as? String else {
            completion(.failure(DoufuBridgeCapabilityError(
                message: "Missing 'data' parameter (data URL string).",
                name: "TypeError"
            )))
            return
        }

        // Parse data URL: "data:image/jpeg;base64,/9j/4AAQ..."
        guard let commaIndex = dataUrl.firstIndex(of: ",") else {
            completion(.failure(DoufuBridgeCapabilityError(
                message: "Invalid data URL format.",
                name: "TypeError"
            )))
            return
        }
        let base64String = String(dataUrl[dataUrl.index(after: commaIndex)...])
        guard let imageData = Data(base64Encoded: base64String),
              let image = UIImage(data: imageData) else {
            completion(.failure(DoufuBridgeCapabilityError(
                message: "Failed to decode image from data URL.",
                name: "TypeError"
            )))
            return
        }

        PHPhotoLibrary.shared().performChanges({
            PHAssetCreationRequest.creationRequestForAsset(from: image)
        }) { success, error in
            Task { @MainActor in
                if success {
                    completion(.success("null"))
                } else {
                    completion(.failure(DoufuBridgeCapabilityError(
                        message: error?.localizedDescription ?? "Failed to save photo.",
                        name: "NotAllowedError"
                    )))
                }
            }
        }
    }

    private func executeVideoSave(
        options: [String: Any],
        completion: @escaping (Result<String, DoufuBridgeCapabilityError>) -> Void
    ) {
        guard let dataUrl = options["data"] as? String else {
            completion(.failure(DoufuBridgeCapabilityError(
                message: "Missing 'data' parameter (data URL string).",
                name: "TypeError"
            )))
            return
        }

        guard let commaIndex = dataUrl.firstIndex(of: ",") else {
            completion(.failure(DoufuBridgeCapabilityError(
                message: "Invalid data URL format.",
                name: "TypeError"
            )))
            return
        }
        let base64String = String(dataUrl[dataUrl.index(after: commaIndex)...])
        guard let videoData = Data(base64Encoded: base64String) else {
            completion(.failure(DoufuBridgeCapabilityError(
                message: "Failed to decode video from data URL.",
                name: "TypeError"
            )))
            return
        }

        // Write to a temp file — PHAssetCreationRequest requires a file URL for video
        let tmpDir = FileManager.default.temporaryDirectory
        let tmpFile = tmpDir.appendingPathComponent(UUID().uuidString + ".mp4")
        do {
            try videoData.write(to: tmpFile)
        } catch {
            completion(.failure(DoufuBridgeCapabilityError(
                message: "Failed to write video to temp file.",
                name: "NotReadableError"
            )))
            return
        }

        PHPhotoLibrary.shared().performChanges({
            PHAssetCreationRequest.forAsset().addResource(with: .video, fileURL: tmpFile, options: nil)
        }) { success, error in
            // Clean up temp file regardless of outcome
            try? FileManager.default.removeItem(at: tmpFile)
            Task { @MainActor in
                if success {
                    completion(.success("null"))
                } else {
                    completion(.failure(DoufuBridgeCapabilityError(
                        message: error?.localizedDescription ?? "Failed to save video.",
                        name: "NotAllowedError"
                    )))
                }
            }
        }
    }

    private func completeCameraControl(
        _ result: Result<Void, DoufuBridgeCapabilityError>,
        completion: @escaping (Result<String, DoufuBridgeCapabilityError>) -> Void
    ) {
        switch result {
        case .success:
            completion(.success("null"))
        case .failure(let error):
            completion(.failure(error))
        }
    }

    // MARK: - Clipboard

    private func executeClipboardRead(
        completion: @escaping (Result<String, DoufuBridgeCapabilityError>) -> Void
    ) {
        let text = UIPasteboard.general.string ?? ""
        if let jsonData = try? JSONEncoder().encode(text),
           let jsonString = String(data: jsonData, encoding: .utf8) {
            completion(.success(jsonString))
        } else {
            completion(.success("\"\""))
        }
    }

    private func executeClipboardWrite(
        options: [String: Any],
        completion: @escaping (Result<String, DoufuBridgeCapabilityError>) -> Void
    ) {
        let text = options["text"] as? String ?? ""
        UIPasteboard.general.string = text
        completion(.success("null"))
    }

    // MARK: - Location

    private func executeLocation(
        action: String,
        options: [String: Any],
        completion: @escaping (Result<String, DoufuBridgeCapabilityError>) -> Void
    ) {
        switch action {
        case "get":
            showCapabilityToast(type: .location, persistent: false)
            locationGetCompletions.append(completion)
            locationService.delegate = self
            if activeWatchIDs.isEmpty {
                locationService.requestLocation()
            }
            // If watch is active, didUpdateLocations will fulfill get completions naturally

        case "watch":
            let watchId = String(nextWatchID)
            nextWatchID += 1
            activeWatchIDs.insert(watchId)
            showCapabilityToast(type: .location, persistent: true)
            completion(.success("\"\(watchId)\""))
            locationService.delegate = self
            locationService.startUpdatingLocation()

        case "clearWatch":
            let watchId = options["watchId"] as? String ?? ""
            activeWatchIDs.remove(watchId)
            if activeWatchIDs.isEmpty && locationGetCompletions.isEmpty {
                locationService.stopUpdatingLocation()
                hideCapabilityToast(type: .location)
            }
            completion(.success("null"))

        default:
            completion(.failure(DoufuBridgeCapabilityError(
                message: "Unknown location action: \(action)",
                name: "NotSupportedError"
            )))
        }
    }

    private func locationJSON(from location: CLLocation) -> String {
        let coords = location.coordinate
        let ts = Int64(location.timestamp.timeIntervalSince1970 * 1000)
        return """
        {"coords":{"latitude":\(coords.latitude),"longitude":\(coords.longitude),\
        "accuracy":\(location.horizontalAccuracy),\
        "altitude":\(location.altitude),\
        "altitudeAccuracy":\(location.verticalAccuracy),\
        "heading":\(location.course),\
        "speed":\(location.speed)},\
        "timestamp":\(ts)}
        """
    }

    private func stopLocationServices() {
        guard let service = _locationService else { return }
        service.stopUpdatingLocation()
        service.delegate = nil
        let getCompletions = locationGetCompletions
        locationGetCompletions.removeAll()
        activeWatchIDs.removeAll()
        for c in getCompletions {
            c(.failure(DoufuBridgeCapabilityError(
                message: "Location service stopped.",
                name: "PositionError"
            )))
        }
    }

    private func presentCapabilityPrompt(
        type: CapabilityType,
        completion: @escaping (Bool) -> Void
    ) {
        capabilityPromptQueue.append((type: type, completion: completion))
        drainCapabilityPromptQueue()
    }

    private func drainCapabilityPromptQueue() {
        guard !isShowingCapabilityPrompt, !capabilityPromptQueue.isEmpty else {
            print("[Capability] drainQueue: skip (showing=\(isShowingCapabilityPrompt) queueCount=\(capabilityPromptQueue.count))")
            return
        }

        // Wait for any system alert or other presented VC to dismiss first.
        // No timeout — capability prompts must never be silently denied.
        if presentedViewController != nil {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
                self?.drainCapabilityPromptQueue()
            }
            return
        }

        let item = capabilityPromptQueue.removeFirst()
        isShowingCapabilityPrompt = true

        let title = String(
            format: String(localized: "capability.prompt.title_format"),
            projectName,
            item.type.displayName
        )
        let alert = UIAlertController(title: title, message: nil, preferredStyle: .alert)
        alert.addAction(UIAlertAction(
            title: String(localized: "capability.prompt.allow"),
            style: .default
        ) { [weak self] _ in
            self?.isShowingCapabilityPrompt = false
            item.completion(true)
            self?.drainCapabilityPromptQueue()
        })
        alert.addAction(UIAlertAction(
            title: String(localized: "capability.prompt.deny"),
            style: .cancel
        ) { [weak self] _ in
            self?.isShowingCapabilityPrompt = false
            item.completion(false)
            self?.drainCapabilityPromptQueue()
        })
        present(alert, animated: true)
    }
}

extension ProjectWorkspaceViewController: CLLocationManagerDelegate {
    func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        guard manager === capabilityLocationManager else { return }
        let status = manager.authorizationStatus
        guard status != .notDetermined else { return }
        let granted = (status == .authorizedWhenInUse || status == .authorizedAlways)
        let callbacks = pendingSystemPermissionCallbacks.removeValue(forKey: .location) ?? []
        for cb in callbacks { cb(granted) }
    }

    func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        guard manager === locationService, let location = locations.last else { return }
        let json = locationJSON(from: location)

        // Fulfill all pending get() completions
        let getCompletions = locationGetCompletions
        locationGetCompletions.removeAll()
        for c in getCompletions {
            c(.success(json))
        }

        // If no active watches and all gets fulfilled, stop updates
        if activeWatchIDs.isEmpty {
            locationService.stopUpdatingLocation()
        }

        // Push to all active watches
        for watchID in activeWatchIDs {
            doufuBridge.pushLocationUpdate(watchID: watchID, data: json)
        }
    }

    func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        guard manager === locationService else { return }
        let err = DoufuBridgeCapabilityError(
            message: error.localizedDescription,
            name: "PositionError"
        )
        // Reject pending get() completions; watches continue trying
        let getCompletions = locationGetCompletions
        locationGetCompletions.removeAll()
        for c in getCompletions {
            c(.failure(err))
        }
    }
}

// MARK: - PHPickerViewControllerDelegate

extension ProjectWorkspaceViewController: PHPickerViewControllerDelegate {
    func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
        picker.dismiss(animated: true)

        guard let context = photoPickContext else { return }
        photoPickContext = nil

        let multiple = context.multiple
        let completion = context.completion

        // Cancel → resolve null (single) or [] (multiple) instead of rejecting
        if results.isEmpty {
            completion(.success(multiple ? "[]" : "null"))
            return
        }

        // Ensure tmp/photos directory exists
        let photosDir = photosTmpDirectory()

        let group = DispatchGroup()
        var urls: [String] = []
        let lock = NSLock()

        for result in results {
            group.enter()
            result.itemProvider.loadObject(ofClass: UIImage.self) { object, _ in
                defer { group.leave() }
                guard let image = object as? UIImage else { return }

                // Downscale if needed (max 2048px on longest edge)
                let scaled = Self.downscaleIfNeeded(image, maxDimension: 2048)
                guard let jpegData = scaled.jpegData(compressionQuality: 0.9) else { return }

                let filename = UUID().uuidString + ".jpg"
                let fileURL = photosDir.appendingPathComponent(filename)
                do {
                    try jpegData.write(to: fileURL)
                    let urlPath = "/__doufu_tmp__/photos/\(filename)"
                    lock.lock()
                    urls.append(urlPath)
                    lock.unlock()
                } catch {
                    // Skip failed writes
                }
            }
        }

        group.notify(queue: .main) {
            if urls.isEmpty {
                completion(.failure(DoufuBridgeCapabilityError(
                    message: "Failed to load selected photos.",
                    name: "NotReadableError"
                )))
                return
            }
            // Use `multiple` flag (not results.count) to decide return format
            if multiple {
                if let jsonData = try? JSONEncoder().encode(urls),
                   let json = String(data: jsonData, encoding: .utf8) {
                    completion(.success(json))
                } else {
                    completion(.success("[]"))
                }
            } else {
                if let jsonData = try? JSONEncoder().encode(urls[0]),
                   let json = String(data: jsonData, encoding: .utf8) {
                    completion(.success(json))
                } else {
                    completion(.success("null"))
                }
            }
        }
    }

    private func photosTmpDirectory() -> URL {
        let dir = projectURL.appendingPathComponent("tmp/photos", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func downscaleIfNeeded(_ image: UIImage, maxDimension: CGFloat) -> UIImage {
        let size = image.size
        let longest = max(size.width, size.height)
        guard longest > maxDimension else { return image }
        let scale = maxDimension / longest
        let newSize = CGSize(width: size.width * scale, height: size.height * scale)
        let renderer = UIGraphicsImageRenderer(size: newSize)
        return renderer.image { _ in
            image.draw(in: CGRect(origin: .zero, size: newSize))
        }
    }

    /// Removes all temporary picked photos. Called on page navigation.
    func cleanUpPhotosTmp() {
        let dir = projectURL.appendingPathComponent("tmp/photos", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
    }
}

private final class WeakScriptMessageHandler: NSObject, WKScriptMessageHandler {
    weak var target: WKScriptMessageHandler?

    init(target: WKScriptMessageHandler) {
        self.target = target
        super.init()
    }

    func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
        target?.userContentController(userContentController, didReceive: message)
    }
}
