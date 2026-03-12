//
//  ChatViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import UIKit

@MainActor
final class ChatViewController: UIViewController {

    var isReadOnly = false

    private let session: ChatSession
    private var toolPermissionMode: ToolPermissionMode = .standard
    private var initialLoadTask: Task<Void, Never>?
    private var appearReloadTask: Task<Void, Never>?
    private var modelSelectionReloadTask: Task<Void, Never>?
    private var pendingModelSelectionReload = false

    /// Server base URL for code validation (uses localhost instead of file://).
    var validationServerBaseURL: URL?
    /// A temporary bridge whose storage is isolated from real user data.
    var validationBridge: DoufuBridge?

    private let inputMinHeight: CGFloat = 38
    private let inputMaxHeight: CGFloat = 120
    private var inputHeightConstraint: NSLayoutConstraint?

    // MARK: - Convenience Accessors

    private var messageStore: ChatMessageStore { session.messageStore }
    private var modelSelection: ChatModelSelectionManager { session.modelSelection }
    private var threadManager: ChatThreadManager { session.threadManager }
    private var taskCoordinator: ChatTaskCoordinator { session.taskCoordinator }
    private var project: AppProjectRecord { session.project }
    private var projectIdentifier: String { session.projectID }
    private var projectName: String { session.project.name }
    private var workspaceURL: URL { session.project.appURL }

    // MARK: - UI Elements

    private lazy var modelBarButtonItem = UIBarButtonItem(
        image: UIImage(systemName: "theatermask.and.paintbrush"),
        style: .plain,
        target: self,
        action: #selector(didTapModelSettings)
    )

    private lazy var usageBarButtonItem = UIBarButtonItem(
        image: UIImage(systemName: "chart.bar"),
        style: .plain,
        target: self,
        action: #selector(didTapProjectUsage)
    )

    private lazy var moreBarButtonItem = UIBarButtonItem(
        image: UIImage(systemName: "ellipsis.circle"),
        style: .plain,
        target: nil,
        action: nil
    )

    private lazy var threadBarButtonItem = UIBarButtonItem(
        title: String(localized: "chat.thread.button_title"),
        style: .plain,
        target: nil,
        action: nil
    )

    private lazy var tableView: UITableView = {
        let tableView = UITableView(frame: .zero, style: .plain)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .interactive
        tableView.backgroundColor = .doufuBackground
        tableView.register(ChatMessageCell.self, forCellReuseIdentifier: ChatMessageCell.reuseIdentifier)
        return tableView
    }()

    private lazy var inputContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .systemBackground
        return view
    }()

    private lazy var inputTextView: UITextView = {
        let view = UITextView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.backgroundColor = .secondarySystemGroupedBackground
        view.layer.cornerRadius = 12
        view.layer.cornerCurve = .continuous
        view.textContainerInset = UIEdgeInsets(top: 9, left: 8, bottom: 9, right: 8)
        view.textContainer.lineFragmentPadding = 0
        view.font = .systemFont(ofSize: 16)
        view.delegate = self
        view.isScrollEnabled = false
        view.returnKeyType = .default
        return view
    }()

    private lazy var inputPlaceholderLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.text = String(localized: "chat.input.placeholder")
        label.textColor = .placeholderText
        label.font = .systemFont(ofSize: 16)
        label.numberOfLines = 1
        return label
    }()

    private lazy var sendButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.image = UIImage(systemName: "arrow.up")
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(didTapSend), for: .touchUpInside)
        button.accessibilityLabel = String(localized: "chat.action.send")
        return button
    }()

    init(session: ChatSession) {
        self.session = session
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: - View Lifecycle

    override func viewDidLoad() {
        super.viewDidLoad()
        title = nil
        view.backgroundColor = .doufuBackground

        session.setUIObserver(self)

        configureNavigation()
        configureLayout()
        ensureProjectMemoryDocumentIfNeeded()
        toolPermissionMode = AppProjectStore.shared.loadToolPermissionMode(projectURL: project.projectURL)
        if isReadOnly {
            inputContainer.isHidden = true
        }
        refreshInputPlaceholder()
        refreshSendButton()

        initialLoadTask = Task { [weak self] in
            guard let self else { return }
            defer { self.initialLoadTask = nil }
            await self.reloadModelSelectionContext()
            do {
                try self.session.restoreThreadStateIfNeeded()
            } catch {
                self.presentChatStorageError(error)
            }
            self.refreshSendButton()
        }
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        session.setUIObserver(self)

        // Re-read permission mode in case it was changed from settings.
        toolPermissionMode = AppProjectStore.shared.loadToolPermissionMode(projectURL: project.projectURL)

        // Sync tableView with messageStore in case messages were added
        // while the VC was dismissed (e.g., execution continued in background).
        tableView.reloadData()
        scrollToBottomIfNeeded(force: true)
        refreshSendButton()

        appearReloadTask?.cancel()
        appearReloadTask = Task { [weak self] in
            guard let self else { return }
            if let initialLoadTask = self.initialLoadTask {
                await initialLoadTask.value
            }
            await self.reloadModelSelectionContext()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateInputTextViewHeight()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if view.window == nil {
            session.setUIObserver(nil)
            initialLoadTask?.cancel()
            initialLoadTask = nil
            appearReloadTask?.cancel()
            appearReloadTask = nil
            modelSelectionReloadTask?.cancel()
            modelSelectionReloadTask = nil
            pendingModelSelectionReload = false
            modelSelection.cancelRefreshTask()
        }
    }

    private func reloadModelSelectionContext() async {
        if let reloadTask = modelSelectionReloadTask {
            pendingModelSelectionReload = true
            await reloadTask.value
            return
        }

        let reloadTask = Task { [weak self] in
            guard let self else { return }
            await self.runModelSelectionReloadLoop()
        }
        modelSelectionReloadTask = reloadTask
        await reloadTask.value
    }

    private func runModelSelectionReloadLoop() async {
        repeat {
            pendingModelSelectionReload = false
            await modelSelection.reloadModelSelectionContext()
        } while pendingModelSelectionReload && !Task.isCancelled
        modelSelectionReloadTask = nil
    }

    // MARK: - Navigation

    private func configureNavigation() {
        navigationItem.rightBarButtonItems = [moreBarButtonItem, modelBarButtonItem, usageBarButtonItem]
        refreshNavigationItems()
    }

    func refreshNavigationItems() {
        let isExecuting = taskCoordinator.isExecuting
        threadBarButtonItem.title = threadManager.currentThread?.title ?? String(localized: "chat.thread.button_title")
        threadBarButtonItem.menu = isExecuting ? nil : ChatMenuBuilder.threadMenu(
            threads: threadManager.threadIndex?.threads ?? [],
            currentThreadID: threadManager.currentThread?.id,
            onSwitch: { [weak self] threadID in self?.threadManager.handleSwitchThread(threadID: threadID) },
            onCreate: { [weak self] in self?.threadManager.createAndSwitchThread() },
            onManage: { [weak self] in self?.presentThreadManagement() }
        )
        threadBarButtonItem.isEnabled = !isExecuting
        navigationItem.leftBarButtonItem = threadBarButtonItem
        navigationItem.prompt = modelSelection.currentStatusPrompt()
        modelBarButtonItem.image = UIImage(systemName: "theatermask.and.paintbrush")
        modelBarButtonItem.accessibilityLabel = modelSelection.currentModelMenuButtonTitle()
        modelBarButtonItem.menu = nil
        modelBarButtonItem.isEnabled = !isExecuting && modelSelection.hasConfiguredProviders
        usageBarButtonItem.isEnabled = true
        moreBarButtonItem.menu = ChatMenuBuilder.moreMenu(
            isExecuting: isExecuting,
            onFiles: { [weak self] in self?.presentProjectFiles() },
            onSettings: { [weak self] in self?.presentProjectSettings() },
            onClose: { [weak self] in self?.didTapClose() }
        )
        moreBarButtonItem.isEnabled = true
    }

    // MARK: - Layout

    private func configureLayout() {
        view.addSubview(tableView)
        view.addSubview(inputContainer)
        inputContainer.addSubview(inputTextView)
        inputTextView.addSubview(inputPlaceholderLabel)
        inputContainer.addSubview(sendButton)

        let inputBottomConstraint: NSLayoutConstraint
        if #available(iOS 15.0, *) {
            inputBottomConstraint = inputContainer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        } else {
            inputBottomConstraint = inputContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        }

        let inputHeightConstraint = inputTextView.heightAnchor.constraint(equalToConstant: inputMinHeight)
        self.inputHeightConstraint = inputHeightConstraint

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: inputContainer.topAnchor),

            inputContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBottomConstraint,

            inputTextView.topAnchor.constraint(equalTo: inputContainer.topAnchor, constant: 10),
            inputTextView.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: 12),
            inputTextView.bottomAnchor.constraint(equalTo: inputContainer.safeAreaLayoutGuide.bottomAnchor, constant: -10),
            inputHeightConstraint,

            inputPlaceholderLabel.topAnchor.constraint(equalTo: inputTextView.topAnchor, constant: 10),
            inputPlaceholderLabel.leadingAnchor.constraint(equalTo: inputTextView.leadingAnchor, constant: 8),
            inputPlaceholderLabel.trailingAnchor.constraint(lessThanOrEqualTo: inputTextView.trailingAnchor, constant: -8),

            sendButton.leadingAnchor.constraint(equalTo: inputTextView.trailingAnchor, constant: 10),
            sendButton.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor, constant: -12),
            sendButton.bottomAnchor.constraint(equalTo: inputTextView.bottomAnchor),
            sendButton.heightAnchor.constraint(equalToConstant: 38),
            sendButton.widthAnchor.constraint(equalToConstant: 38)
        ])
    }

    // MARK: - Project Setup

    private func ensureProjectMemoryDocumentIfNeeded() {
        let memoryURL = workspaceURL.appendingPathComponent("DOUFU.MD")
        guard !FileManager.default.fileExists(atPath: memoryURL.path) else {
            return
        }
        let fallback = """
        # DOUFU.MD

        ## Project Overview
        - Name: \(projectName)
        - Runtime: Static html/css/js in WKWebView
        - Directory layout: `App/` (code + git) | `AppData/` (user data)
        - All code lives in `App/`. This file is inside `App/`.

        ## Notes
        - Keep this file updated with architecture and important feature notes.
        - Keep AGENTS.md aligned with current UX constraints.
        """
        try? fallback.write(to: memoryURL, atomically: true, encoding: .utf8)
    }

    private func presentThreadManagement() {
        guard !taskCoordinator.isExecuting else { return }
        let vc = ThreadManagementViewController(projectID: project.id)
        vc.onChanged = { [weak self] in
            guard let self else { return }
            threadManager.reloadIndex()
            refreshNavigationItems()
        }
        let nav = UINavigationController(rootViewController: vc)
        present(nav, animated: true)
    }

    // MARK: - Input Handling

    private func currentInputText() -> String {
        inputTextView.text.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func refreshInputPlaceholder() {
        inputPlaceholderLabel.isHidden = !inputTextView.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    private func updateInputTextViewHeight() {
        guard let inputHeightConstraint else {
            return
        }

        let targetSize = CGSize(width: inputTextView.bounds.width, height: .greatestFiniteMagnitude)
        let fittingSize = inputTextView.sizeThatFits(targetSize)
        let clamped = min(inputMaxHeight, max(inputMinHeight, fittingSize.height))
        inputHeightConstraint.constant = clamped
        inputTextView.isScrollEnabled = fittingSize.height > inputMaxHeight
    }

    private func refreshSendButton() {
        let hasText = !currentInputText().isEmpty
        let hasThread = threadManager.currentThread != nil
        if taskCoordinator.isExecuting {
            sendButton.isEnabled = true
            var configuration = sendButton.configuration ?? UIButton.Configuration.filled()
            configuration.image = UIImage(systemName: "stop")
            configuration.baseBackgroundColor = .systemRed
            configuration.baseForegroundColor = .white
            configuration.cornerStyle = .capsule
            sendButton.configuration = configuration
            sendButton.accessibilityLabel = String(localized: "chat.action.cancel")
        } else {
            sendButton.isEnabled = hasText && modelSelection.canSend && hasThread
            var configuration = sendButton.configuration ?? UIButton.Configuration.filled()
            configuration.image = UIImage(systemName: "arrow.up")
            configuration.baseBackgroundColor = .systemBlue
            configuration.baseForegroundColor = .white
            configuration.cornerStyle = .capsule
            sendButton.configuration = configuration
            sendButton.accessibilityLabel = String(localized: "chat.action.send")
        }
        inputTextView.isEditable = !taskCoordinator.isExecuting
        inputTextView.alpha = taskCoordinator.isExecuting ? 0.72 : 1.0
        refreshNavigationItems()
    }

    // MARK: - Scroll

    private var isNearBottom: Bool {
        let offsetY = tableView.contentOffset.y
        let contentHeight = tableView.contentSize.height
        let frameHeight = tableView.bounds.height
        return contentHeight - offsetY - frameHeight < 150
    }

    func scrollToBottomIfNeeded(force: Bool = false) {
        guard !messageStore.messages.isEmpty else {
            return
        }
        guard force || isNearBottom else {
            return
        }
        let lastRow = messageStore.messages.count - 1
        let indexPath = IndexPath(row: lastRow, section: 0)
        tableView.scrollToRow(at: indexPath, at: .bottom, animated: !force)
    }

    // MARK: - Presentation

    @objc
    private func didTapModelSettings() {
        guard !taskCoordinator.isExecuting else {
            return
        }

        let availableProviderCredentials = modelSelection.resolveProviderCredentials()
        modelSelection.refreshWithResolvedCredentials(availableProviderCredentials)
        guard modelSelection.hasConfiguredProviders else {
            Task { [weak self] in
                await self?.reloadModelSelectionContext()
            }
            messageStore.appendMessage(role: .system, text: ChatProviderError.noAvailableProvider.localizedDescription)
            return
        }

        let selectionState = modelSelection.selectionSnapshot
        let controller = ModelConfigurationViewController(
            initialState: selectionState,
            showsResetToDefaults: modelSelection.hasThreadOverride,
            projectUsageIdentifier: projectIdentifier,
            inheritedState: modelSelection.inheritedSnapshot,
            inheritedStateProvider: { [weak self] in
                self?.modelSelection.inheritedSnapshot
            },
            inheritTitle: String(localized: "model_config.inherit.use_project_default")
        )
        controller.onSelectionStateChanged = { [weak self] state in
            self?.modelSelection.applySelectionState(state) ?? SelectionApplyOutcome(hasExplicitSelection: false)
        }
        controller.onResetToDefaults = { [weak self] in
            guard let self else { return selectionState }
            self.modelSelection.resetToDefaults()
            return self.modelSelection.selectionSnapshot
        }

        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .pageSheet
        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigationController, animated: true)
    }

    @objc
    private func didTapProjectUsage() {
        let controller = ProjectTokenUsageViewController(
            projectUsageIdentifier: projectIdentifier
        )
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .pageSheet
        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigationController, animated: true)
    }

    private func presentProjectFiles() {
        let controller = ProjectFileBrowserViewController(
            projectName: projectName,
            rootURL: workspaceURL,
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

    private func presentProjectSettings() {
        let settingsController = ProjectSettingsViewController(
            projectURL: project.projectURL,
            projectName: projectName
        )
        settingsController.onProjectUpdated = { [weak self] updatedProjectName in
            guard let self else { return }
            let updatedProject = AppProjectRecord(
                id: self.session.project.id,
                name: updatedProjectName,
                projectURL: self.session.project.projectURL,
                createdAt: self.session.project.createdAt,
                updatedAt: Date()
            )
            self.session.updateProject(updatedProject)
            self.session.onProjectFilesUpdated?()
        }
        settingsController.onToolPermissionModeChanged = { [weak self] mode in
            self?.toolPermissionMode = mode
        }
        let navigationController = UINavigationController(rootViewController: settingsController)
        navigationController.modalPresentationStyle = .pageSheet
        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigationController, animated: true)
    }

    private func presentChatStorageError(_ error: Error) {
        guard !(presentedViewController is UIAlertController) else {
            return
        }
        let alert = UIAlertController(
            title: String(
                localized: "chat.storage.alert.title",
                defaultValue: "Chat Storage Error"
            ),
            message: error.localizedDescription,
            preferredStyle: .alert
        )
        alert.addAction(UIAlertAction(title: String(localized: "common.action.ok"), style: .default))
        present(alert, animated: true)
    }

    @objc
    private func didTapClose() {
        dismiss(animated: true)
    }

    // MARK: - Send / Cancel

    @objc
    private func didTapSend() {
        if taskCoordinator.isExecuting {
            taskCoordinator.cancel()
            return
        }

        let userInput = currentInputText()
        guard !userInput.isEmpty else {
            return
        }
        guard threadManager.currentThread != nil else {
            messageStore.appendMessage(role: .system, text: ChatProviderError.noThreadAvailable.localizedDescription)
            return
        }
        guard modelSelection.canSend else {
            if let blockedMessage = modelSelection.sendBlockedMessage() {
                messageStore.appendMessage(role: .system, text: blockedMessage)
            }
            return
        }

        inputTextView.text = ""
        refreshInputPlaceholder()
        updateInputTextViewHeight()
        messageStore.appendMessage(role: .user, text: userInput)
        inputTextView.resignFirstResponder()

        session.sendMessage(
            userInput,
            toolPermissionMode: toolPermissionMode,
            validationServerBaseURL: validationServerBaseURL,
            validationBridge: validationBridge
        )
        refreshSendButton()
    }

}

// MARK: - ChatMessageStoreDelegate

extension ChatViewController: ChatMessageStoreDelegate {
    func messageStoreDidInsertRow(at index: Int) {
        UIView.performWithoutAnimation {
            tableView.insertRows(at: [IndexPath(row: index, section: 0)], with: .none)
        }
    }

    func messageStoreDidUpdateCell(at index: Int, message: ChatMessage) {
        let ip = IndexPath(row: index, section: 0)
        if let cell = tableView.cellForRow(at: ip) as? ChatMessageCell {
            cell.configure(message: message, now: Date())
        }
    }

    func messageStoreDidUpdateStreamingText(at index: Int, text: String) {
        let ip = IndexPath(row: index, section: 0)
        if let cell = tableView.cellForRow(at: ip) as? ChatMessageCell {
            cell.updateText(text)
        }
    }

    func messageStoreDidRequestBatchUpdate() {
        tableView.performBatchUpdates(nil)
    }

    func messageStoreDidRequestScroll(force: Bool) {
        scrollToBottomIfNeeded(force: force)
    }
}

// MARK: - ChatSessionDelegate

extension ChatViewController: ChatSessionDelegate {
    func sessionDidFinishExecution() {
        refreshSendButton()
    }

    func sessionDidSwitchThread() {
        tableView.reloadData()
        scrollToBottomIfNeeded(force: true)
        refreshNavigationItems()
        refreshSendButton()
    }

    func sessionModelSelectionDidChange() {
        refreshNavigationItems()
        refreshSendButton()
    }

    func sessionDidEncounterError(_ error: Error) {
        presentChatStorageError(error)
    }
}

// MARK: - UITableViewDataSource

extension ChatViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        messageStore.messages.count
    }

    func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard
            let cell = tableView.dequeueReusableCell(
                withIdentifier: ChatMessageCell.reuseIdentifier,
                for: indexPath
            ) as? ChatMessageCell
        else {
            return UITableViewCell()
        }

        let message = messageStore.messages[indexPath.row]
        cell.configure(message: message, now: Date())

        if message.isProgress {
            let progressText = message.text
            cell.onExpandTapped = { [weak self] in
                guard let self else { return }
                let detailVC = MessageDetailViewController(text: progressText)
                let nav = UINavigationController(rootViewController: detailVC)
                nav.modalPresentationStyle = .pageSheet
                if let sheet = nav.sheetPresentationController {
                    sheet.detents = [.large()]
                }
                self.present(nav, animated: true)
            }
        }

        cell.onNeedsHeightUpdate = { [weak self] in
            self?.tableView.performBatchUpdates(nil)
        }

        return cell
    }
}

// MARK: - UITextViewDelegate

extension ChatViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        refreshInputPlaceholder()
        updateInputTextViewHeight()
        refreshSendButton()
    }
}

// MARK: - ToolConfirmationHandler

extension ChatViewController: ToolConfirmationHandler {
    func confirmToolAction(
        toolName: String,
        tier: ToolPermissionTier,
        description: String
    ) async -> Bool {
        PiPProgressManager.shared.setNeedsUserAction()
        return await withCheckedContinuation { continuation in
            let title: String
            let allowStyle: UIAlertAction.Style
            switch tier {
            case .autoAllow:
                continuation.resume(returning: true)
                return
            case .confirmOnce:
                title = String(localized: "tool.confirm.title")
                allowStyle = .default
            case .alwaysConfirm:
                title = String(localized: "tool.confirm.title.destructive")
                allowStyle = .destructive
            }

            // If the VC is no longer in the window hierarchy, presenting
            // will silently fail and the continuation will never resume.
            // Reject the action to avoid a permanent hang.
            guard self.view.window != nil else {
                continuation.resume(returning: false)
                return
            }

            let alert = UIAlertController(
                title: title,
                message: description,
                preferredStyle: .alert
            )
            alert.addAction(UIAlertAction(
                title: String(localized: "tool.confirm.allow"),
                style: allowStyle
            ) { _ in
                continuation.resume(returning: true)
            })
            alert.addAction(UIAlertAction(
                title: String(localized: "tool.confirm.deny"),
                style: .cancel
            ) { _ in
                continuation.resume(returning: false)
            })
            self.present(alert, animated: true)
        }
    }
}
