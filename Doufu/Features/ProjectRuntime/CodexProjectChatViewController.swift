//
//  CodexProjectChatViewController.swift
//  Doufu
//
//  Created by Codex on 2026/03/05.
//

import UIKit

final class CodexProjectChatViewController: UIViewController {

    var onProjectFilesUpdated: (() -> Void)?

    private enum LocalError: LocalizedError {
        case noAvailableProvider

        var errorDescription: String? {
            switch self {
            case .noAvailableProvider:
                return "没有可用的 Provider。请先在设置中添加 API Key 或 OAuth Provider。"
            }
        }
    }

    fileprivate struct Message: Hashable {
        enum Role: Hashable {
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
    }

    private let projectName: String
    private let projectURL: URL
    private let chatService = CodexProjectChatService()
    private let providerStore = LLMProviderSettingsStore.shared

    private var messages: [Message] = []
    private var providerCredential: CodexProjectChatService.ProviderCredential?
    private var sessionMemory: CodexProjectChatService.SessionMemory?
    private var isSending = false

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

    private lazy var inputTextField: UITextField = {
        let field = UITextField()
        field.translatesAutoresizingMaskIntoConstraints = false
        field.borderStyle = .roundedRect
        field.placeholder = "描述你想让 Codex 修改的内容"
        field.returnKeyType = .send
        field.delegate = self
        field.addTarget(self, action: #selector(textFieldDidChange), for: .editingChanged)
        return field
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
        configureProvider()
        refreshSendButton()
    }

    private func configureNavigation() {
        navigationItem.rightBarButtonItem = UIBarButtonItem(
            barButtonSystemItem: .close,
            target: self,
            action: #selector(didTapClose)
        )
    }

    private func configureLayout() {
        view.addSubview(tableView)
        view.addSubview(inputContainer)
        inputContainer.addSubview(inputTextField)
        inputContainer.addSubview(sendButton)

        let inputBottomConstraint: NSLayoutConstraint
        if #available(iOS 15.0, *) {
            inputBottomConstraint = inputContainer.bottomAnchor.constraint(equalTo: view.keyboardLayoutGuide.topAnchor)
        } else {
            inputBottomConstraint = inputContainer.bottomAnchor.constraint(equalTo: view.safeAreaLayoutGuide.bottomAnchor)
        }

        NSLayoutConstraint.activate([
            tableView.topAnchor.constraint(equalTo: view.topAnchor),
            tableView.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            tableView.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            tableView.bottomAnchor.constraint(equalTo: inputContainer.topAnchor),

            inputContainer.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            inputContainer.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            inputBottomConstraint,

            inputTextField.topAnchor.constraint(equalTo: inputContainer.topAnchor, constant: 10),
            inputTextField.leadingAnchor.constraint(equalTo: inputContainer.leadingAnchor, constant: 12),
            inputTextField.bottomAnchor.constraint(equalTo: inputContainer.safeAreaLayoutGuide.bottomAnchor, constant: -10),

            sendButton.leadingAnchor.constraint(equalTo: inputTextField.trailingAnchor, constant: 10),
            sendButton.trailingAnchor.constraint(equalTo: inputContainer.trailingAnchor, constant: -12),
            sendButton.centerYAnchor.constraint(equalTo: inputTextField.centerYAnchor),
            sendButton.widthAnchor.constraint(equalToConstant: 68)
        ])
    }

    private func configureProvider() {
        do {
            let credential = try resolveProviderCredential()
            providerCredential = credential
            appendMessage(
                role: .system,
                text: "已连接 Provider「\(credential.providerLabel)」。你现在可以描述要改的网页需求。"
            )
        } catch {
            providerCredential = nil
            appendMessage(role: .system, text: error.localizedDescription)
        }
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

        messages.append(Message(role: role, text: normalizedText))
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

    private func refreshSendButton() {
        let hasText = !(inputTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        let hasProvider = providerCredential != nil
        sendButton.isEnabled = hasText && !isSending && hasProvider
    }

    @objc
    private func didTapClose() {
        dismiss(animated: true)
    }

    @objc
    private func textFieldDidChange() {
        refreshSendButton()
    }

    @objc
    private func didTapSend() {
        guard !isSending else {
            return
        }

        let userInput = inputTextField.text?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !userInput.isEmpty else {
            return
        }
        guard let providerCredential else {
            appendMessage(role: .system, text: LocalError.noAvailableProvider.localizedDescription)
            return
        }

        inputTextField.text = nil
        appendMessage(role: .user, text: userInput)
        inputTextField.resignFirstResponder()
        let historyTurns = buildHistoryTurns()
        let streamingMessageIndex = appendMessage(role: .assistant, text: "Codex 正在生成...")
        final class StreamState {
            var hasReceivedModelText = false
        }
        let streamState = StreamState()
        isSending = true
        refreshSendButton()

        Task { [weak self] in
            guard let self else { return }

            do {
                let result = try await chatService.sendAndApply(
                    userMessage: userInput,
                    history: historyTurns,
                    projectURL: projectURL,
                    credential: providerCredential,
                    memory: sessionMemory,
                    onStreamedText: { [weak self] partialText in
                        guard let self, let streamingMessageIndex else {
                            return
                        }
                        streamState.hasReceivedModelText = true
                        self.updateMessage(at: streamingMessageIndex, text: partialText)
                    },
                    onProgress: { [weak self] phaseText in
                        guard let self, let streamingMessageIndex else {
                            return
                        }
                        guard !streamState.hasReceivedModelText else {
                            return
                        }
                        self.updateMessage(at: streamingMessageIndex, text: phaseText)
                    }
                )

                sessionMemory = result.updatedMemory

                var assistantText = result.assistantMessage
                if !result.changedPaths.isEmpty {
                    let changesSummary = result.changedPaths.joined(separator: ", ")
                    assistantText += "\n\n已更新文件：\(changesSummary)"
                }
                if let streamingMessageIndex {
                    updateMessage(at: streamingMessageIndex, text: assistantText)
                } else {
                    appendMessage(role: .assistant, text: assistantText)
                }

                if !result.changedPaths.isEmpty {
                    onProjectFilesUpdated?()
                }
            } catch {
                if let streamingMessageIndex {
                    removeMessage(at: streamingMessageIndex)
                }
                appendMessage(role: .system, text: error.localizedDescription)
            }

            isSending = false
            refreshSendButton()
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

extension CodexProjectChatViewController: UITextFieldDelegate {
    func textFieldShouldReturn(_ textField: UITextField) -> Bool {
        didTapSend()
        return true
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
