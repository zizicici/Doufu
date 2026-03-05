//
//  ProjectWorkspaceViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import UIKit
import WebKit

final class ProjectWorkspaceViewController: UIViewController {

    private var projectName: String
    private let projectURL: URL
    private let isNewlyCreated: Bool
    private let projectStore = AppProjectStore.shared
    private var hasProjectBeenModified = false
    private let jsErrorHandlerName = "jsError"
    private var lastPresentedJSErrorSignature: String?
    private lazy var jsErrorMessageProxy = WeakScriptMessageHandler(target: self)

    private let panelSize = CGSize(width: 168, height: 198)
    private var hasInitializedPanelPosition = false

    private lazy var webView: WKWebView = {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let script = WKUserScript(
            source: jsErrorBridgeScriptSource(),
            injectionTime: .atDocumentStart,
            forMainFrameOnly: false
        )
        configuration.userContentController.addUserScript(script)
        configuration.userContentController.add(jsErrorMessageProxy, name: jsErrorHandlerName)
        let view = WKWebView(frame: .zero, configuration: configuration)
        view.translatesAutoresizingMaskIntoConstraints = false
        view.navigationDelegate = self
        view.backgroundColor = .systemBackground
        view.scrollView.contentInsetAdjustmentBehavior = .never
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

    private lazy var panelHandleArea: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.isUserInteractionEnabled = true
        return view
    }()

    private lazy var panelHandleIndicator: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .tertiaryLabel
        view.layer.cornerRadius = 2
        view.layer.cornerCurve = .continuous
        return view
    }()

    private lazy var refreshButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "arrow.clockwise")
        configuration.title = "刷新"
        configuration.imagePadding = 6
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: #selector(didTapRefresh), for: .touchUpInside)
        return button
    }()

    private lazy var chatButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "bubble.left.and.bubble.right")
        configuration.title = "聊天"
        configuration.imagePadding = 6
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: #selector(didTapChat), for: .touchUpInside)
        return button
    }()

    private lazy var settingsButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "gearshape")
        configuration.title = "设置"
        configuration.imagePadding = 6
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: #selector(didTapSettings), for: .touchUpInside)
        return button
    }()

    private lazy var exitButton: UIButton = {
        var configuration = UIButton.Configuration.plain()
        configuration.image = UIImage(systemName: "xmark.circle")
        configuration.title = "退出"
        configuration.imagePadding = 6
        configuration.baseForegroundColor = .systemRed
        let button = UIButton(configuration: configuration)
        button.addTarget(self, action: #selector(didTapExit), for: .touchUpInside)
        return button
    }()

    init(projectName: String, projectURL: URL, isNewlyCreated: Bool) {
        self.projectName = projectName
        self.projectURL = projectURL
        self.isNewlyCreated = isNewlyCreated
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        webView.configuration.userContentController.removeScriptMessageHandler(forName: jsErrorHandlerName)
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = projectName
        view.backgroundColor = .systemBackground
        configureLayout()
        configureFloatingPanel()
        loadProjectPage()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        navigationController?.setNavigationBarHidden(true, animated: animated)
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if isMovingFromParent || isBeingDismissed {
            navigationController?.setNavigationBarHidden(false, animated: animated)
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()

        if !hasInitializedPanelPosition {
            positionPanelAtTopRight()
            hasInitializedPanelPosition = true
        } else {
            panelContainer.frame = clampedPanelFrame(panelContainer.frame)
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

    private func configureFloatingPanel() {
        view.addSubview(panelContainer)

        let stackView = UIStackView(arrangedSubviews: [refreshButton, chatButton, settingsButton, exitButton])
        stackView.translatesAutoresizingMaskIntoConstraints = false
        stackView.axis = .vertical
        stackView.spacing = 2
        stackView.distribution = .fillEqually

        panelContainer.contentView.addSubview(panelHandleArea)
        panelContainer.contentView.addSubview(stackView)
        panelHandleArea.addSubview(panelHandleIndicator)

        NSLayoutConstraint.activate([
            panelHandleArea.topAnchor.constraint(equalTo: panelContainer.contentView.topAnchor),
            panelHandleArea.leadingAnchor.constraint(equalTo: panelContainer.contentView.leadingAnchor),
            panelHandleArea.trailingAnchor.constraint(equalTo: panelContainer.contentView.trailingAnchor),
            panelHandleArea.heightAnchor.constraint(equalToConstant: 28),

            panelHandleIndicator.centerXAnchor.constraint(equalTo: panelHandleArea.centerXAnchor),
            panelHandleIndicator.centerYAnchor.constraint(equalTo: panelHandleArea.centerYAnchor),
            panelHandleIndicator.widthAnchor.constraint(equalToConstant: 34),
            panelHandleIndicator.heightAnchor.constraint(equalToConstant: 4),

            stackView.topAnchor.constraint(equalTo: panelHandleArea.bottomAnchor, constant: 4),
            stackView.leadingAnchor.constraint(equalTo: panelContainer.contentView.leadingAnchor, constant: 4),
            stackView.trailingAnchor.constraint(equalTo: panelContainer.contentView.trailingAnchor, constant: -4),
            stackView.bottomAnchor.constraint(equalTo: panelContainer.contentView.bottomAnchor, constant: -6)
        ])

        let panGesture = UIPanGestureRecognizer(target: self, action: #selector(handlePanelPan(_:)))
        panelHandleArea.addGestureRecognizer(panGesture)
    }

    private func loadProjectPage() {
        let entryURL = projectURL.appendingPathComponent("index.html")
        guard FileManager.default.fileExists(atPath: entryURL.path) else {
            showLoadError("项目入口文件 index.html 不存在。")
            return
        }

        webView.loadFileURL(entryURL, allowingReadAccessTo: projectURL)
    }

    private func positionPanelAtTopRight() {
        let safeFrame = view.safeAreaLayoutGuide.layoutFrame
        let margin: CGFloat = 12
        let origin = CGPoint(
            x: safeFrame.maxX - panelSize.width - margin,
            y: safeFrame.minY + margin
        )
        panelContainer.frame = clampedPanelFrame(CGRect(origin: origin, size: panelSize))
    }

    private func clampedPanelFrame(_ frame: CGRect) -> CGRect {
        let safeFrame = view.safeAreaLayoutGuide.layoutFrame.insetBy(dx: 8, dy: 8)
        var adjusted = frame
        adjusted.size = panelSize

        if adjusted.minX < safeFrame.minX {
            adjusted.origin.x = safeFrame.minX
        }
        if adjusted.maxX > safeFrame.maxX {
            adjusted.origin.x = safeFrame.maxX - adjusted.width
        }
        if adjusted.minY < safeFrame.minY {
            adjusted.origin.y = safeFrame.minY
        }
        if adjusted.maxY > safeFrame.maxY {
            adjusted.origin.y = safeFrame.maxY - adjusted.height
        }
        return adjusted
    }

    @objc
    private func didTapRefresh() {
        webView.reload()
    }

    @objc
    private func didTapChat() {
        let chatController = CodexProjectChatViewController(projectName: projectName, projectURL: projectURL)
        chatController.onProjectFilesUpdated = { [weak self] in
            guard let self else { return }
            self.hasProjectBeenModified = true
            self.projectStore.touchProjectUpdatedAt(projectURL: self.projectURL)
            self.webView.reload()
        }

        let navigationController = UINavigationController(rootViewController: chatController)
        navigationController.modalPresentationStyle = .pageSheet
        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigationController, animated: true)
    }

    @objc
    private func didTapSettings() {
        let settingsController = ProjectSettingsViewController(
            projectURL: projectURL,
            projectName: projectName
        )
        settingsController.onProjectUpdated = { [weak self] updatedProjectName in
            guard let self else { return }
            self.projectName = updatedProjectName
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
        present(navigationController, animated: true)
    }

    @objc
    private func didTapExit() {
        if isNewlyCreated && !hasProjectBeenModified {
            presentUnsavedNewProjectAlert()
            return
        }
        presentNormalExitAlert()
    }

    @objc
    private func handlePanelPan(_ gesture: UIPanGestureRecognizer) {
        let translation = gesture.translation(in: view)
        var nextFrame = panelContainer.frame
        nextFrame.origin.x += translation.x
        nextFrame.origin.y += translation.y
        panelContainer.frame = clampedPanelFrame(nextFrame)
        gesture.setTranslation(.zero, in: view)
    }

    private func showLoadError(_ message: String) {
        let alert = UIAlertController(title: "加载失败", message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
        present(alert, animated: true)
    }

    private func presentNormalExitAlert() {
        let alert = UIAlertController(
            title: "退出项目",
            message: "确认退出当前项目并返回首页吗？",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "退出", style: .destructive, handler: { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        }))
        present(alert, animated: true)
    }

    private func presentUnsavedNewProjectAlert() {
        let alert = UIAlertController(
            title: "保存新项目？",
            message: "这个新项目还没有任何修改。你可以选择保存，或不保存直接退出。",
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "取消", style: .cancel))
        alert.addAction(UIAlertAction(title: "保存并退出", style: .default, handler: { [weak self] _ in
            self?.navigationController?.popViewController(animated: true)
        }))
        alert.addAction(UIAlertAction(title: "不保存", style: .destructive, handler: { [weak self] _ in
            self?.discardProjectAndExit()
        }))
        present(alert, animated: true)
    }

    private func discardProjectAndExit() {
        do {
            try projectStore.deleteProject(projectURL: projectURL)
            navigationController?.popViewController(animated: true)
        } catch {
            let alert = UIAlertController(
                title: "删除失败",
                message: error.localizedDescription,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(title: "知道了", style: .default))
            present(alert, animated: true)
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
        let message = (payload["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Unknown JS error"
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
            details += "\n来源：\(source)"
        }
        if line > 0 || column > 0 {
            details += "\n位置：\(line):\(column)"
        }

        guard presentedViewController == nil else {
            return
        }
        let alert = UIAlertController(
            title: "页面脚本错误",
            message: details,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: "知道了", style: .default))
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
            guard let imageData = image.pngData() else {
                return
            }
            let previewURL = self.projectURL.appendingPathComponent("preview.png")
            try? imageData.write(to: previewURL, options: .atomic)
        }
    }
}

extension ProjectWorkspaceViewController: WKNavigationDelegate {
    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        lastPresentedJSErrorSignature = nil
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
