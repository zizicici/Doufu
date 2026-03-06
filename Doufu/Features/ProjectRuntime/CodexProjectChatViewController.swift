//
//  CodexProjectChatViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import UIKit

@MainActor
final class CodexProjectChatViewController: UIViewController {

    var onProjectFilesUpdated: (() -> Void)?

    private enum LocalError: LocalizedError {
        case noAvailableProvider
        case noThreadAvailable

        var errorDescription: String? {
            switch self {
            case .noAvailableProvider:
                return "没有可用的 Provider。请先在设置中添加 API Key 或 OAuth Provider。"
            case .noThreadAvailable:
                return "没有可用线程，请先创建线程。"
            }
        }
    }

    fileprivate struct Message: Hashable {
        enum Role: String, Hashable {
            case user
            case assistant
            case system

            var prefix: String {
                switch self {
                case .user:
                    return "你"
                case .assistant:
                    return "Codex"
                case .system:
                    return "系统"
                }
            }
        }

        let id = UUID()
        let role: Role
        var text: String
        let createdAt: Date
    }

    private let projectName: String
    private let projectURL: URL
    private let chatService = CodexProjectChatService()
    private let providerStore = LLMProviderSettingsStore.shared
    private let threadStore = ProjectChatThreadStore.shared

    private var messages: [Message] = []
    private var providerCredential: CodexProjectChatService.ProviderCredential?
    private var sessionMemory: CodexProjectChatService.SessionMemory?
    private var threadSessionMemories: [String: CodexProjectChatService.SessionMemory] = [:]
    private var isSending = false
    private var sendTask: Task<Void, Never>?
    private var activeStreamingMessageIndex: Int?
    private var didCancelCurrentRequest = false
    private var threadIndex: ProjectChatThreadIndex?
    private var currentThread: ProjectChatThreadRecord?
    private var selectedReasoningEffort: CodexProjectChatService.ReasoningEffort = .high
    private let inputMinHeight: CGFloat = 38
    private let inputMaxHeight: CGFloat = 120
    private var inputHeightConstraint: NSLayoutConstraint?

    private lazy var closeBarButtonItem = UIBarButtonItem(
        barButtonSystemItem: .close,
        target: self,
        action: #selector(didTapClose)
    )

    private lazy var reasoningBarButtonItem = UIBarButtonItem(
        title: selectedReasoningEffort.displayName,
        style: .plain,
        target: nil,
        action: nil
    )

    private lazy var threadBarButtonItem = UIBarButtonItem(
        title: "Threads",
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
        label.text = "描述你想让 Codex 修改的内容"
        label.textColor = .placeholderText
        label.font = .systemFont(ofSize: 16)
        label.numberOfLines = 1
        return label
    }()

    private lazy var sendButton: UIButton = {
        var configuration = UIButton.Configuration.filled()
        configuration.title = "发送"
        let button = UIButton(configuration: configuration)
        button.translatesAutoresizingMaskIntoConstraints = false
        button.addTarget(self, action: #selector(didTapSend), for: .touchUpInside)
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
        title = "Codex 聊天"
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

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        persistCurrentThreadMessages()
    }

    private func configureNavigation() {
        navigationItem.rightBarButtonItems = [closeBarButtonItem, reasoningBarButtonItem]
        refreshNavigationItems()
    }

    private func refreshNavigationItems() {
        if isSending {
            navigationItem.leftBarButtonItem = UIBarButtonItem(
                title: "取消",
                style: .plain,
                target: self,
                action: #selector(didTapCancelRequest)
            )
        } else {
            threadBarButtonItem.title = currentThread?.title ?? "Threads"
            threadBarButtonItem.menu = buildThreadMenu()
            navigationItem.leftBarButtonItem = threadBarButtonItem
        }
        reasoningBarButtonItem.title = selectedReasoningEffort.displayName
        reasoningBarButtonItem.menu = buildReasoningMenu()
        reasoningBarButtonItem.isEnabled = !isSending
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
            sendButton.widthAnchor.constraint(equalToConstant: 68)
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
            appendProviderStatusIfNeeded()
        } catch {
            providerCredential = nil
            appendMessage(role: .system, text: error.localizedDescription)
        }
    }

    private func appendProviderStatusIfNeeded() {
        guard let credential = providerCredential else {
            return
        }
        guard messages.isEmpty else {
            return
        }
        _ = appendMessage(role: .system, text: "已连接 Provider「\(credential.providerLabel)」。你现在可以描述要改的网页需求。")
        persistCurrentThreadMessages()
    }

    private func resolveProviderCredential() throws -> CodexProjectChatService.ProviderCredential {
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

            return CodexProjectChatService.ProviderCredential(
                providerID: provider.id,
                providerLabel: provider.label,
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
                UIAction(title: "暂无线程", attributes: .disabled) { _ in }
            ]
        }

        let createAction = UIAction(title: "新建线程", image: UIImage(systemName: "plus")) { [weak self] _ in
            self?.createAndSwitchThread()
        }
        return UIMenu(title: "Threads", children: threadActions + [createAction])
    }

    private func buildReasoningMenu() -> UIMenu {
        let actions = CodexProjectChatService.ReasoningEffort.allCases.map { effort in
            UIAction(
                title: effort.displayName,
                state: effort == selectedReasoningEffort ? .on : .off
            ) { [weak self] _ in
                self?.selectedReasoningEffort = effort
                self?.refreshNavigationItems()
            }
        }
        return UIMenu(title: "Reasoning", children: actions)
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
            _ = appendMessage(role: .system, text: "已创建并切换到新线程。")
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
            return Message(role: role, text: text, createdAt: persistedMessage.createdAt)
        }

        if appendStatusMessage {
            _ = appendMessage(role: .system, text: "已切换到线程「\(switched.title)」。")
        }
        appendProviderStatusIfNeeded()

        tableView.reloadData()
        scrollToBottomIfNeeded()
        refreshNavigationItems()
    }

    private func buildThreadContext() -> CodexProjectChatService.ThreadContext? {
        guard let currentThread else {
            return nil
        }
        let memoryFilePath = threadStore.currentMemoryFilePath(for: currentThread)
        let memoryContent = threadStore.loadThreadMemory(projectURL: projectURL, thread: currentThread)
        return CodexProjectChatService.ThreadContext(
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
                createdAt: message.createdAt
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
    private func appendMessage(role: Message.Role, text: String) -> Int? {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else {
            return nil
        }

        messages.append(Message(role: role, text: normalizedText, createdAt: Date()))
        tableView.reloadData()
        scrollToBottomIfNeeded()
        return messages.count - 1
    }

    private func updateMessage(at index: Int, text: String) {
        guard messages.indices.contains(index) else {
            return
        }

        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        messages[index].text = normalizedText.isEmpty ? "Codex 正在生成..." : normalizedText
        tableView.reloadData()
        scrollToBottomIfNeeded()
    }

    private func removeMessage(at index: Int) {
        guard messages.indices.contains(index) else {
            return
        }

        messages.remove(at: index)
        tableView.reloadData()
    }

    private func scrollToBottomIfNeeded() {
        guard !messages.isEmpty else {
            return
        }
        let lastRow = messages.count - 1
        let indexPath = IndexPath(row: lastRow, section: 0)
        tableView.scrollToRow(at: indexPath, at: .bottom, animated: true)
    }

    private func buildHistoryTurns() -> [CodexProjectChatService.ChatTurn] {
        messages.compactMap { message in
            let normalizedText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedText.isEmpty else {
                return nil
            }
            switch message.role {
            case .user:
                return .init(role: .user, text: normalizedText)
            case .assistant:
                return .init(role: .assistant, text: normalizedText)
            case .system:
                return nil
            }
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
        sendButton.isEnabled = hasText && !isSending && hasProvider && hasThread
        inputTextView.isEditable = !isSending
        inputTextView.alpha = isSending ? 0.72 : 1.0
        refreshNavigationItems()
    }

    @objc
    private func didTapClose() {
        if isSending {
            cancelCurrentRequest(showMessage: false)
        }
        persistCurrentThreadMessages()
        dismiss(animated: true)
    }

    @objc
    private func didTapCancelRequest() {
        cancelCurrentRequest(showMessage: true)
    }

    @objc
    private func didTapSend() {
        guard !isSending else {
            return
        }

        let userInput = currentInputText()
        guard !userInput.isEmpty else {
            return
        }
        guard let providerCredential else {
            _ = appendMessage(role: .system, text: LocalError.noAvailableProvider.localizedDescription)
            return
        }
        guard let currentThread else {
            _ = appendMessage(role: .system, text: LocalError.noThreadAvailable.localizedDescription)
            return
        }

        inputTextView.text = ""
        refreshInputPlaceholder()
        updateInputTextViewHeight()
        _ = appendMessage(role: .user, text: userInput)
        inputTextView.resignFirstResponder()
        let historyTurns = buildHistoryTurns()
        let streamingMessageIndex = appendMessage(role: .assistant, text: "Codex 正在生成...")
        activeStreamingMessageIndex = streamingMessageIndex
        isSending = true
        didCancelCurrentRequest = false
        persistCurrentThreadMessages()
        refreshSendButton()

        sendTask = Task { [weak self] in
            guard let self else { return }
            defer {
                sendTask = nil
                activeStreamingMessageIndex = nil
                didCancelCurrentRequest = false
                isSending = false
                refreshSendButton()
                persistCurrentThreadMessages()
            }

            do {
                let threadContext = buildThreadContext()
                let result = try await chatService.sendAndApply(
                    userMessage: userInput,
                    history: historyTurns,
                    projectURL: projectURL,
                    credential: providerCredential,
                    memory: sessionMemory,
                    threadContext: threadContext,
                    reasoningEffort: selectedReasoningEffort,
                    onStreamedText: nil,
                    onProgress: { [weak self] phaseText in
                        guard let self, let streamingMessageIndex else {
                            return
                        }
                        self.updateMessage(at: streamingMessageIndex, text: phaseText)
                    }
                )

                sessionMemory = result.updatedMemory
                threadSessionMemories[currentThread.id] = result.updatedMemory

                var assistantText = result.assistantMessage
                if !result.changedPaths.isEmpty {
                    let changesSummary = result.changedPaths.joined(separator: ", ")
                    assistantText += "\n\n已更新文件：\(changesSummary)"
                }

                if let streamingMessageIndex {
                    updateMessage(at: streamingMessageIndex, text: assistantText)
                } else {
                    _ = appendMessage(role: .assistant, text: assistantText)
                }

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
                    _ = appendMessage(role: .system, text: "线程记忆更新失败：\(error.localizedDescription)")
                }

                if !result.changedPaths.isEmpty {
                    onProjectFilesUpdated?()
                }
            } catch is CancellationError {
                if let streamingMessageIndex {
                    updateMessage(at: streamingMessageIndex, text: "已取消本次请求。")
                } else {
                    _ = appendMessage(role: .system, text: "已取消本次请求。")
                }
            } catch {
                if didCancelCurrentRequest {
                    if let streamingMessageIndex {
                        updateMessage(at: streamingMessageIndex, text: "已取消本次请求。")
                    } else {
                        _ = appendMessage(role: .system, text: "已取消本次请求。")
                    }
                    return
                }
                if let streamingMessageIndex {
                    removeMessage(at: streamingMessageIndex)
                }
                _ = appendMessage(role: .system, text: error.localizedDescription)
            }
        }
    }

    private func cancelCurrentRequest(showMessage: Bool) {
        guard isSending else {
            return
        }
        didCancelCurrentRequest = true
        sendTask?.cancel()
        if showMessage {
            if let index = activeStreamingMessageIndex {
                updateMessage(at: index, text: "已取消本次请求。")
            } else {
                _ = appendMessage(role: .system, text: "已取消本次请求。")
            }
        }
    }
}

extension CodexProjectChatViewController: UITableViewDataSource {
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
        cell.configure(prefix: message.role.prefix, text: message.text, role: message.role)
        return cell
    }
}

extension CodexProjectChatViewController: UITextViewDelegate {
    func textViewDidChange(_ textView: UITextView) {
        refreshInputPlaceholder()
        updateInputTextViewHeight()
        refreshSendButton()
    }
}

private final class ChatMessageCell: UITableViewCell {
    static let reuseIdentifier = "ChatMessageCell"

    private let bubbleContainer: UIView = {
        let view = UIView()
        view.translatesAutoresizingMaskIntoConstraints = false
        view.layer.cornerRadius = 12
        view.layer.cornerCurve = .continuous
        return view
    }()

    private let messageLabel: UILabel = {
        let label = UILabel()
        label.translatesAutoresizingMaskIntoConstraints = false
        label.numberOfLines = 0
        label.font = .systemFont(ofSize: 15)
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

        leadingConstraint = bubbleContainer.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 18)
        trailingConstraint = bubbleContainer.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -18)

        NSLayoutConstraint.activate([
            bubbleContainer.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 6),
            bubbleContainer.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -6),
            leadingConstraint,
            trailingConstraint,
            bubbleContainer.widthAnchor.constraint(lessThanOrEqualTo: contentView.widthAnchor, multiplier: 0.86),

            messageLabel.topAnchor.constraint(equalTo: bubbleContainer.topAnchor, constant: 10),
            messageLabel.leadingAnchor.constraint(equalTo: bubbleContainer.leadingAnchor, constant: 12),
            messageLabel.trailingAnchor.constraint(equalTo: bubbleContainer.trailingAnchor, constant: -12),
            messageLabel.bottomAnchor.constraint(equalTo: bubbleContainer.bottomAnchor, constant: -10)
        ])
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func configure(prefix: String, text: String, role: CodexProjectChatViewController.Message.Role) {
        messageLabel.text = "\(prefix)：\(text)"

        switch role {
        case .user:
            trailingConstraint.isActive = true
            leadingConstraint.isActive = false
            bubbleContainer.backgroundColor = tintColor
            messageLabel.textColor = .white
        case .assistant:
            trailingConstraint.isActive = false
            leadingConstraint.isActive = true
            bubbleContainer.backgroundColor = .secondarySystemGroupedBackground
            messageLabel.textColor = .label
        case .system:
            trailingConstraint.isActive = false
            leadingConstraint.isActive = true
            bubbleContainer.backgroundColor = UIColor.systemYellow.withAlphaComponent(0.24)
            messageLabel.textColor = .secondaryLabel
        }
    }
}
