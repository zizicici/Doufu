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

    private enum PanelSide {
        case left
        case right
    }

    private enum PanelPresentationState {
        case expanded
        case collapsed(PanelSide)
    }

    private(set) var project: AppProjectRecord
    private let isNewlyCreated: Bool
    private let projectStore = AppProjectStore.shared
    private let projectActivityStore = ProjectActivityStore.shared
    private let coordinator = ProjectLifecycleCoordinator.shared
    var onDismissed: (() -> Void)?
    private var hasProjectBeenModified = false
    private var dismissInteractionController: ProjectDismissInteractionController?
    private let jsErrorHandlerName = "jsError"
    private var lastPresentedJSErrorSignature: String?
    private lazy var jsErrorMessageProxy = WeakScriptMessageHandler(target: self)

    private let panelSize = CGSize(width: 72, height: 278)
    private let collapsedHandleSize = CGSize(width: 28, height: 72)
    private let collapsedVisibleWidth: CGFloat = 10
    private let panelMargin: CGFloat = 10
    private let panelAutoCollapseDelay: TimeInterval = 2.4
    private let panelAnimationDuration: TimeInterval = 0.22
    private let collapsedHandleVisibleAlpha: CGFloat = 0.5
    private let edgeSnapThreshold: CGFloat = 28
    private var hasInitializedPanelPosition = false
    private var panelState: PanelPresentationState = .expanded
    private var panelPanStartFrame: CGRect = .zero
    private var autoCollapseWorkItem: DispatchWorkItem?
    private var chatNavigationController: UINavigationController?
    private var webLoadingCover: UIView?
    private let webServer: LocalWebServer
    private let doufuBridge: DoufuBridge
    private var chatPresentationTask: Task<Void, Never>?

    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        // Per-project data store: IndexedDB, cookies, cache are isolated per project
        // and persist independently of git checkpoints.
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
        view.layer.cornerRadius = 18
        view.layer.cornerCurve = .continuous
        view.layer.masksToBounds = true
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor
        view.translatesAutoresizingMaskIntoConstraints = true
        return view
    }()

    private lazy var leftDragArea: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isUserInteractionEnabled = true
        return view
    }()

    private lazy var rightDragArea: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isUserInteractionEnabled = true
        return view
    }()

    private lazy var leftDragIndicator: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .tertiaryLabel
        view.layer.cornerRadius = 1.5
        view.layer.cornerCurve = .continuous
        view.alpha = 0.85
        return view
    }()

    private lazy var rightDragIndicator: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .tertiaryLabel
        view.layer.cornerRadius = 1.5
        view.layer.cornerCurve = .continuous
        view.alpha = 0.85
        return view
    }()

    private lazy var collapsedHandleView: UIVisualEffectView = {
        let blur = UIBlurEffect(style: .systemThinMaterial)
        let view = UIVisualEffectView(effect: blur)
        view.layer.cornerRadius = 12
        view.layer.cornerCurve = .continuous
        view.layer.masksToBounds = true
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.separator.withAlphaComponent(0.35).cgColor
        view.alpha = 0
        view.isHidden = true
        view.translatesAutoresizingMaskIntoConstraints = true
        return view
    }()

    private lazy var collapsedHandleIndicator: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .tertiaryLabel
        view.layer.cornerRadius = 2
        view.layer.cornerCurve = .continuous
        view.alpha = 0.9
        return view
    }()

    private lazy var refreshButton: UIButton = {
        let button = makePanelIconButton(systemName: "arrow.clockwise", tintColor: nil)
        button.accessibilityLabel = String(localized: "workspace.panel.refresh")
        button.addTarget(self, action: #selector(didTapRefresh), for: .touchUpInside)
        return button
    }()

    private lazy var chatButton: UIButton = {
        let button = makePanelIconButton(systemName: "bubble.left.and.bubble.right", tintColor: nil)
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

    init(project: AppProjectRecord, isNewlyCreated: Bool) {
        self.project = project
        self.isNewlyCreated = isNewlyCreated
        self.webServer = LocalWebServer(projectURL: project.appURL, projectID: project.id)
        self.doufuBridge = DoufuBridge(projectURL: project.appURL)
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        autoCollapseWorkItem?.cancel()
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
        configureInteractiveDismiss()
        projectActivityStore.markProjectViewed(projectID: project.id)
        AppProjectStore.shared.ensureProjectMemoryDocument(at: project.appURL, projectName: projectName)
        loadProjectPage()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed {
            coordinator.closeProject(projectID: project.id)
            onDismissed?()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        if !hasInitializedPanelPosition {
            let safeFrame = currentSafeFrame()
            if AppProjectStore.shared.isAutoCollapsePanelEnabled {
                // Start collapsed directly
                let preferredY = safeFrame.minY + panelMargin
                collapsePanel(to: .right, preferredY: preferredY, animated: false)
            } else {
                let initialFrame = expandedFrame(
                    for: .right,
                    preferredY: safeFrame.minY + panelMargin,
                    safeFrame: safeFrame
                )
                panelContainer.frame = initialFrame
                panelContainer.alpha = 1
                panelContainer.isHidden = false
                panelState = .expanded
            }
            hasInitializedPanelPosition = true
        } else {
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

    private func configureInteractiveDismiss() {
        let interaction = ProjectDismissInteractionController(viewController: self)
        interaction.isGestureEnabled = true
        dismissInteractionController = interaction
        if let delegate = transitioningDelegate as? ProjectOpenTransitionDelegate {
            delegate.interactionController = interaction
        }
    }

    private func configureFloatingPanel() {
        view.addSubview(panelContainer)
        view.addSubview(collapsedHandleView)

        let stackView = UIStackView(arrangedSubviews: [refreshButton, chatButton, filesButton, settingsButton, exitButton])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.spacing = 4
        stackView.distribution = .fillEqually

        panelContainer.contentView.addSubview(stackView)
        panelContainer.contentView.addSubview(leftDragArea)
        panelContainer.contentView.addSubview(rightDragArea)
        leftDragArea.addSubview(leftDragIndicator)
        rightDragArea.addSubview(rightDragIndicator)
        collapsedHandleView.contentView.addSubview(collapsedHandleIndicator)

        NSLayoutConstraint.activate([
            leftDragArea.topAnchor.constraint(equalTo: panelContainer.contentView.topAnchor),
            leftDragArea.leadingAnchor.constraint(equalTo: panelContainer.contentView.leadingAnchor),
            leftDragArea.bottomAnchor.constraint(equalTo: panelContainer.contentView.bottomAnchor),
            leftDragArea.widthAnchor.constraint(equalToConstant: 16),

            rightDragArea.topAnchor.constraint(equalTo: panelContainer.contentView.topAnchor),
            rightDragArea.trailingAnchor.constraint(equalTo: panelContainer.contentView.trailingAnchor),
            rightDragArea.bottomAnchor.constraint(equalTo: panelContainer.contentView.bottomAnchor),
            rightDragArea.widthAnchor.constraint(equalToConstant: 16),

            leftDragIndicator.centerXAnchor.constraint(equalTo: leftDragArea.centerXAnchor),
            leftDragIndicator.centerYAnchor.constraint(equalTo: leftDragArea.centerYAnchor),
            leftDragIndicator.widthAnchor.constraint(equalToConstant: 3),
            leftDragIndicator.heightAnchor.constraint(equalToConstant: 34),

            rightDragIndicator.centerXAnchor.constraint(equalTo: rightDragArea.centerXAnchor),
            rightDragIndicator.centerYAnchor.constraint(equalTo: rightDragArea.centerYAnchor),
            rightDragIndicator.widthAnchor.constraint(equalToConstant: 3),
            rightDragIndicator.heightAnchor.constraint(equalToConstant: 34),

            stackView.topAnchor.constraint(equalTo: panelContainer.contentView.topAnchor, constant: 8),
            stackView.leadingAnchor.constraint(equalTo: leftDragArea.trailingAnchor, constant: 2),
            stackView.trailingAnchor.constraint(equalTo: rightDragArea.leadingAnchor, constant: -2),
            stackView.bottomAnchor.constraint(equalTo: panelContainer.contentView.bottomAnchor, constant: -8),

            collapsedHandleIndicator.centerXAnchor.constraint(equalTo: collapsedHandleView.contentView.centerXAnchor),
            collapsedHandleIndicator.centerYAnchor.constraint(equalTo: collapsedHandleView.contentView.centerYAnchor),
            collapsedHandleIndicator.widthAnchor.constraint(equalToConstant: 14),
            collapsedHandleIndicator.heightAnchor.constraint(equalToConstant: 3)
        ])

        let panelPanGestureLeft = UIPanGestureRecognizer(target: self, action: #selector(handleExpandedPanelPan(_:)))
        let panelPanGestureRight = UIPanGestureRecognizer(target: self, action: #selector(handleExpandedPanelPan(_:)))
        leftDragArea.addGestureRecognizer(panelPanGestureLeft)
        rightDragArea.addGestureRecognizer(panelPanGestureRight)

        let collapsedTapGesture = UITapGestureRecognizer(target: self, action: #selector(didTapCollapsedHandle))
        let collapsedPanGesture = UIPanGestureRecognizer(target: self, action: #selector(handleCollapsedHandlePan(_:)))
        collapsedTapGesture.require(toFail: collapsedPanGesture)
        collapsedHandleView.addGestureRecognizer(collapsedTapGesture)
        collapsedHandleView.addGestureRecognizer(collapsedPanGesture)
    }

    private func makePanelIconButton(systemName: String, tintColor: UIColor?) -> UIButton {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: systemName)
        configuration.title = nil
        configuration.imagePlacement = .all
        configuration.baseForegroundColor = tintColor
        configuration.contentInsets = NSDirectionalEdgeInsets(top: 4, leading: 4, bottom: 4, trailing: 4)
        let button = UIButton(configuration: configuration)
        let symbolConfiguration = UIImage.SymbolConfiguration(pointSize: 21, weight: .semibold)
        button.setPreferredSymbolConfiguration(symbolConfiguration, forImageIn: .normal)
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

    private func expandedFrame(
        for side: PanelSide,
        preferredY: CGFloat,
        safeFrame: CGRect? = nil
    ) -> CGRect {
        let safe = safeFrame ?? currentSafeFrame()
        let clampedY = min(max(preferredY, safe.minY), safe.maxY - panelSize.height)
        let x: CGFloat = side == .left ? safe.minX : safe.maxX - panelSize.width
        return CGRect(x: x, y: clampedY, width: panelSize.width, height: panelSize.height)
    }

    private func clampedExpandedFrame(_ frame: CGRect, safeFrame: CGRect? = nil) -> CGRect {
        let safe = safeFrame ?? currentSafeFrame()
        var adjusted = frame
        adjusted.size = panelSize
        adjusted.origin.x = min(max(adjusted.origin.x, safe.minX), safe.maxX - panelSize.width)
        adjusted.origin.y = min(max(adjusted.origin.y, safe.minY), safe.maxY - panelSize.height)
        return adjusted
    }

    private func collapsedHandleFrame(
        for side: PanelSide,
        preferredY: CGFloat,
        safeFrame: CGRect? = nil
    ) -> CGRect {
        let safe = safeFrame ?? currentSafeFrame()
        let clampedY = min(max(preferredY, safe.minY), safe.maxY - collapsedHandleSize.height)
        let x: CGFloat
        switch side {
        case .left:
            x = safe.minX - (collapsedHandleSize.width - collapsedVisibleWidth)
        case .right:
            x = safe.maxX - collapsedVisibleWidth
        }
        return CGRect(x: x, y: clampedY, width: collapsedHandleSize.width, height: collapsedHandleSize.height)
    }

    private func sideIfShouldSnap(for expandedFrame: CGRect, safeFrame: CGRect? = nil) -> PanelSide? {
        let safe = safeFrame ?? currentSafeFrame()
        let leftDistance = expandedFrame.minX - safe.minX
        if leftDistance <= edgeSnapThreshold {
            return .left
        }
        let rightDistance = safe.maxX - expandedFrame.maxX
        if rightDistance <= edgeSnapThreshold {
            return .right
        }
        return nil
    }

    private func relayoutPanelForCurrentState() {
        let safeFrame = currentSafeFrame()
        switch panelState {
        case .expanded:
            panelContainer.frame = clampedExpandedFrame(panelContainer.frame, safeFrame: safeFrame)
            panelContainer.alpha = 1
            panelContainer.isHidden = false
            collapsedHandleView.alpha = 0
            collapsedHandleView.isHidden = true
        case let .collapsed(side):
            panelContainer.isHidden = true
            collapsedHandleView.isHidden = false
            collapsedHandleView.alpha = collapsedHandleVisibleAlpha
            collapsedHandleView.frame = collapsedHandleFrame(
                for: side,
                preferredY: collapsedHandleView.frame.minY,
                safeFrame: safeFrame
            )
            updateCollapsedHandleAppearance(for: side)
        }
    }

    private func updateCollapsedHandleAppearance(for side: PanelSide) {
        collapsedHandleIndicator.backgroundColor = UIColor.tertiaryLabel
        collapsedHandleIndicator.transform = .identity
    }

    private func expandPanel(
        from side: PanelSide,
        preferredY: CGFloat,
        animated: Bool,
        scheduleAutoCollapseAfter: Bool
    ) {
        cancelAutoCollapse()
        let safeFrame = currentSafeFrame()
        let targetFrame = expandedFrame(for: side, preferredY: preferredY, safeFrame: safeFrame)
        var startFrame = targetFrame
        switch side {
        case .left:
            startFrame.origin.x = safeFrame.minX - panelSize.width + collapsedVisibleWidth
        case .right:
            startFrame.origin.x = safeFrame.maxX - collapsedVisibleWidth
        }

        panelState = .expanded
        panelContainer.isHidden = false
        panelContainer.frame = animated ? startFrame : targetFrame
        panelContainer.alpha = animated ? 0.92 : 1
        collapsedHandleView.isHidden = false

        let applyFinalState = {
            self.panelContainer.frame = targetFrame
            self.panelContainer.alpha = 1
            self.collapsedHandleView.alpha = 0
        }

        let finalize = {
            self.collapsedHandleView.isHidden = true
            if scheduleAutoCollapseAfter {
                self.scheduleAutoCollapse()
            }
        }

        if animated {
            UIView.animate(
                withDuration: panelAnimationDuration,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState]
            ) {
                applyFinalState()
            } completion: { _ in
                finalize()
            }
        } else {
            applyFinalState()
            finalize()
        }
    }

    private func collapsePanel(to side: PanelSide, preferredY: CGFloat, animated: Bool) {
        cancelAutoCollapse()
        let safeFrame = currentSafeFrame()
        let targetHandleFrame = collapsedHandleFrame(for: side, preferredY: preferredY, safeFrame: safeFrame)
        let targetPanelFrame = expandedFrame(
            for: side,
            preferredY: targetHandleFrame.midY - panelSize.height / 2,
            safeFrame: safeFrame
        )

        panelState = .collapsed(side)
        updateCollapsedHandleAppearance(for: side)
        collapsedHandleView.frame = targetHandleFrame
        collapsedHandleView.isHidden = false
        collapsedHandleView.alpha = animated ? 0 : collapsedHandleVisibleAlpha

        let applyFinalState = {
            self.panelContainer.frame = targetPanelFrame
            self.panelContainer.alpha = 0
            self.collapsedHandleView.alpha = self.collapsedHandleVisibleAlpha
        }

        let finalize = {
            self.panelContainer.isHidden = true
        }

        if animated {
            UIView.animate(
                withDuration: panelAnimationDuration,
                delay: 0,
                options: [.curveEaseOut, .beginFromCurrentState]
            ) {
                applyFinalState()
            } completion: { _ in
                finalize()
            }
        } else {
            applyFinalState()
            finalize()
        }
    }

    private func scheduleAutoCollapse() {
        cancelAutoCollapse()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            guard case .expanded = panelState else {
                return
            }
            guard let side = sideIfShouldSnap(for: panelContainer.frame) else {
                return
            }
            let y = panelContainer.frame.midY - collapsedHandleSize.height / 2
            collapsePanel(to: side, preferredY: y, animated: true)
        }
        autoCollapseWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + panelAutoCollapseDelay, execute: workItem)
    }

    private func cancelAutoCollapse() {
        autoCollapseWorkItem?.cancel()
        autoCollapseWorkItem = nil
    }

    @objc
    private func didTapCollapsedHandle() {
        guard case let .collapsed(side) = panelState else {
            return
        }
        let y = collapsedHandleView.frame.midY - panelSize.height / 2
        expandPanel(from: side, preferredY: y, animated: true, scheduleAutoCollapseAfter: true)
    }

    @objc
    private func handleCollapsedHandlePan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            guard case let .collapsed(side) = panelState else { return }
            let y = collapsedHandleView.frame.midY - panelSize.height / 2
            expandPanel(from: side, preferredY: y, animated: false, scheduleAutoCollapseAfter: false)
            panelPanStartFrame = panelContainer.frame
        case .changed:
            let translation = gesture.translation(in: view)
            var frame = panelPanStartFrame
            frame.origin.x += translation.x
            frame.origin.y += translation.y
            panelContainer.frame = clampedExpandedFrame(frame)
        case .ended, .cancelled, .failed:
            let clamped = clampedExpandedFrame(panelContainer.frame)
            panelContainer.frame = clamped
            if let side = sideIfShouldSnap(for: clamped) {
                let y = clamped.midY - collapsedHandleSize.height / 2
                collapsePanel(to: side, preferredY: y, animated: true)
            } else {
                panelState = .expanded
                collapsedHandleView.alpha = 0
                collapsedHandleView.isHidden = true
            }
        default:
            break
        }
    }

    @objc
    private func handleExpandedPanelPan(_ gesture: UIPanGestureRecognizer) {
        switch gesture.state {
        case .began:
            cancelAutoCollapse()
            panelPanStartFrame = panelContainer.frame
        case .changed:
            let translation = gesture.translation(in: view)
            var frame = panelPanStartFrame
            frame.origin.x += translation.x
            frame.origin.y += translation.y
            panelContainer.frame = clampedExpandedFrame(frame)
        case .ended, .cancelled, .failed:
            let clamped = clampedExpandedFrame(panelContainer.frame)
            panelContainer.frame = clamped
            if let side = sideIfShouldSnap(for: clamped) {
                let y = clamped.midY - collapsedHandleSize.height / 2
                collapsePanel(to: side, preferredY: y, animated: true)
            } else {
                panelState = .expanded
                collapsedHandleView.alpha = 0
                collapsedHandleView.isHidden = true
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
        session.onProjectFilesUpdated = { [weak self] in
            guard let self else { return }
            self.hasProjectBeenModified = true
            self.projectActivityStore.markProjectViewed(projectID: self.project.id)
            self.projectStore.touchProjectUpdatedAt(projectID: self.project.id)
            self.webView.reload()
        }
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
        let settingsController = ProjectSettingsViewController(
            projectURL: projectURL,
            projectName: projectName
        )
        settingsController.onProjectUpdated = { [weak self] updatedProjectName in
            guard let self else { return }
            // Rename DB write + session sync already done by
            // ProjectSettingsVC → coordinator.renameProject.
            // Only update local UI state here.
            self.project = AppProjectRecord(
                id: self.project.id,
                name: updatedProjectName,
                projectURL: self.project.projectURL,
                createdAt: self.project.createdAt,
                updatedAt: Date()
            )
            self.title = updatedProjectName
            self.hasProjectBeenModified = true
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
        present(navigationController, animated: true)
    }

    @objc
    private func didTapExit() {
        scheduleAutoCollapse()
        if isNewlyCreated && !hasProjectBeenModified {
            presentUnsavedNewProjectAlert()
            return
        }
        dismiss(animated: true)
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

    private func presentUnsavedNewProjectAlert() {
        let alert = UIAlertController(
            title: String(localized: "workspace.alert.save_new_project.title"),
            message: String(localized: "workspace.alert.save_new_project.message"),
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.action.cancel"), style: .cancel))
        alert.addAction(UIAlertAction(title: String(localized: "workspace.action.save_and_exit"), style: .default, handler: { [weak self] _ in
            self?.dismiss(animated: true)
        }))
        alert.addAction(UIAlertAction(title: String(localized: "workspace.action.discard"), style: .destructive, handler: { [weak self] _ in
            self?.discardProjectAndExit()
        }))
        present(alert, animated: true)
    }

    private func discardProjectAndExit() {
        Task {
            do {
                try await coordinator.deleteProject(projectID: project.id, projectURL: projectURL)
                dismiss(animated: true)
            } catch {
                let alert = UIAlertController(
                    title: String(localized: "workspace.alert.delete_failed.title"),
                    message: error.localizedDescription,
                    preferredStyle: .alert
                )
                alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
                present(alert, animated: true)
            }
        }
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
            let legacyPNGURL = self.projectURL.appendingPathComponent("preview.png")
            try? imageData.write(to: previewURL, options: .atomic)
            if FileManager.default.fileExists(atPath: legacyPNGURL.path) {
                try? FileManager.default.removeItem(at: legacyPNGURL)
            }
        }
    }
}

extension ProjectWorkspaceViewController: UIAdaptivePresentationControllerDelegate {
    func presentationControllerDidDismiss(_ presentationController: UIPresentationController) {
        if presentationController.presentedViewController === chatNavigationController {
            chatNavigationController = nil
        }
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
