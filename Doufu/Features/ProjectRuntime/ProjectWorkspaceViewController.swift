//
//  ProjectWorkspaceViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

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

    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
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
        self.doufuBridge = DoufuBridge(projectURL: project.appURL)
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
        let panelTrailing = panelFrame.maxX
        let distance = abs(panelTrailing - center.x)
        return distance < exitTargetSize / 2
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
            projectName: projectName
        )
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

extension ProjectWorkspaceViewController: WKNavigationDelegate {
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
