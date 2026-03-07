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
        let requestTokenUsage: ProjectChatService.RequestTokenUsage?
    }

    private var projectName: String
    private let projectURL: URL
    private let chatService = ProjectChatService()
    private let providerStore = LLMProviderSettingsStore.shared
    private let threadStore = ProjectChatThreadStore.shared

    private var messages: [Message] = []
    private var availableProviderCredentials: [ProjectChatService.ProviderCredential] = []
    private var providerCredential: ProjectChatService.ProviderCredential?
    private var selectedProviderID: String?
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
    private var selectedModelIDByProviderID: [String: String] = [:]
    private var selectedReasoningEffortsByModelID: [String: ProjectChatService.ReasoningEffort] = [:]
    private var selectedAnthropicThinkingEnabledByModelID: [String: Bool] = [:]
    private var selectedGeminiThinkingEnabledByModelID: [String: Bool] = [:]
    private let inputMinHeight: CGFloat = 38
    private let inputMaxHeight: CGFloat = 120
    private var inputHeightConstraint: NSLayoutConstraint?

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
        configuration.image = UIImage(systemName: "arrow.up")
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
        navigationItem.rightBarButtonItems = [moreBarButtonItem, modelBarButtonItem, usageBarButtonItem]
        refreshNavigationItems()
    }

    private func refreshNavigationItems() {
        threadBarButtonItem.title = currentThread?.title ?? String(localized: "chat.thread.button_title")
        threadBarButtonItem.menu = isSending ? nil : buildThreadMenu()
        threadBarButtonItem.isEnabled = !isSending
        navigationItem.leftBarButtonItem = threadBarButtonItem
        modelBarButtonItem.image = UIImage(systemName: "theatermask.and.paintbrush")
        modelBarButtonItem.accessibilityLabel = currentModelMenuButtonTitle()
        modelBarButtonItem.menu = nil
        modelBarButtonItem.isEnabled = !isSending && providerCredential != nil
        usageBarButtonItem.isEnabled = !isSending
        moreBarButtonItem.menu = isSending ? nil : buildMoreMenu()
        moreBarButtonItem.isEnabled = !isSending
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
            if
                let currentProviderID = providerCredential?.providerID,
                let currentModelID = selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines),
                !currentModelID.isEmpty
            {
                selectedModelIDByProviderID[currentProviderID] = currentModelID
            }

            availableProviderCredentials = try resolveProviderCredentials()
            let preferredProviderID = selectedProviderID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let credential = availableProviderCredentials.first(where: { $0.providerID == preferredProviderID })
                ?? availableProviderCredentials.first
            guard let credential else {
                throw LocalError.noAvailableProvider
            }

            providerCredential = credential
            selectedProviderID = credential.providerID
            let providerSelectedModel = selectedModelIDByProviderID[credential.providerID]?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if providerSelectedModel.isEmpty {
                selectedModelID = credential.modelID
                selectedModelIDByProviderID[credential.providerID] = credential.modelID
            } else {
                selectedModelID = providerSelectedModel
            }
            appendProviderStatusIfNeeded()
            refreshNavigationItems()
        } catch {
            availableProviderCredentials = []
            providerCredential = nil
            selectedProviderID = nil
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

    private func resolveProviderCredentials() throws -> [ProjectChatService.ProviderCredential] {
        var output: [ProjectChatService.ProviderCredential] = []
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

            output.append(ProjectChatService.ProviderCredential(
                providerID: provider.id,
                providerLabel: provider.label,
                providerKind: provider.kind,
                authMode: provider.authMode,
                modelID: provider.effectiveModelID,
                baseURL: baseURL,
                bearerToken: token,
                chatGPTAccountID: chatGPTAccountID
            ))
        }

        if output.isEmpty {
            throw LocalError.noAvailableProvider
        }

        return output
    }

    private func switchProvider(to providerID: String) {
        guard let credential = availableProviderCredentials.first(where: { $0.providerID == providerID }) else {
            return
        }
        if
            let currentProviderID = providerCredential?.providerID,
            let currentModel = selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !currentModel.isEmpty
        {
            selectedModelIDByProviderID[currentProviderID] = currentModel
        }

        providerCredential = credential
        selectedProviderID = credential.providerID

        let providerModel = selectedModelIDByProviderID[credential.providerID]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if providerModel.isEmpty {
            selectedModelID = credential.modelID
            selectedModelIDByProviderID[credential.providerID] = credential.modelID
        } else {
            selectedModelID = providerModel
        }
        refreshNavigationItems()
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

    private func buildMoreMenu() -> UIMenu {
        let filesAction = UIAction(
            title: String(localized: "workspace.panel.files"),
            image: UIImage(systemName: "folder")
        ) { [weak self] _ in
            self?.presentProjectFiles()
        }
        let settingsAction = UIAction(
            title: String(localized: "workspace.panel.settings"),
            image: UIImage(systemName: "gearshape")
        ) { [weak self] _ in
            self?.presentProjectSettings()
        }
        let closeAction = UIAction(
            title: String(localized: "common.action.close"),
            image: UIImage(systemName: "xmark"),
            attributes: .destructive
        ) { [weak self] _ in
            self?.didTapClose()
        }
        return UIMenu(children: [filesAction, settingsAction, closeAction])
    }

    private func currentModelMenuTitle() -> String {
        if
            let providerID = providerCredential?.providerID,
            let providerModel = selectedModelIDByProviderID[providerID]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !providerModel.isEmpty
        {
            return providerModel
        }

        let selected = selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !selected.isEmpty {
            return selected
        }
        let fallback = providerCredential?.modelID.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        return fallback.isEmpty ? String(localized: "chat.menu.model") : fallback
    }

    private func currentModelMenuButtonTitle() -> String {
        let modelTitle = currentModelMenuTitle()
        guard
            let credential = providerCredential,
            let providerKind = currentProviderKind()
        else {
            return modelTitle
        }
        let normalizedProviderLabel = credential.providerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        let providerTitle = normalizedProviderLabel.isEmpty ? providerKind.displayName : normalizedProviderLabel
        switch providerKind {
        case .openAICompatible:
            guard reasoningProfile(forModelID: modelTitle, providerKind: providerKind) != nil else {
                return providerTitle + " · " + modelTitle
            }
            let effort = resolvedReasoningEffort(forModelID: modelTitle, providerKind: providerKind)
            return providerTitle + " · " + modelTitle + " · " + effort.displayName
        case .anthropic:
            let enabled = resolvedAnthropicThinkingEnabled(forModelID: modelTitle)
            let status = enabled
                ? String(localized: "chat.thinking.enabled")
                : String(localized: "chat.thinking.disabled")
            return providerTitle + " · " + modelTitle + " · " + status
        case .googleGemini:
            let enabled = resolvedGeminiThinkingEnabled(forModelID: modelTitle)
            let status = enabled
                ? String(localized: "chat.thinking.enabled")
                : String(localized: "chat.thinking.disabled")
            return providerTitle + " · " + modelTitle + " · " + status
        }
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
    ) -> (supported: [ProjectChatService.ReasoningEffort], defaultEffort: ProjectChatService.ReasoningEffort)? {
        let normalizedModel = normalizedModelID(modelID)
        switch providerKind {
        case .openAICompatible:
            if normalizedModel.contains("mini") {
                return (supported: [.low, .medium, .high], defaultEffort: .medium)
            }
            if normalizedModel.contains("pro") || normalizedModel.contains("codex") {
                return (supported: [.medium, .high, .xhigh], defaultEffort: .high)
            }
            return (supported: [.low, .medium, .high, .xhigh], defaultEffort: .high)
        case .anthropic, .googleGemini:
            return nil
        }
    }

    private func resolvedReasoningEffort(
        forModelID modelID: String,
        providerKind: LLMProviderRecord.Kind
    ) -> ProjectChatService.ReasoningEffort {
        guard let profile = reasoningProfile(forModelID: modelID, providerKind: providerKind) else {
            return .high
        }
        let key = normalizedModelID(modelID)
        if let selected = selectedReasoningEffortsByModelID[key], profile.supported.contains(selected) {
            return selected
        }
        selectedReasoningEffortsByModelID[key] = profile.defaultEffort
        return profile.defaultEffort
    }

    private func resolvedAnthropicThinkingEnabled(forModelID modelID: String) -> Bool {
        let key = normalizedModelID(modelID)
        if let selected = selectedAnthropicThinkingEnabledByModelID[key] {
            return selected
        }
        selectedAnthropicThinkingEnabledByModelID[key] = true
        return true
    }

    private func resolvedGeminiThinkingEnabled(forModelID modelID: String) -> Bool {
        let key = normalizedModelID(modelID)
        guard geminiModelSupportsThinkingToggle(modelID) else {
            selectedGeminiThinkingEnabledByModelID[key] = true
            return true
        }
        if let selected = selectedGeminiThinkingEnabledByModelID[key] {
            return selected
        }
        selectedGeminiThinkingEnabledByModelID[key] = true
        return true
    }

    private func geminiModelSupportsThinkingToggle(_ modelID: String) -> Bool {
        let normalized = normalizedModelID(modelID)
        return !normalized.contains("gemini-2.5-pro")
    }

    private func providerMenuTitle(for credential: ProjectChatService.ProviderCredential) -> String {
        let normalizedLabel = credential.providerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedLabel.isEmpty ? credential.providerKind.displayName : normalizedLabel
    }

    private func selectedModelID(for credential: ProjectChatService.ProviderCredential) -> String {
        if
            let remembered = selectedModelIDByProviderID[credential.providerID]?
                .trimmingCharacters(in: .whitespacesAndNewlines),
            !remembered.isEmpty
        {
            return remembered
        }
        let fallback = credential.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? credential.providerKind.defaultModelID : fallback
    }

    private func selectProviderModel(
        providerCredential: ProjectChatService.ProviderCredential,
        modelID: String
    ) {
        switchProvider(to: providerCredential.providerID)
        selectedModelID = modelID
        selectedModelIDByProviderID[providerCredential.providerID] = modelID

        let providerKind = providerStore.loadProvider(id: providerCredential.providerID)?.kind ?? providerCredential.providerKind
        let normalizedModel = normalizedModelID(modelID)
        switch providerKind {
        case .openAICompatible:
            if let profile = reasoningProfile(forModelID: modelID, providerKind: providerKind) {
                if let selected = selectedReasoningEffortsByModelID[normalizedModel], profile.supported.contains(selected) {
                    selectedReasoningEffortsByModelID[normalizedModel] = selected
                } else {
                    selectedReasoningEffortsByModelID[normalizedModel] = profile.defaultEffort
                }
            } else {
                selectedReasoningEffortsByModelID.removeValue(forKey: normalizedModel)
            }
        case .anthropic:
            selectedReasoningEffortsByModelID.removeValue(forKey: normalizedModel)
            if selectedAnthropicThinkingEnabledByModelID[normalizedModel] == nil {
                selectedAnthropicThinkingEnabledByModelID[normalizedModel] = true
            }
        case .googleGemini:
            selectedReasoningEffortsByModelID.removeValue(forKey: normalizedModel)
            if !geminiModelSupportsThinkingToggle(modelID) {
                selectedGeminiThinkingEnabledByModelID[normalizedModel] = true
            } else if selectedGeminiThinkingEnabledByModelID[normalizedModel] == nil {
                selectedGeminiThinkingEnabledByModelID[normalizedModel] = true
            }
        }

        refreshNavigationItems()
    }

    private func buildModelOptionMenu(
        providerCredential: ProjectChatService.ProviderCredential,
        modelID: String
    ) -> UIMenu? {
        let providerKind = providerStore.loadProvider(id: providerCredential.providerID)?.kind ?? providerCredential.providerKind
        switch providerKind {
        case .openAICompatible:
            guard let profile = reasoningProfile(forModelID: modelID, providerKind: providerKind) else {
                return nil
            }
            let selectedReasoning = resolvedReasoningEffort(forModelID: modelID, providerKind: providerKind)
            let reasoningActions = profile.supported.map { effort in
                UIAction(
                    title: effort.displayName,
                    state: effort == selectedReasoning ? .on : .off
                ) { [weak self] _ in
                    guard let self else {
                        return
                    }
                    self.selectProviderModel(providerCredential: providerCredential, modelID: modelID)
                    self.selectedReasoningEffortsByModelID[self.normalizedModelID(modelID)] = effort
                    self.refreshNavigationItems()
                }
            }
            return UIMenu(
                title: String(localized: "chat.menu.reasoning"),
                options: .displayInline,
                children: reasoningActions
            )
        case .anthropic:
            let key = normalizedModelID(modelID)
            let currentValue = selectedAnthropicThinkingEnabledByModelID[key] ?? true
            selectedAnthropicThinkingEnabledByModelID[key] = currentValue
            let actions = [
                UIAction(
                    title: String(localized: "chat.thinking.enabled"),
                    state: currentValue ? .on : .off
                ) { [weak self] _ in
                    guard let self else { return }
                    self.selectProviderModel(providerCredential: providerCredential, modelID: modelID)
                    self.selectedAnthropicThinkingEnabledByModelID[key] = true
                    self.refreshNavigationItems()
                },
                UIAction(
                    title: String(localized: "chat.thinking.disabled"),
                    state: currentValue ? .off : .on
                ) { [weak self] _ in
                    guard let self else { return }
                    self.selectProviderModel(providerCredential: providerCredential, modelID: modelID)
                    self.selectedAnthropicThinkingEnabledByModelID[key] = false
                    self.refreshNavigationItems()
                }
            ]
            return UIMenu(
                title: String(localized: "chat.menu.thinking"),
                options: .displayInline,
                children: actions
            )
        case .googleGemini:
            let key = normalizedModelID(modelID)
            guard geminiModelSupportsThinkingToggle(modelID) else {
                selectedGeminiThinkingEnabledByModelID[key] = true
                return nil
            }
            let currentValue = selectedGeminiThinkingEnabledByModelID[key] ?? true
            selectedGeminiThinkingEnabledByModelID[key] = currentValue
            let actions = [
                UIAction(
                    title: String(localized: "chat.thinking.enabled"),
                    state: currentValue ? .on : .off
                ) { [weak self] _ in
                    guard let self else { return }
                    self.selectProviderModel(providerCredential: providerCredential, modelID: modelID)
                    self.selectedGeminiThinkingEnabledByModelID[key] = true
                    self.refreshNavigationItems()
                },
                UIAction(
                    title: String(localized: "chat.thinking.disabled"),
                    state: currentValue ? .off : .on
                ) { [weak self] _ in
                    guard let self else { return }
                    self.selectProviderModel(providerCredential: providerCredential, modelID: modelID)
                    self.selectedGeminiThinkingEnabledByModelID[key] = false
                    self.refreshNavigationItems()
                }
            ]
            return UIMenu(
                title: String(localized: "chat.menu.thinking"),
                options: .displayInline,
                children: actions
            )
        }
    }

    private func buildModelMenu() -> UIMenu {
        guard let credential = providerCredential else {
            let unavailable = UIAction(title: String(localized: "chat.error.no_provider"), attributes: .disabled) { _ in }
            return UIMenu(title: String(localized: "chat.menu.model"), children: [unavailable])
        }
        let providerMenus = availableProviderCredentials.map { provider in
            let providerKind = providerStore.loadProvider(id: provider.providerID)?.kind ?? provider.providerKind
            var modelIDs = providerKind.builtInModels
            let fallbackModel = provider.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
            if !fallbackModel.isEmpty, !modelIDs.contains(where: { $0.caseInsensitiveCompare(fallbackModel) == .orderedSame }) {
                modelIDs.insert(fallbackModel, at: 0)
            }

            let selectedModelForProvider = selectedModelID(for: provider)
            if !selectedModelForProvider.isEmpty, !modelIDs.contains(where: { $0.caseInsensitiveCompare(selectedModelForProvider) == .orderedSame }) {
                modelIDs.insert(selectedModelForProvider, at: 0)
            }

            let modelSubmenus: [UIMenu] = modelIDs.map { modelID in
                let isCurrent = provider.providerID == credential.providerID
                    && modelID.caseInsensitiveCompare(currentModelMenuTitle()) == .orderedSame
                let selectAction = UIAction(
                    title: String(localized: "chat.menu.use_model"),
                    state: isCurrent ? .on : .off
                ) { [weak self] _ in
                    self?.selectProviderModel(providerCredential: provider, modelID: modelID)
                }
                var children: [UIMenuElement] = [selectAction]
                if let optionMenu = buildModelOptionMenu(providerCredential: provider, modelID: modelID) {
                    children.append(optionMenu)
                }
                return UIMenu(
                    title: modelID,
                    options: .displayInline,
                    children: children
                )
            }

            let useProviderAction = UIAction(
                title: String(localized: "chat.menu.use_provider"),
                state: provider.providerID == credential.providerID ? .on : .off
            ) { [weak self] _ in
                self?.switchProvider(to: provider.providerID)
            }
            return UIMenu(
                title: providerMenuTitle(for: provider),
                children: [useProviderAction] + modelSubmenus
            )
        }

        return UIMenu(
            title: String(localized: "chat.menu.model"),
            children: providerMenus
        )
    }

    private func executionOptions(for credential: ProjectChatService.ProviderCredential) -> ProjectChatService.ModelExecutionOptions {
        let providerKind = currentProviderKind() ?? credential.providerKind
        let modelID = credential.modelID
        let reasoningEffort = resolvedReasoningEffort(forModelID: modelID, providerKind: providerKind)
        let anthropicThinkingEnabled: Bool
        let geminiThinkingEnabled: Bool

        switch providerKind {
        case .openAICompatible:
            anthropicThinkingEnabled = true
            geminiThinkingEnabled = true
        case .anthropic:
            anthropicThinkingEnabled = resolvedAnthropicThinkingEnabled(forModelID: modelID)
            geminiThinkingEnabled = true
        case .googleGemini:
            anthropicThinkingEnabled = true
            geminiThinkingEnabled = resolvedGeminiThinkingEnabled(forModelID: modelID)
        }

        return ProjectChatService.ModelExecutionOptions(
            reasoningEffort: reasoningEffort,
            anthropicThinkingEnabled: anthropicThinkingEnabled,
            geminiThinkingEnabled: geminiThinkingEnabled
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
                isProgress: persistedMessage.isProgress,
                requestTokenUsage: {
                    let input = max(0, persistedMessage.inputTokens ?? 0)
                    let output = max(0, persistedMessage.outputTokens ?? 0)
                    guard input > 0 || output > 0 else {
                        return nil
                    }
                    return ProjectChatService.RequestTokenUsage(
                        inputTokens: input,
                        outputTokens: output
                    )
                }()
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
                isProgress: message.isProgress,
                inputTokens: message.requestTokenUsage?.inputTokens,
                outputTokens: message.requestTokenUsage?.outputTokens
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
        finishedAt: Date? = nil,
        requestTokenUsage: ProjectChatService.RequestTokenUsage? = nil
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
                isProgress: isProgress,
                requestTokenUsage: requestTokenUsage
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
    private func didTapModelSettings() {
        guard !isSending else {
            return
        }

        do {
            availableProviderCredentials = try resolveProviderCredentials()
        } catch {
            providerCredential = nil
            selectedProviderID = nil
            appendMessage(role: .system, text: error.localizedDescription)
            refreshNavigationItems()
            return
        }

        guard let fallbackProvider = availableProviderCredentials.first else {
            appendMessage(role: .system, text: LocalError.noAvailableProvider.localizedDescription)
            return
        }

        let selectedProvider = providerCredential ?? fallbackProvider
        providerCredential = selectedProvider
        selectedProviderID = selectedProvider.providerID
        if
            let currentModel = selectedModelID?.trimmingCharacters(in: .whitespacesAndNewlines),
            !currentModel.isEmpty
        {
            selectedModelIDByProviderID[selectedProvider.providerID] = currentModel
        } else {
            selectedModelIDByProviderID[selectedProvider.providerID] = selectedProvider.modelID
        }

        let selectionState = ProjectModelConfigurationViewController.SelectionState(
            selectedProviderID: selectedProvider.providerID,
            selectedModelIDByProviderID: selectedModelIDByProviderID,
            selectedReasoningEffortsByModelID: selectedReasoningEffortsByModelID,
            selectedAnthropicThinkingEnabledByModelID: selectedAnthropicThinkingEnabledByModelID,
            selectedGeminiThinkingEnabledByModelID: selectedGeminiThinkingEnabledByModelID
        )
        let controller = ProjectModelConfigurationViewController(
            providers: availableProviderCredentials,
            initialState: selectionState,
            projectUsageIdentifier: projectURL.standardizedFileURL.path
        )
        controller.onSelectionStateChanged = { [weak self] state in
            self?.applyModelConfigurationSelectionState(state)
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
        guard !isSending else {
            return
        }
        let controller = ProjectTokenUsageViewController(
            projectUsageIdentifier: projectURL.standardizedFileURL.path
        )
        let navigationController = UINavigationController(rootViewController: controller)
        navigationController.modalPresentationStyle = .pageSheet
        if let sheet = navigationController.sheetPresentationController {
            sheet.detents = [.medium(), .large()]
            sheet.prefersGrabberVisible = true
        }
        present(navigationController, animated: true)
    }

    private func applyModelConfigurationSelectionState(_ state: ProjectModelConfigurationViewController.SelectionState) {
        selectedModelIDByProviderID = state.selectedModelIDByProviderID
        selectedReasoningEffortsByModelID = state.selectedReasoningEffortsByModelID
        selectedAnthropicThinkingEnabledByModelID = state.selectedAnthropicThinkingEnabledByModelID
        selectedGeminiThinkingEnabledByModelID = state.selectedGeminiThinkingEnabledByModelID
        selectedProviderID = state.selectedProviderID

        switchProvider(to: state.selectedProviderID)
        let selectedModel = state.selectedModelIDByProviderID[state.selectedProviderID]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !selectedModel.isEmpty {
            selectedModelID = selectedModel
        }
        refreshNavigationItems()
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
            self.projectName = updatedProjectName
            self.onProjectFilesUpdated?()
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
                let requestExecutionOptions = self.executionOptions(for: providerCredential)
                let result = try await chatService.sendAndApply(
                    userMessage: userInput,
                    history: historyTurns,
                    projectURL: projectURL,
                    credential: providerCredential,
                    memory: sessionMemory,
                    threadContext: threadContext,
                    executionOptions: requestExecutionOptions,
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
                    startedAt: currentRequestStartedAt,
                    requestTokenUsage: result.requestTokenUsage
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
        var parts: [String] = [timestamp]
        if message.role != .user {
            let endAt = message.finishedAt ?? now
            let duration = max(0, endAt.timeIntervalSince(message.startedAt))
            let durationString = formatDuration(duration)
            if message.isProgress {
                parts.append(message.finishedAt == nil ? "执行中" : "已完成")
            }
            parts.append(durationString)
        }
        if let usageText = tokenUsageText(for: message.requestTokenUsage), message.finishedAt != nil {
            parts.append(usageText)
        }
        return parts.joined(separator: " · ")
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

    private func tokenUsageText(for usage: ProjectChatService.RequestTokenUsage?) -> String? {
        guard let usage else {
            return nil
        }
        let inputText = formatTokenCountInK(usage.inputTokens)
        let outputText = formatTokenCountInK(usage.outputTokens)
        return "↑\(inputText) ↓\(outputText)"
    }

    private func formatTokenCountInK(_ value: Int64) -> String {
        let kiloValue = Double(max(0, value)) / 1000
        if kiloValue >= 100 {
            return String(format: "%.0fK", kiloValue)
        }
        if kiloValue >= 10 {
            return String(format: "%.1fK", kiloValue)
        }
        return String(format: "%.2fK", kiloValue)
    }
}

@MainActor
final class ProjectModelConfigurationViewController: UITableViewController {
    struct SelectionState {
        var selectedProviderID: String
        var selectedModelIDByProviderID: [String: String]
        var selectedReasoningEffortsByModelID: [String: ProjectChatService.ReasoningEffort]
        var selectedAnthropicThinkingEnabledByModelID: [String: Bool]
        var selectedGeminiThinkingEnabledByModelID: [String: Bool]
    }

    var onSelectionStateChanged: ((SelectionState) -> Void)?

    private enum Section: Int, CaseIterable {
        case provider
        case model
        case parameter
    }

    private let providers: [ProjectChatService.ProviderCredential]
    private var state: SelectionState
    private let projectUsageIdentifier: String
    private let usageStore = LLMTokenUsageStore.shared
    private var usageRecords: [LLMTokenUsageRecord] = []
    private var usageByProviderID: [String: Int64] = [:]
    private var usageByProviderModel: [String: Int64] = [:]

    private let numberFormatter: NumberFormatter = {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter
    }()

    init(
        providers: [ProjectChatService.ProviderCredential],
        initialState: SelectionState,
        projectUsageIdentifier: String
    ) {
        self.providers = providers
        state = initialState
        self.projectUsageIdentifier = projectUsageIdentifier
        super.init(style: .insetGrouped)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func viewDidLoad() {
        super.viewDidLoad()
        refreshNavigationTitle()
        tableView.register(UITableViewCell.self, forCellReuseIdentifier: "ProjectModelConfigCell")
        tableView.register(SettingsToggleCell.self, forCellReuseIdentifier: SettingsToggleCell.reuseIdentifier)
        reloadUsageData()
    }

    override func viewWillAppear(_ animated: Bool) {
        super.viewWillAppear(animated)
        reloadUsageData()
    }

    override func numberOfSections(in tableView: UITableView) -> Int {
        Section.allCases.count
    }

    override func tableView(_ tableView: UITableView, numberOfRowsInSection section: Int) -> Int {
        guard let section = Section(rawValue: section) else {
            return 0
        }
        switch section {
        case .provider:
            return providers.count
        case .model:
            guard let selectedProvider = selectedProviderCredential() else {
                return 0
            }
            return availableModelIDs(for: selectedProvider).count
        case .parameter:
            guard let selectedProvider = selectedProviderCredential() else {
                return 0
            }
            let selectedModelID = selectedModelID(for: selectedProvider)
            switch selectedProvider.providerKind {
            case .openAICompatible:
                return reasoningProfile(forModelID: selectedModelID, providerKind: .openAICompatible)?
                    .supported.count ?? 0
            case .anthropic, .googleGemini:
                return 1
            }
        }
    }

    override func tableView(_ tableView: UITableView, titleForHeaderInSection section: Int) -> String? {
        guard let section = Section(rawValue: section) else {
            return nil
        }
        switch section {
        case .provider:
            return String(localized: "chat.menu.provider")
        case .model:
            return String(localized: "chat.menu.model")
        case .parameter:
            guard let selectedProvider = selectedProviderCredential() else {
                return nil
            }
            switch selectedProvider.providerKind {
            case .openAICompatible:
                return String(localized: "chat.menu.reasoning")
            case .anthropic, .googleGemini:
                return String(localized: "chat.menu.thinking")
            }
        }
    }

    override func tableView(_ tableView: UITableView, cellForRowAt indexPath: IndexPath) -> UITableViewCell {
        guard let section = Section(rawValue: indexPath.section) else {
            return UITableViewCell()
        }

        switch section {
        case .provider:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectModelConfigCell", for: indexPath)
            guard providers.indices.contains(indexPath.row) else {
                return cell
            }
            let provider = providers[indexPath.row]
            var configuration = cell.defaultContentConfiguration()
            configuration.text = providerTitle(for: provider)
            configuration.secondaryText = providerSubtitle(for: provider)
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.accessoryType = provider.providerID == state.selectedProviderID ? .checkmark : .none
            return cell

        case .model:
            let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectModelConfigCell", for: indexPath)
            guard let selectedProvider = selectedProviderCredential() else {
                return cell
            }
            let modelIDs = availableModelIDs(for: selectedProvider)
            guard modelIDs.indices.contains(indexPath.row) else {
                return cell
            }
            let modelID = modelIDs[indexPath.row]
            var configuration = cell.defaultContentConfiguration()
            configuration.text = modelID
            configuration.secondaryText = usedTokenCountText(
                modelTokenUsage(
                    providerID: selectedProvider.providerID,
                    modelID: modelID
                )
            )
            configuration.secondaryTextProperties.color = .secondaryLabel
            cell.contentConfiguration = configuration
            cell.accessoryType = modelID.caseInsensitiveCompare(selectedModelID(for: selectedProvider)) == .orderedSame
                ? .checkmark
                : .none
            return cell

        case .parameter:
            guard let selectedProvider = selectedProviderCredential() else {
                return UITableViewCell()
            }
            let selectedModelID = selectedModelID(for: selectedProvider)
            switch selectedProvider.providerKind {
            case .openAICompatible:
                let cell = tableView.dequeueReusableCell(withIdentifier: "ProjectModelConfigCell", for: indexPath)
                let profile = reasoningProfile(forModelID: selectedModelID, providerKind: .openAICompatible)
                let efforts = profile?.supported ?? []
                guard efforts.indices.contains(indexPath.row) else {
                    return cell
                }
                let effort = efforts[indexPath.row]
                var configuration = cell.defaultContentConfiguration()
                configuration.text = effort.displayName
                cell.contentConfiguration = configuration
                let currentEffort = selectedReasoningEffort(forModelID: selectedModelID, providerKind: .openAICompatible)
                cell.accessoryType = effort == currentEffort ? .checkmark : .none
                return cell

            case .anthropic, .googleGemini:
                guard
                    let cell = tableView.dequeueReusableCell(
                        withIdentifier: SettingsToggleCell.reuseIdentifier,
                        for: indexPath
                    ) as? SettingsToggleCell
                else {
                    return UITableViewCell()
                }
                let isOn: Bool
                switch selectedProvider.providerKind {
                case .anthropic:
                    isOn = selectedAnthropicThinkingEnabled(forModelID: selectedModelID)
                case .googleGemini:
                    isOn = selectedGeminiThinkingEnabled(forModelID: selectedModelID)
                case .openAICompatible:
                    isOn = true
                }
                cell.configure(
                    title: String(localized: "chat.menu.thinking"),
                    isOn: isOn
                ) { [weak self] value in
                    guard let self else { return }
                    let key = self.normalizedModelID(selectedModelID)
                    switch selectedProvider.providerKind {
                    case .anthropic:
                        self.state.selectedAnthropicThinkingEnabledByModelID[key] = value
                    case .googleGemini:
                        self.state.selectedGeminiThinkingEnabledByModelID[key] = value
                    case .openAICompatible:
                        break
                    }
                    self.notifySelectionChanged()
                }
                return cell
            }
        }
    }

    override func tableView(_ tableView: UITableView, willSelectRowAt indexPath: IndexPath) -> IndexPath? {
        guard let section = Section(rawValue: indexPath.section) else {
            return nil
        }
        switch section {
        case .provider, .model:
            return indexPath
        case .parameter:
            guard let selectedProvider = selectedProviderCredential() else {
                return nil
            }
            switch selectedProvider.providerKind {
            case .openAICompatible:
                return indexPath
            case .anthropic, .googleGemini:
                return nil
            }
        }
    }

    override func tableView(_ tableView: UITableView, didSelectRowAt indexPath: IndexPath) {
        defer { tableView.deselectRow(at: indexPath, animated: true) }
        guard let section = Section(rawValue: indexPath.section) else {
            return
        }
        switch section {
        case .provider:
            guard providers.indices.contains(indexPath.row) else {
                return
            }
            let selectedProvider = providers[indexPath.row]
            state.selectedProviderID = selectedProvider.providerID
            state.selectedModelIDByProviderID[selectedProvider.providerID] = selectedModelID(for: selectedProvider)
            notifySelectionChanged()
            tableView.reloadData()

        case .model:
            guard let selectedProvider = selectedProviderCredential() else {
                return
            }
            let modelIDs = availableModelIDs(for: selectedProvider)
            guard modelIDs.indices.contains(indexPath.row) else {
                return
            }
            let modelID = modelIDs[indexPath.row]
            state.selectedModelIDByProviderID[selectedProvider.providerID] = modelID
            if selectedProvider.providerKind == .openAICompatible {
                _ = selectedReasoningEffort(forModelID: modelID, providerKind: .openAICompatible)
            }
            notifySelectionChanged()
            tableView.reloadData()

        case .parameter:
            guard let selectedProvider = selectedProviderCredential() else {
                return
            }
            let selectedModelID = selectedModelID(for: selectedProvider)
            switch selectedProvider.providerKind {
            case .openAICompatible:
                guard
                    let profile = reasoningProfile(forModelID: selectedModelID, providerKind: .openAICompatible),
                    profile.supported.indices.contains(indexPath.row)
                else {
                    return
                }
                let selectedEffort = profile.supported[indexPath.row]
                state.selectedReasoningEffortsByModelID[normalizedModelID(selectedModelID)] = selectedEffort
                notifySelectionChanged()
                tableView.reloadSections(IndexSet(integer: Section.parameter.rawValue), with: .none)
            case .anthropic, .googleGemini:
                return
            }
        }
    }

    private func selectedProviderCredential() -> ProjectChatService.ProviderCredential? {
        if let credential = providers.first(where: { $0.providerID == state.selectedProviderID }) {
            return credential
        }
        return providers.first
    }

    private func selectedModelID(for provider: ProjectChatService.ProviderCredential) -> String {
        let remembered = state.selectedModelIDByProviderID[provider.providerID]?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if !remembered.isEmpty {
            return remembered
        }
        let fallback = provider.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        return fallback.isEmpty ? provider.providerKind.defaultModelID : fallback
    }

    private func availableModelIDs(for provider: ProjectChatService.ProviderCredential) -> [String] {
        var models = provider.providerKind.builtInModels
        let selected = selectedModelID(for: provider)
        if !selected.isEmpty, !models.contains(where: { $0.caseInsensitiveCompare(selected) == .orderedSame }) {
            models.insert(selected, at: 0)
        }
        let fallback = provider.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        if !fallback.isEmpty, !models.contains(where: { $0.caseInsensitiveCompare(fallback) == .orderedSame }) {
            models.insert(fallback, at: 0)
        }
        return models
    }

    private func providerTitle(for provider: ProjectChatService.ProviderCredential) -> String {
        let normalizedLabel = provider.providerLabel.trimmingCharacters(in: .whitespacesAndNewlines)
        return normalizedLabel.isEmpty ? provider.providerKind.displayName : normalizedLabel
    }

    private func reasoningProfile(
        forModelID modelID: String,
        providerKind: LLMProviderRecord.Kind
    ) -> (supported: [ProjectChatService.ReasoningEffort], defaultEffort: ProjectChatService.ReasoningEffort)? {
        guard providerKind == .openAICompatible else {
            return nil
        }
        let normalizedModel = normalizedModelID(modelID)
        if normalizedModel.contains("mini") {
            return (supported: [.low, .medium, .high], defaultEffort: .medium)
        }
        if normalizedModel.contains("pro") || normalizedModel.contains("codex") {
            return (supported: [.medium, .high, .xhigh], defaultEffort: .high)
        }
        return (supported: [.low, .medium, .high, .xhigh], defaultEffort: .high)
    }

    private func selectedReasoningEffort(
        forModelID modelID: String,
        providerKind: LLMProviderRecord.Kind
    ) -> ProjectChatService.ReasoningEffort {
        guard let profile = reasoningProfile(forModelID: modelID, providerKind: providerKind) else {
            return .high
        }
        let key = normalizedModelID(modelID)
        if let selected = state.selectedReasoningEffortsByModelID[key], profile.supported.contains(selected) {
            return selected
        }
        state.selectedReasoningEffortsByModelID[key] = profile.defaultEffort
        return profile.defaultEffort
    }

    private func selectedAnthropicThinkingEnabled(forModelID modelID: String) -> Bool {
        let key = normalizedModelID(modelID)
        if let selected = state.selectedAnthropicThinkingEnabledByModelID[key] {
            return selected
        }
        state.selectedAnthropicThinkingEnabledByModelID[key] = true
        return true
    }

    private func selectedGeminiThinkingEnabled(forModelID modelID: String) -> Bool {
        let key = normalizedModelID(modelID)
        if let selected = state.selectedGeminiThinkingEnabledByModelID[key] {
            return selected
        }
        state.selectedGeminiThinkingEnabledByModelID[key] = true
        return true
    }

    private func normalizedModelID(_ modelID: String) -> String {
        modelID.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }

    private func reloadUsageData() {
        usageRecords = usageStore.loadRecords(projectIdentifier: projectUsageIdentifier)
        usageByProviderID = Dictionary(
            grouping: usageRecords,
            by: { $0.providerID }
        ).mapValues { records in
            records.reduce(Int64(0)) { $0 + $1.totalTokens }
        }
        usageByProviderModel = Dictionary(
            uniqueKeysWithValues: usageRecords.map { record in
                (providerModelUsageKey(providerID: record.providerID, modelID: record.model), record.totalTokens)
            }
        )
        tableView.reloadData()
    }

    private func providerModelUsageKey(providerID: String, modelID: String) -> String {
        providerID.lowercased() + "|" + normalizedModelID(modelID)
    }

    private func providerTokenUsage(for providerID: String) -> Int64 {
        usageByProviderID[providerID] ?? 0
    }

    private func modelTokenUsage(providerID: String, modelID: String) -> Int64 {
        usageByProviderModel[providerModelUsageKey(providerID: providerID, modelID: modelID)] ?? 0
    }

    private func providerSubtitle(for provider: ProjectChatService.ProviderCredential) -> String {
        let providerKindName = provider.providerKind.displayName
        let usageText = usedTokenCountText(providerTokenUsage(for: provider.providerID))
        return String(
            format: String(localized: "providers.usage.detail.section.model_format"),
            providerKindName,
            usageText
        )
    }

    private func usedTokenCountText(_ value: Int64) -> String {
        let tokenCountText = formattedTokenCount(value)
        return String(format: String(localized: "providers.usage.used_tokens_format"), tokenCountText)
    }

    private func formattedTokenCount(_ value: Int64) -> String {
        let number = NSNumber(value: value)
        let formatted = numberFormatter.string(from: number) ?? "\(value)"
        return String(format: String(localized: "providers.usage.tokens_format"), formatted)
    }

    private func notifySelectionChanged() {
        refreshNavigationTitle()
        onSelectionStateChanged?(state)
    }

    private func refreshNavigationTitle() {
        guard let provider = selectedProviderCredential() else {
            title = String(localized: "chat.menu.model")
            return
        }
        title = providerTitle(for: provider) + "-" + selectedModelID(for: provider)
    }
}

@MainActor
final class ProjectTokenUsageViewController: TokenUsageDashboardViewController {
    init(projectUsageIdentifier: String) {
        super.init(
            titleText: String(localized: "chat.project_usage.title"),
            projectIdentifier: projectUsageIdentifier,
            includeDoneButton: true
        )
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
}
