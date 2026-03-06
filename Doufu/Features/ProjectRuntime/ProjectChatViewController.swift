//
//  ProjectChatViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import UIKit

@MainActor
final class ProjectChatViewController: UIViewController {

    var onProjectFilesUpdated: (() -> Void)?

    private enum LocalError: LocalizedError {
        case noAvailableProvider
        case noThreadAvailable

        var errorDescription: String? {
            switch self {
            case .noAvailableProvider:
                return String(localized: "chat.error.no_provider")
            case .noThreadAvailable:
                return String(localized: "chat.error.no_thread")
            }
        }
    }

    fileprivate struct Message: Hashable {
        enum Role: String, Hashable {
            case user
            case assistant
            case system
        }

        let id = UUID()
        let role: Role
        var text: String
        let createdAt: Date
        let startedAt: Date
        var finishedAt: Date?
        let isProgress: Bool
    }

    private let projectName: String
    private let projectURL: URL
    private let chatService = ProjectChatService()
    private let providerStore = LLMProviderSettingsStore.shared
    private let threadStore = ProjectChatThreadStore.shared

    private var messages: [Message] = []
    private var providerCredential: ProjectChatService.ProviderCredential?
    private var sessionMemory: ProjectChatService.SessionMemory?
    private var threadSessionMemories: [String: ProjectChatService.SessionMemory] = [:]
    private var isSending = false
    private var sendTask: Task<Void, Never>?
    private var didCancelCurrentRequest = false
    private var didAppendCancelMessage = false
    private var lastProgressPhaseText: String?
    private var activeProgressMessageID: UUID?
    private var currentRequestStartedAt: Date?
    private var progressUIUpdateTimer: Timer?
    private var threadIndex: ProjectChatThreadIndex?
    private var currentThread: ProjectChatThreadRecord?
    private var selectedModelID: String?
    private var selectedReasoningEffortsByModelID: [String: ProjectChatService.ReasoningEffort] = [:]
    private let inputMinHeight: CGFloat = 38
    private let inputMaxHeight: CGFloat = 120
    private var inputHeightConstraint: NSLayoutConstraint?

    private lazy var closeBarButtonItem = UIBarButtonItem(
        barButtonSystemItem: .close,
        target: self,
        action: #selector(didTapClose)
    )

    private lazy var modelBarButtonItem = UIBarButtonItem(
        title: "Model",
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
        let tableView = UITableView(frame: .zero, style: .insetGrouped)
        tableView.translatesAutoresizingMaskIntoConstraints = false
        tableView.dataSource = self
        tableView.separatorStyle = .none
        tableView.keyboardDismissMode = .interactive
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
        configuration.image = UIImage(systemName: "paperplane.fill")
        configuration.cornerStyle = .capsule
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(didTapSend), for: .touchUpInside)
        button.accessibilityLabel = String(localized: "chat.action.send")
        return button
    }()

    init(projectName: String, projectURL: URL) {
        self.projectName = projectName
        self.projectURL = projectURL
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        title = nil
        view.backgroundColor = .systemGroupedBackground
        configureNavigation()
        configureLayout()
        ensureProjectMemoryDocumentIfNeeded()
        restoreThreadStateIfNeeded()
        configureProvider()
        refreshInputPlaceholder()
        refreshSendButton()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        updateInputTextViewHeight()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        if isSending {
            startProgressUIUpdateTimerIfNeeded()
        }
        refreshVisibleMessageCellsForDynamicState()
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if view.window == nil {
            stopProgressUIUpdateTimer()
        }
        persistCurrentThreadMessages()
    }

    private func configureNavigation() {
        navigationItem.rightBarButtonItems = [closeBarButtonItem, modelBarButtonItem]
        refreshNavigationItems()
    }

    private func refreshNavigationItems() {
        threadBarButtonItem.title = currentThread?.title ?? String(localized: "chat.thread.button_title")
        threadBarButtonItem.menu = isSending ? nil : buildThreadMenu()
        threadBarButtonItem.isEnabled = !isSending
        navigationItem.leftBarButtonItem = threadBarButtonItem
        modelBarButtonItem.title = currentModelMenuButtonTitle()
        modelBarButtonItem.menu = isSending ? nil : buildModelMenu()
        modelBarButtonItem.isEnabled = !isSending && providerCredential != nil
    }

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

    private func restoreThreadStateIfNeeded() {
        do {
            threadIndex = try threadStore.loadOrCreateIndex(projectURL: projectURL)
            if let currentThreadID = threadIndex?.currentThreadID {
                try switchToThread(threadID: currentThreadID, appendStatusMessage: false)
            }
        } catch {
            appendMessage(role: .system, text: error.localizedDescription)
        }
    }

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

    private func configureProvider() {
        do {
            let credential = try resolveProviderCredential()
            providerCredential = credential
            let normalizedSelectedModel = selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if normalizedSelectedModel.isEmpty {
                selectedModelID = credential.modelID
            }
            appendProviderStatusIfNeeded()
            refreshNavigationItems()
        } catch {
            providerCredential = nil
            appendMessage(role: .system, text: error.localizedDescription)
            refreshNavigationItems()
        }
    }

    private func appendProviderStatusIfNeeded() {
        guard let credential = providerCredential else {
            return
        }
        guard messages.isEmpty else {
            return
        }
        _ = appendMessage(
            role: .system,
            text: String(
                format: String(localized: "chat.system.provider_connected.message_format"),
                credential.providerLabel
            )
        )
        persistCurrentThreadMessages()
    }

    private func resolveProviderCredential() throws -> ProjectChatService.ProviderCredential {
        let providers = providerStore.loadProviders()
        for provider in providers {
            guard let baseURL = URL(string: provider.effectiveBaseURLString) else {
                continue
            }
            let token = try providerStore.loadBearerToken(for: provider)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard !token.isEmpty else {
                continue
            }

            let chatGPTAccountID = provider.chatGPTAccountID ?? extractChatGPTAccountID(fromJWT: token)

            return ProjectChatService.ProviderCredential(
                providerID: provider.id,
                providerLabel: provider.label,
                providerKind: provider.kind,
                authMode: provider.authMode,
                modelID: provider.effectiveModelID,
                baseURL: baseURL,
                bearerToken: token,
                chatGPTAccountID: chatGPTAccountID
            )
        }

        throw LocalError.noAvailableProvider
    }

    private func buildThreadMenu() -> UIMenu {
        let threadActions: [UIAction]
        if let index = threadIndex, !index.threads.isEmpty {
            threadActions = index.threads
                .sorted { lhs, rhs in
                    if lhs.updatedAt == rhs.updatedAt {
                        return lhs.createdAt > rhs.createdAt
                    }
                    return lhs.updatedAt > rhs.updatedAt
                }
                .map { thread in
                    UIAction(
                        title: thread.title,
                        state: thread.id == currentThread?.id ? .on : .off
                    ) { [weak self] _ in
                        self?.handleSwitchThread(threadID: thread.id)
                    }
                }
        } else {
            threadActions = [
                UIAction(title: String(localized: "chat.menu.no_thread"), attributes: .disabled) { _ in }
            ]
        }

        let createAction = UIAction(
            title: String(localized: "chat.menu.new_thread"),
            image: UIImage(systemName: "plus")
        ) { [weak self] _ in
            self?.createAndSwitchThread()
        }
        return UIMenu(title: String(localized: "chat.thread.button_title"), children: threadActions + [createAction])
    }

    private func currentModelMenuTitle() -> String {
        let selected = selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !selected.isEmpty {
            return selected
        }
        let fallback = providerCredential?.modelID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fallback.isEmpty ? String(localized: "chat.menu.model") : fallback
    }

    private func currentModelMenuButtonTitle() -> String {
        let modelTitle = currentModelMenuTitle()
        guard let providerKind = currentProviderKind() else {
            return modelTitle
        }
        let effort = resolvedReasoningEffort(forModelID: modelTitle, providerKind: providerKind)
        return modelTitle + " · " + effort.displayName
    }

    private func currentProviderKind() -> LLMProviderRecord.Kind? {
        guard let credential = providerCredential else {
            return nil
        }
        return providerStore.loadProvider(id: credential.providerID)?.kind ?? credential.providerKind
    }

    private func normalizedModelID(_ modelID: String) -> String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func reasoningProfile(
        forModelID modelID: String,
        providerKind: LLMProviderRecord.Kind
    ) -> (supported: [ProjectChatService.ReasoningEffort], defaultEffort: ProjectChatService.ReasoningEffort) {
        let normalizedModel = normalizedModelID(modelID)
        switch providerKind {
        case .openAICompatible:
            if normalizedModel.contains("mini") {
                return ([.low, .medium, .high], .medium)
            }
            if normalizedModel.contains("pro") || normalizedModel.contains("codex") {
                return ([.medium, .high, .xhigh], .high)
            }
            return ([.low, .medium, .high, .xhigh], .high)
        case .anthropic:
            if normalizedModel.contains("haiku") {
                return ([.low, .medium], .medium)
            }
            if normalizedModel.contains("opus") {
                return ([.medium, .high], .high)
            }
            return ([.medium, .high], .high)
        case .googleGemini:
            if normalizedModel.contains("flash") {
                return ([.low, .medium], .medium)
            }
            return ([.medium, .high], .high)
        }
    }

    private func resolvedReasoningEffort(
        forModelID modelID: String,
        providerKind: LLMProviderRecord.Kind
    ) -> ProjectChatService.ReasoningEffort {
        let profile = reasoningProfile(forModelID: modelID, providerKind: providerKind)
        let key = normalizedModelID(modelID)
        if let selected = selectedReasoningEffortsByModelID[key], profile.supported.contains(selected) {
            return selected
        }
        selectedReasoningEffortsByModelID[key] = profile.defaultEffort
        return profile.defaultEffort
    }

    private func buildModelMenu() -> UIMenu {
        guard let credential = providerCredential else {
            let unavailable = UIAction(title: String(localized: "chat.error.no_provider"), attributes: .disabled) { _ in }
            return UIMenu(title: String(localized: "chat.menu.model"), children: [unavailable])
        }

        let providerKind = providerStore.loadProvider(id: credential.providerID)?.kind ?? credential.providerKind
        var modelIDs = providerKind.builtInModels
        let fallbackModel = credential.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fallbackModel.isEmpty && !modelIDs.contains(where: { $0.caseInsensitiveCompare(fallbackModel) == .orderedSame }) {
            modelIDs.insert(fallbackModel, at: 0)
        }

        let selectedModel = currentModelMenuTitle()
        if !selectedModel.isEmpty, !modelIDs.contains(where: { $0.caseInsensitiveCompare(selectedModel) == .orderedSame }) {
            modelIDs.insert(selectedModel, at: 0)
        }

        let actions = modelIDs.map { modelID in
            UIAction(
                title: modelID,
                state: modelID.caseInsensitiveCompare(selectedModel) == .orderedSame ? .on : .off
            ) { [weak self] _ in
                self?.selectedModelID = modelID
                let normalizedModel = self?.normalizedModelID(modelID) ?? modelID.lowercased()
                if let self {
                    let profile = self.reasoningProfile(forModelID: modelID, providerKind: providerKind)
                    if let selected = self.selectedReasoningEffortsByModelID[normalizedModel], profile.supported.contains(selected) {
                        self.selectedReasoningEffortsByModelID[normalizedModel] = selected
                    } else {
                        self.selectedReasoningEffortsByModelID[normalizedModel] = profile.defaultEffort
                    }
                }
                self?.refreshNavigationItems()
            }
        }
        let selectedReasoning = resolvedReasoningEffort(forModelID: selectedModel, providerKind: providerKind)
        let profile = reasoningProfile(forModelID: selectedModel, providerKind: providerKind)
        let reasoningActions = profile.supported.map { effort in
            UIAction(
                title: effort.displayName,
                state: effort == selectedReasoning ? .on : .off
            ) { [weak self] _ in
                guard let self else {
                    return
                }
                let key = self.normalizedModelID(selectedModel)
                self.selectedReasoningEffortsByModelID[key] = effort
                self.refreshNavigationItems()
            }
        }

        let modelSection = UIMenu(
            title: String(localized: "chat.menu.model"),
            options: .displayInline,
            children: actions
        )
        let reasoningSection = UIMenu(
            title: String(format: String(localized: "chat.menu.reasoning_for_model_format"), selectedModel),
            options: .displayInline,
            children: reasoningActions
        )
        return UIMenu(
            title: String(localized: "chat.menu.model"),
            children: [modelSection, reasoningSection]
        )
    }

    private func handleSwitchThread(threadID: String) {
        guard !isSending else {
            return
        }
        do {
            try switchToThread(threadID: threadID, appendStatusMessage: true)
        } catch {
            appendMessage(role: .system, text: error.localizedDescription)
        }
    }

    private func createAndSwitchThread() {
        guard !isSending else {
            return
        }
        do {
            persistCurrentThreadMessages()
            _ = try threadStore.createThread(projectURL: projectURL, title: nil, makeCurrent: true)
            threadIndex = try threadStore.loadOrCreateIndex(projectURL: projectURL)
            guard let currentThreadID = threadIndex?.currentThreadID else {
                throw LocalError.noThreadAvailable
            }
            try switchToThread(threadID: currentThreadID, appendStatusMessage: false)
            _ = appendMessage(role: .system, text: String(localized: "chat.system.thread_created"))
            persistCurrentThreadMessages()
            refreshNavigationItems()
        } catch {
            appendMessage(role: .system, text: error.localizedDescription)
        }
    }

    private func switchToThread(threadID: String, appendStatusMessage: Bool) throws {
        persistCurrentThreadMessages()
        if let currentThread {
            threadSessionMemories[currentThread.id] = sessionMemory
        }

        let switched = try threadStore.switchCurrentThread(projectURL: projectURL, threadID: threadID)
        threadIndex = try threadStore.loadOrCreateIndex(projectURL: projectURL)
        currentThread = switched
        sessionMemory = threadSessionMemories[switched.id] ?? nil

        let persisted = threadStore.loadMessages(projectURL: projectURL, threadID: switched.id)
        messages = persisted.compactMap { persistedMessage in
            let normalizedRole = persistedMessage.role.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard let role = Message.Role(rawValue: normalizedRole) else {
                return nil
            }
            let text = persistedMessage.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }
            let startedAt = persistedMessage.startedAt ?? persistedMessage.createdAt
            let finishedAt: Date? = {
                if let finishedAt = persistedMessage.finishedAt {
                    return finishedAt
                }
                if persistedMessage.isProgress {
                    return startedAt
                }
                return persistedMessage.createdAt
            }()
            return Message(
                role: role,
                text: text,
                createdAt: persistedMessage.createdAt,
                startedAt: startedAt,
                finishedAt: finishedAt,
                isProgress: persistedMessage.isProgress
            )
        }

        if appendStatusMessage {
            _ = appendMessage(
                role: .system,
                text: String(format: String(localized: "chat.system.thread_switched.message_format"), switched.title)
            )
        }
        appendProviderStatusIfNeeded()

        tableView.reloadData()
        scrollToBottomIfNeeded()
        refreshNavigationItems()
    }

    private func buildThreadContext() -> ProjectChatService.ThreadContext? {
        guard let currentThread else {
            return nil
        }
        let memoryFilePath = threadStore.currentMemoryFilePath(for: currentThread)
        let memoryContent = threadStore.loadThreadMemory(projectURL: projectURL, thread: currentThread)
        return ProjectChatService.ThreadContext(
            threadID: currentThread.id,
            version: currentThread.currentVersion,
            memoryFilePath: memoryFilePath,
            memoryContent: memoryContent
        )
    }

    private func persistCurrentThreadMessages() {
        guard let threadID = currentThread?.id else {
            return
        }
        let persisted = messages.compactMap { message -> ProjectChatPersistedMessage? in
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else {
                return nil
            }
            return ProjectChatPersistedMessage(
                role: message.role.rawValue,
                text: text,
                createdAt: message.createdAt,
                startedAt: message.startedAt,
                finishedAt: message.finishedAt,
                isProgress: message.isProgress
            )
        }
        threadStore.saveMessages(projectURL: projectURL, threadID: threadID, messages: persisted)
    }

    private func extractChatGPTAccountID(fromJWT token: String) -> String? {
        let parts = token.split(separator: ".")
        guard parts.count >= 2 else {
            return nil
        }
        guard let payloadData = decodeBase64URL(String(parts[1])) else {
            return nil
        }
        guard let payloadObject = (try? JSONSerialization.jsonObject(with: payloadData)) as? [String: Any] else {
            return nil
        }

        if
            let authClaims = payloadObject["https://api.openai.com/auth"] as? [String: Any],
            let accountID = normalizedString(from: authClaims["chatgpt_account_id"] ?? authClaims["account_id"])
        {
            return accountID
        }

        return normalizedString(from: payloadObject["chatgpt_account_id"] ?? payloadObject["account_id"])
    }

    private func decodeBase64URL(_ value: String) -> Data? {
        var base64 = value
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        let paddingLength = (4 - (base64.count % 4)) % 4
        if paddingLength > 0 {
            base64.append(String(repeating: "=", count: paddingLength))
        }
        return Data(base64Encoded: base64)
    }

    private func normalizedString(from value: Any?) -> String? {
        guard let rawValue = value as? String else {
            return nil
        }
        let normalized = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? nil : normalized
    }

    @discardableResult
    private func appendMessage(
        role: Message.Role,
        text: String,
        isProgress: Bool = false,
        startedAt: Date? = nil,
        finishedAt: Date? = nil
    ) -> Int? {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            return nil
        }

        let createdAt = Date()
        let startedAt = startedAt ?? createdAt
        let resolvedFinishedAt = finishedAt ?? (isProgress ? nil : createdAt)

        messages.append(
            Message(
                role: role,
                text: normalizedText,
                createdAt: createdAt,
                startedAt: startedAt,
                finishedAt: resolvedFinishedAt,
                isProgress: isProgress
            )
        )
        tableView.reloadData()
        scrollToBottomIfNeeded()
        refreshVisibleMessageCellsForDynamicState()
        return messages.count - 1
    }

    private func finalizeActiveProgressMessage(finishedAt: Date = Date()) {
        guard let activeProgressMessageID else {
            return
        }
        guard let index = messages.firstIndex(where: { $0.id == activeProgressMessageID }) else {
            self.activeProgressMessageID = nil
            return
        }
        if messages[index].finishedAt == nil {
            messages[index].finishedAt = finishedAt
            refreshVisibleMessageCellsForDynamicState()
        }
        self.activeProgressMessageID = nil
    }

    private func startProgressUIUpdateTimerIfNeeded() {
        guard progressUIUpdateTimer == nil else {
            return
        }
        let timer = Timer(timeInterval: 0.4, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshVisibleMessageCellsForDynamicState()
            }
        }
        progressUIUpdateTimer = timer
        RunLoop.main.add(timer, forMode: .common)
    }

    private func stopProgressUIUpdateTimer() {
        progressUIUpdateTimer?.invalidate()
        progressUIUpdateTimer = nil
    }

    private func refreshVisibleMessageCellsForDynamicState() {
        let now = Date()
        let visibleRows = tableView.indexPathsForVisibleRows ?? []
        for indexPath in visibleRows {
            guard messages.indices.contains(indexPath.row) else {
                continue
            }
            guard let cell = tableView.cellForRow(at: indexPath) as? ChatMessageCell else {
                continue
            }
            cell.configure(message: messages[indexPath.row], now: now)
        }
    }

    private func scrollToBottomIfNeeded() {
        guard !messages.isEmpty else {
            return
        }
        let lastRow = messages.count - 1
        let indexPath = IndexPath(row: lastRow, section: 0)
        tableView.scrollToRow(at: indexPath, at: .bottom, animated: true)
    }

    private func buildHistoryTurns() -> [ProjectChatService.ChatTurn] {
        messages.compactMap { message in
            let normalizedText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedText.isEmpty else {
                return nil
            }
            switch message.role {
            case .user:
                return .init(role: .user, text: normalizedText)
            case .assistant:
                if message.isProgress {
                    return nil
                }
                return .init(role: .assistant, text: normalizedText)
            case .system:
                return nil
            }
        }
    }

    private func appendProgressMessageIfNeeded(_ phaseText: String) {
        let normalizedText = phaseText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            return
        }
        guard normalizedText != lastProgressPhaseText else {
            return
        }
        let now = Date()
        finalizeActiveProgressMessage(finishedAt: now)
        lastProgressPhaseText = normalizedText
        if let index = appendMessage(
            role: .assistant,
            text: normalizedText,
            isProgress: true,
            startedAt: now,
            finishedAt: nil
        ) {
            activeProgressMessageID = messages[index].id
        }
    }

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
        let hasProvider = providerCredential != nil
        let hasThread = currentThread != nil
        if isSending {
            sendButton.isEnabled = true
            var configuration = sendButton.configuration ?? UIButton.Configuration.filled()
            configuration.image = UIImage(systemName: "xmark.circle.fill")
            configuration.baseBackgroundColor = .systemRed
            configuration.baseForegroundColor = .white
            configuration.cornerStyle = .capsule
            sendButton.configuration = configuration
            sendButton.accessibilityLabel = String(localized: "chat.action.cancel")
        } else {
            sendButton.isEnabled = hasText && hasProvider && hasThread
            var configuration = sendButton.configuration ?? UIButton.Configuration.filled()
            configuration.image = UIImage(systemName: "paperplane.fill")
            configuration.baseBackgroundColor = .systemBlue
            configuration.baseForegroundColor = .white
            configuration.cornerStyle = .capsule
            sendButton.configuration = configuration
            sendButton.accessibilityLabel = String(localized: "chat.action.send")
        }
        inputTextView.isEditable = !isSending
        inputTextView.alpha = isSending ? 0.72 : 1.0
        refreshNavigationItems()
    }

    private func runtimeCredential(from base: ProjectChatService.ProviderCredential) -> ProjectChatService.ProviderCredential {
        let normalizedSelectedModel = selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !normalizedSelectedModel.isEmpty else {
            return base
        }
        return ProjectChatService.ProviderCredential(
            providerID: base.providerID,
            providerLabel: base.providerLabel,
            providerKind: base.providerKind,
            authMode: base.authMode,
            modelID: normalizedSelectedModel,
            baseURL: base.baseURL,
            bearerToken: base.bearerToken,
            chatGPTAccountID: base.chatGPTAccountID
        )
    }

    @objc
    private func didTapClose() {
        persistCurrentThreadMessages()
        dismiss(animated: true)
    }

    @objc
    private func didTapSend() {
        if isSending {
            cancelCurrentRequest(showMessage: true)
            return
        }

        let userInput = currentInputText()
        guard !userInput.isEmpty else {
            return
        }
        guard let baseProviderCredential = providerCredential else {
            _ = appendMessage(role: .system, text: LocalError.noAvailableProvider.localizedDescription)
            return
        }
        guard let currentThread else {
            _ = appendMessage(role: .system, text: LocalError.noThreadAvailable.localizedDescription)
            return
        }
        let providerCredential = runtimeCredential(from: baseProviderCredential)

        inputTextView.text = ""
        refreshInputPlaceholder()
        updateInputTextViewHeight()
        _ = appendMessage(role: .user, text: userInput)
        inputTextView.resignFirstResponder()
        let historyTurns = buildHistoryTurns()
        currentRequestStartedAt = Date()
        isSending = true
        didCancelCurrentRequest = false
        didAppendCancelMessage = false
        lastProgressPhaseText = nil
        activeProgressMessageID = nil
        startProgressUIUpdateTimerIfNeeded()
        persistCurrentThreadMessages()
        refreshSendButton()

        sendTask = Task { [weak self] in
            guard let self else { return }
            defer {
                finalizeActiveProgressMessage()
                stopProgressUIUpdateTimer()
                sendTask = nil
                didCancelCurrentRequest = false
                didAppendCancelMessage = false
                lastProgressPhaseText = nil
                activeProgressMessageID = nil
                currentRequestStartedAt = nil
                isSending = false
                refreshSendButton()
                persistCurrentThreadMessages()
            }

            do {
                let threadContext = buildThreadContext()
                let requestReasoningEffort: ProjectChatService.ReasoningEffort = {
                    guard let providerKind = self.currentProviderKind() else {
                        return .high
                    }
                    return self.resolvedReasoningEffort(
                        forModelID: providerCredential.modelID,
                        providerKind: providerKind
                    )
                }()
                let result = try await chatService.sendAndApply(
                    userMessage: userInput,
                    history: historyTurns,
                    projectURL: projectURL,
                    credential: providerCredential,
                    memory: sessionMemory,
                    threadContext: threadContext,
                    reasoningEffort: requestReasoningEffort,
                    onStreamedText: nil,
                    onProgress: { [weak self] phaseText in
                        guard let self else {
                            return
                        }
                        self.appendProgressMessageIfNeeded(phaseText)
                    }
                )

                sessionMemory = result.updatedMemory
                threadSessionMemories[currentThread.id] = result.updatedMemory

                finalizeActiveProgressMessage()
                var assistantText = result.assistantMessage
                if !result.changedPaths.isEmpty {
                    let changesSummary = result.changedPaths.joined(separator: ", ")
                    assistantText += String(
                        format: String(localized: "chat.system.files_updated.append_format"),
                        changesSummary
                    )
                }
                _ = appendMessage(
                    role: .assistant,
                    text: assistantText,
                    startedAt: currentRequestStartedAt
                )

                do {
                    let applyResult = try threadStore.applyThreadMemoryUpdate(
                        projectURL: projectURL,
                        threadID: currentThread.id,
                        update: result.threadMemoryUpdate,
                        fallbackUserMessage: userInput,
                        fallbackAssistantMessage: assistantText
                    )
                    self.currentThread = applyResult.updatedThread
                    if var index = self.threadIndex {
                        if let threadIndex = index.threads.firstIndex(where: { $0.id == applyResult.updatedThread.id }) {
                            index.threads[threadIndex] = applyResult.updatedThread
                            index.currentThreadID = applyResult.updatedThread.id
                            self.threadIndex = index
                        }
                    }
                } catch {
                    _ = appendMessage(
                        role: .system,
                        text: String(
                            format: String(localized: "chat.system.memory_update_failed.message_format"),
                            error.localizedDescription
                        )
                    )
                }

                if !result.changedPaths.isEmpty {
                    onProjectFilesUpdated?()
                }
            } catch is CancellationError {
                finalizeActiveProgressMessage()
                if !didAppendCancelMessage {
                    _ = appendMessage(
                        role: .system,
                        text: String(localized: "chat.system.request_cancelled"),
                        startedAt: currentRequestStartedAt
                    )
                    didAppendCancelMessage = true
                }
            } catch {
                if didCancelCurrentRequest {
                    finalizeActiveProgressMessage()
                    if !didAppendCancelMessage {
                        _ = appendMessage(
                            role: .system,
                            text: String(localized: "chat.system.request_cancelled"),
                            startedAt: currentRequestStartedAt
                        )
                        didAppendCancelMessage = true
                    }
                    return
                }
                finalizeActiveProgressMessage()
                _ = appendMessage(
                    role: .system,
                    text: error.localizedDescription,
                    startedAt: currentRequestStartedAt
                )
            }
        }
    }

    private func cancelCurrentRequest(showMessage: Bool) {
        guard isSending else {
            return
        }
        didCancelCurrentRequest = true
        sendTask?.cancel()
        if showMessage, !didAppendCancelMessage {
            _ = appendMessage(
                role: .system,
                text: String(localized: "chat.system.request_cancelled"),
                startedAt: currentRequestStartedAt
            )
            didAppendCancelMessage = true
        }
    }
}

extension ProjectChatViewController: UITableViewDataSource {
    func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        messages.count
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

        let message = messages[indexPath.row]
        cell.configure(message: message, now: Date())
        return cell
    }
}

extension ProjectChatViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        refreshInputPlaceholder()
        updateInputTextViewHeight()
        refreshSendButton()
    }
}

private final class ChatMessageCell: UITableViewCell {
    static let reuseIdentifier = "ChatMessageCell"

    private static let timestampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()

    private let bubbleContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = 12
        view.layer.cornerCurve = .continuous
        view.layer.borderWidth = 1
        view.layer.borderColor = UIColor.clear.cgColor
        return view
    }()

    private let messageLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 15)
        return label
    }()

    private let metaLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 1
        label.font = .monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        return label
    }()

    private var leadingConstraint: NSLayoutConstraint!
    private var trailingConstraint: NSLayoutConstraint!

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)
        selectionStyle = .none
        backgroundColor = .clear
        contentView.backgroundColor = .clear

        contentView.addSubview(bubbleContainer)
        bubbleContainer.addSubview(messageLabel)
        bubbleContainer.addSubview(metaLabel)

        leadingConstraint = bubbleContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 10)
        trailingConstraint = bubbleContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -10)

        NSLayoutConstraint.activate([
            bubbleContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 4),
            bubbleContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -4),
            leadingConstraint,
            trailingConstraint,
            bubbleContainer.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.92),

            messageLabel.topAnchor.constraint(equalTo: bubbleContainer.topAnchor, constant: 10),
            messageLabel.leadingAnchor.constraint(equalTo: bubbleContainer.leadingAnchor, constant: 12),
            messageLabel.trailingAnchor.constraint(equalTo: bubbleContainer.trailingAnchor, constant: -12),
            metaLabel.topAnchor.constraint(equalTo: messageLabel.bottomAnchor, constant: 8),
            metaLabel.leadingAnchor.constraint(equalTo: bubbleContainer.leadingAnchor, constant: 12),
            metaLabel.trailingAnchor.constraint(equalTo: bubbleContainer.trailingAnchor, constant: -12),
            metaLabel.bottomAnchor.constraint(equalTo: bubbleContainer.bottomAnchor, constant: -10)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(message: ProjectChatViewController.Message, now: Date) {
        let animatedText = displayText(for: message, now: now)
        messageLabel.text = animatedText
        metaLabel.text = metadataText(for: message, now: now)

        switch message.role {
        case .user:
            trailingConstraint.isActive = true
            leadingConstraint.isActive = false
            bubbleContainer.backgroundColor = tintColor
            messageLabel.textColor = .white
            metaLabel.textColor = UIColor.white.withAlphaComponent(0.78)
            bubbleContainer.layer.borderColor = UIColor.clear.cgColor
        case .assistant:
            trailingConstraint.isActive = false
            leadingConstraint.isActive = true
            bubbleContainer.backgroundColor = .secondarySystemGroupedBackground
            messageLabel.textColor = .label
            metaLabel.textColor = .secondaryLabel
            if message.isProgress && message.finishedAt == nil {
                bubbleContainer.layer.borderColor = tintColor.withAlphaComponent(0.45).cgColor
            } else {
                bubbleContainer.layer.borderColor = UIColor.clear.cgColor
            }
        case .system:
            trailingConstraint.isActive = false
            leadingConstraint.isActive = true
            bubbleContainer.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.24)
            messageLabel.textColor = .secondaryLabel
            metaLabel.textColor = .tertiaryLabel
            bubbleContainer.layer.borderColor = UIColor.clear.cgColor
        }
    }

    private func displayText(for message: ProjectChatViewController.Message, now: Date) -> String {
        guard message.isProgress, message.finishedAt == nil else {
            return message.text
        }
        let baseText = message.text.replacingOccurrences(
            of: #"[.。…\s]+$"#,
            with: "",
            options: .regularExpression
        )
        let phase = Int((now.timeIntervalSinceReferenceDate * 2).rounded(.down)) % 3 + 1
        let dots = String(repeating: ".", count: phase)
        return baseText + dots
    }

    private func metadataText(for message: ProjectChatViewController.Message, now: Date) -> String {
        let timestamp = Self.timestampFormatter.string(from: message.createdAt)
        let endAt = message.finishedAt ?? now
        let duration = max(0, endAt.timeIntervalSince(message.startedAt))
        let durationString = formatDuration(duration)
        return "\(timestamp) · \(durationString)"
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        if duration < 1 {
            let milliseconds = Int((duration * 1000).rounded())
            return String(format: String(localized: "chat.duration.ms_format"), milliseconds)
        }
        if duration < 60 {
            return String(format: String(localized: "chat.duration.seconds_format"), duration)
        }
        let minutes = Int(duration) / 60
        let seconds = duration - Double(minutes * 60)
        return String(format: String(localized: "chat.duration.minutes_seconds_format"), minutes, seconds)
    }
}
