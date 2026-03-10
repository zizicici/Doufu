//
//  ChatViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import UIKit

@MainActor
final class ChatViewController: UIViewController {

    var onProjectFilesUpdated: (() -> Void)?
    var isReadOnly = false

    private var project: AppProjectRecord
    private lazy var dataService: ChatDataService = {
        ChatDataService(projectID: project.id)
    }()

    private lazy var taskCoordinator: ChatTaskCoordinator = {
        let coordinator = ChatTaskCoordinator()
        coordinator.delegate = self
        return coordinator
    }()
    private var toolPermissionMode: ToolPermissionMode = .standard

    /// Server base URL for code validation (uses localhost instead of file://).
    var validationServerBaseURL: URL?
    /// A temporary bridge whose storage is isolated from real user data.
    var validationBridge: DoufuBridge?

    private let inputMinHeight: CGFloat = 38
    private let inputMaxHeight: CGFloat = 120
    private var inputHeightConstraint: NSLayoutConstraint?

    // MARK: - Extracted Modules

    private lazy var messageStore: ChatMessageStore = {
        let store = ChatMessageStore()
        store.mutationDelegate = self
        return store
    }()

    private lazy var modelSelection: ChatModelSelectionManager = {
        let manager = ChatModelSelectionManager(
            projectID: project.id,
            currentThreadIDProvider: { [weak self] in self?.threadSession.currentThread?.id }
        )
        manager.dataService = dataService
        return manager
    }()

    private lazy var threadSession: ChatThreadSessionManager = {
        let manager = ChatThreadSessionManager(
            dataService: dataService,
            messageStore: messageStore,
            modelSelection: modelSelection,
            isExecutingProvider: { [weak self] in self?.taskCoordinator.isExecuting ?? false }
        )
        manager.delegate = self
        return manager
    }()

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

    private var projectIdentifier: String { project.id }
    private var projectName: String { project.name }
    private var projectURL: URL { project.projectURL }

    init(project: AppProjectRecord) {
        self.project = project
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

        messageStore.delegate = self
        modelSelection.delegate = self

        configureNavigation()
        configureLayout()
        ensureProjectMemoryDocumentIfNeeded()
        toolPermissionMode = AppProjectStore.shared.loadToolPermissionMode(projectURL: projectURL)
        if isReadOnly {
            inputContainer.isHidden = true
        }
        refreshInputPlaceholder()
        refreshSendButton()

        Task {
            await modelSelection.loadProjectModelSelection()
            modelSelection.configureProvider()
            do {
                try await threadSession.restoreThreadStateIfNeeded()
            } catch {
                messageStore.appendMessage(role: .system, text: error.localizedDescription)
            }
            refreshSendButton()
        }
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateInputTextViewHeight()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if view.window == nil {
            modelSelection.cancelRefreshTask()
        }
    }

    // MARK: - Navigation

    private func configureNavigation() {
        navigationItem.rightBarButtonItems = [moreBarButtonItem, modelBarButtonItem, usageBarButtonItem]
        refreshNavigationItems()
    }

    func refreshNavigationItems() {
        let isExecuting = taskCoordinator.isExecuting
        threadBarButtonItem.title = threadSession.currentThread?.title ?? String(localized: "chat.thread.button_title")
        threadBarButtonItem.menu = isExecuting ? nil : ChatMenuBuilder.threadMenu(
            threads: threadSession.threadIndex?.threads ?? [],
            currentThreadID: threadSession.currentThread?.id,
            onSwitch: { [weak self] threadID in self?.threadSession.handleSwitchThread(threadID: threadID) },
            onCreate: { [weak self] in self?.threadSession.createAndSwitchThread() },
            onManage: { [weak self] in self?.presentThreadManagement() }
        )
        threadBarButtonItem.isEnabled = !isExecuting
        navigationItem.leftBarButtonItem = threadBarButtonItem
        modelBarButtonItem.image = UIImage(systemName: "theatermask.and.paintbrush")
        modelBarButtonItem.accessibilityLabel = modelSelection.currentModelMenuButtonTitle()
        modelBarButtonItem.menu = nil
        modelBarButtonItem.isEnabled = !isExecuting && modelSelection.providerCredential != nil
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
        let memoryURL = projectURL.appendingPathComponent("DOUFU.MD")
        guard !FileManager.default.fileExists(atPath: memoryURL.path) else {
            return
        }
        let fallback = """
        # DOUFU.MD

        ## Project Overview
        - Name: \(projectName)
        - Runtime: Static html/css/js in WKWebView

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
            threadSession.reloadIndex()
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
        let hasProvider = modelSelection.providerCredential != nil
        let hasThread = threadSession.currentThread != nil
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
            sendButton.isEnabled = hasText && hasProvider && hasThread
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

        do {
            modelSelection.availableProviderCredentials = try modelSelection.resolveProviderCredentials()
        } catch {
            modelSelection.providerCredential = nil
            modelSelection.selectedProviderID = nil
            messageStore.appendMessage(role: .system, text: error.localizedDescription)
            refreshNavigationItems()
            return
        }

        guard let fallbackProvider = modelSelection.availableProviderCredentials.first else {
            messageStore.appendMessage(role: .system, text: ChatProviderError.noAvailableProvider.localizedDescription)
            return
        }

        let selectedProvider = modelSelection.providerCredential ?? fallbackProvider
        modelSelection.providerCredential = selectedProvider
        modelSelection.selectedProviderID = selectedProvider.providerID
        if let currentModel = modelSelection.selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines),
           !currentModel.isEmpty {
            modelSelection.selectedModelIDByProviderID[selectedProvider.providerID] = currentModel
        } else {
            let resolvedModel = modelSelection.resolvedModelID(for: selectedProvider)
            if resolvedModel.isEmpty {
                modelSelection.selectedModelIDByProviderID.removeValue(forKey: selectedProvider.providerID)
            } else {
                modelSelection.selectedModelIDByProviderID[selectedProvider.providerID] = resolvedModel
            }
        }

        let selectionState = modelSelection.selectionSnapshot
        let controller = ModelConfigurationViewController(
            providers: modelSelection.availableProviderCredentials,
            initialState: selectionState,
            projectUsageIdentifier: projectIdentifier
        )
        controller.onSelectionStateChanged = { [weak self] state in
            self?.modelSelection.applySelectionState(state)
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
        let controller = ProjectFileBrowserViewController(projectName: projectName, rootURL: projectURL)
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
            projectURL: projectURL,
            projectName: projectName
        )
        settingsController.onProjectUpdated = { [weak self] updatedProjectName in
            guard let self else { return }
            self.project = AppProjectRecord(
                id: self.project.id,
                name: updatedProjectName,
                projectURL: self.project.projectURL,
                entryFileURL: self.project.entryFileURL,
                createdAt: self.project.createdAt,
                updatedAt: Date()
            )
            self.onProjectFilesUpdated?()
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
        guard let baseProviderCredential = modelSelection.providerCredential else {
            messageStore.appendMessage(role: .system, text: ChatProviderError.noAvailableProvider.localizedDescription)
            return
        }
        guard threadSession.currentThread != nil else {
            messageStore.appendMessage(role: .system, text: ChatProviderError.noThreadAvailable.localizedDescription)
            return
        }
        guard modelSelection.ensureModelSelectionForSend(providerCredential: baseProviderCredential) else {
            return
        }
        let credential = modelSelection.runtimeCredential(from: baseProviderCredential)

        inputTextView.text = ""
        refreshInputPlaceholder()
        updateInputTextViewHeight()
        messageStore.appendMessage(role: .user, text: userInput)
        inputTextView.resignFirstResponder()

        let historyTurns = messageStore.buildHistoryTurns()
        messageStore.beginRequest(startedAt: Date())

        let sessionContext = ChatSessionContext(
            projectID: projectIdentifier,
            projectURL: projectURL,
            projectName: projectName
        )
        let request = ChatTaskCoordinator.Request(
            userMessage: userInput,
            history: historyTurns,
            sessionContext: sessionContext,
            credential: credential,
            memory: threadSession.sessionMemory,
            executionOptions: modelSelection.executionOptions(for: credential),
            confirmationHandler: self,
            permissionMode: toolPermissionMode,
            validationServerBaseURL: validationServerBaseURL,
            validationBridge: validationBridge
        )
        taskCoordinator.execute(request)
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

// MARK: - ChatMessageStoreMutationDelegate

extension ChatViewController: ChatMessageStoreMutationDelegate {
    func messageStoreDidMutateMessages() {
        guard let threadID = threadSession.currentThread?.id else { return }
        dataService.persistMessages(messageStore.messages, threadID: threadID)
    }
}

// MARK: - ChatModelSelectionManagerDelegate

extension ChatViewController: ChatModelSelectionManagerDelegate {
    func modelSelectionDidChange() {
        refreshNavigationItems()
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
            cell.onExpandTapped = { [weak self] in
                guard let self else { return }
                let fullText = self.messageStore.messages[indexPath.row].text
                let detailVC = MessageDetailViewController(text: fullText)
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

// MARK: - ChatThreadSessionManagerDelegate

extension ChatViewController: ChatThreadSessionManagerDelegate {
    func threadSessionDidSwitchThread() {
        tableView.reloadData()
        scrollToBottomIfNeeded(force: true)
        refreshNavigationItems()
    }

    func threadSessionDidEncounterError(_ error: Error) {
        messageStore.appendMessage(role: .system, text: error.localizedDescription)
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

// MARK: - ChatTaskCoordinatorDelegate

extension ChatViewController: ChatTaskCoordinatorDelegate {
    func coordinatorDidReceiveStreamedText(_ chunk: String) {
        messageStore.receiveStreamedText(chunk)
    }

    func coordinatorDidReceiveProgressEvent(_ event: ToolProgressEvent) {
        messageStore.receiveProgressEvent(event)
    }

    func coordinatorDidCompleteWithResult(_ result: ChatTaskResult) {
        guard threadSession.currentThread != nil else { return }

        threadSession.updateSessionMemory(result.updatedMemory)

        var assistantText = result.assistantMessage
        if !result.changedPaths.isEmpty {
            let changesSummary = result.changedPaths.joined(separator: ", ")
            assistantText += String(
                format: String(localized: "chat.system.files_updated.append_format"),
                changesSummary
            )
        }

        messageStore.completeWithResult(
            text: assistantText,
            requestTokenUsage: result.requestTokenUsage,
            toolSummary: result.toolActivitySummary
        )

        threadSession.touchCurrentThread()

        if !result.changedPaths.isEmpty {
            onProjectFilesUpdated?()
        }
    }

    func coordinatorDidCancel() {
        messageStore.handleCancellation()
    }

    func coordinatorDidFailWithError(_ error: Error) {
        messageStore.handleError(error)
    }

    func coordinatorDidFinishExecution() {
        messageStore.finishExecution()
        refreshSendButton()
    }
}
