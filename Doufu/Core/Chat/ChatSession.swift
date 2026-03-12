//
//  ChatSession.swift
//  Doufu
//

import Foundation

/// Delegate protocol for ChatSession lifecycle events (execution finish,
/// thread switch, model change, errors).  Message-level UI updates are
/// delivered directly via ``ChatMessageStoreDelegate`` — see ``setUIObserver(_:)``.
@MainActor
protocol ChatSessionDelegate: AnyObject {
    // Execution lifecycle
    func sessionDidFinishExecution()
    // Thread/model changes
    func sessionDidSwitchThread()
    func sessionModelSelectionDidChange()
    // Errors
    func sessionDidEncounterError(_ error: Error)
}

/// Data needed by ModelConfigurationViewController, assembled by ChatSession.
@MainActor
struct ModelConfigurationContext {
    let initialState: ModelSelectionDraft
    let showsResetToDefaults: Bool
    let inheritedState: ModelSelectionDraft
    let inheritedStateProvider: () -> ModelSelectionDraft
}

/// Long-lived per-project chat session that owns all execution infrastructure.
/// Survives UI dismissal so that in-flight LLM requests complete and persist.
@MainActor
final class ChatSession {

    private final class PendingToolConfirmation {
        let toolName: String
        let tier: ToolPermissionTier
        let description: String
        let continuation: CheckedContinuation<Bool, Never>

        init(
            toolName: String,
            tier: ToolPermissionTier,
            description: String,
            continuation: CheckedContinuation<Bool, Never>
        ) {
            self.toolName = toolName
            self.tier = tier
            self.description = description
            self.continuation = continuation
        }
    }

    let projectID: String
    private(set) var project: AppProjectRecord
    private let dataService: ChatDataService
    private let messageStore: ChatMessageStore
    private let threadManager: ChatThreadManager
    private let modelSelection: ChatModelSelectionManager
    private let taskCoordinator: ChatTaskCoordinator

    weak var delegate: ChatSessionDelegate?

    /// Set via ``setUIObserver(_:)`` when the VC appears; cleared when it disappears.
    /// When nil, confirmations fall back to a session-level pending state that
    /// can be resumed the next time chat UI becomes available.
    private weak var activeConfirmationHandler: ToolConfirmationPresenter?
    private var pendingToolConfirmation: PendingToolConfirmation?
    private var pendingConfirmationPresentationTask: Task<Void, Never>?

    var onProjectFilesUpdated: (() -> Void)?

    /// When true, ``coordinatorDidFinishExecution()`` will **not** self-clean
    /// the session from the manager.  Set by ``ProjectLifecycleCoordinator``
    /// before cancelling, so that the coordinator retains control over when
    /// the session is removed.
    var suppressAutoEndSession = false

    /// Debounce window for coalescing rapid message persistence calls.
    private static let persistenceDebounceNanos: UInt64 = 500_000_000 // 0.5s
    private var persistenceDebounceTask: Task<Void, Never>?
    /// When true, the next `messageStoreDidMutateMessages` must flush
    /// immediately rather than scheduling a debounced write.
    private var needsImmediatePersistence = false

    /// Model selection reload task management (migrated from ChatViewController).
    private var modelSelectionReloadTask: Task<Void, Never>?
    private var pendingModelSelectionReload = false

    init(project: AppProjectRecord) {
        self.project = project
        self.projectID = project.id

        let dataService = ChatDataService(projectID: project.id)
        self.dataService = dataService

        let messageStore = ChatMessageStore()
        self.messageStore = messageStore

        // Temporary placeholder — replaced immediately after threadManager
        // is created below.  Safe because no code path calls
        // reloadModelSelectionContext() during init.
        let modelSelection = ChatModelSelectionManager(
            projectID: project.id,
            currentThreadIDProvider: { nil }
        )
        self.modelSelection = modelSelection

        let taskCoordinator = ChatTaskCoordinator()
        self.taskCoordinator = taskCoordinator

        let threadManager = ChatThreadManager(
            dataService: dataService,
            isExecutingProvider: { taskCoordinator.isExecuting }
        )
        self.threadManager = threadManager

        // Now that threadManager exists, wire up the real provider.
        modelSelection.currentThreadIDProvider = { [weak threadManager] in
            threadManager?.currentThread?.id
        }

        // Wire delegates — messageStore.delegate is set later via setUIObserver(_:)
        taskCoordinator.delegate = self
        messageStore.mutationDelegate = self
        threadManager.delegate = self
        modelSelection.delegate = self
    }

    // MARK: - UI Observer

    /// Sets (or clears) the UI observer that receives both session lifecycle
    /// events and message-store UI updates.  Call from `viewDidLoad` /
    /// `viewWillAppear` with `self`, and from `viewDidDisappear` with `nil`.
    func setUIObserver(_ observer: (ChatSessionDelegate & ChatMessageStoreDelegate & ToolConfirmationPresenter)?) {
        delegate = observer
        activeConfirmationHandler = observer
        messageStore.delegate = observer
    }

    // MARK: - Project Metadata

    func updateProject(_ updatedProject: AppProjectRecord) {
        self.project = updatedProject
    }

    // MARK: - Execution State

    var isExecuting: Bool { taskCoordinator.isExecuting }

    func cancelExecution() {
        activeConfirmationHandler?.cancelPendingToolConfirmationPresentation()
        cancelPendingToolConfirmationIfNeeded()
        taskCoordinator.cancel()
    }

    /// Cancels the current execution and suspends until the task fully completes.
    func cancelAndAwaitCompletion() async {
        cancelExecution()
        await taskCoordinator.awaitCompletion()
    }

    // MARK: - Thread State (for UI)

    var currentThreadTitle: String? { threadManager.currentThread?.title }
    var currentThreadID: String? { threadManager.currentThread?.id }
    var hasThread: Bool { threadManager.currentThread != nil }
    var threadList: [ProjectChatThreadRecord] { threadManager.threadIndex?.threads ?? [] }

    func switchThread(threadID: String) {
        threadManager.handleSwitchThread(threadID: threadID)
    }

    func createNewThread() {
        threadManager.createAndSwitchThread()
    }

    // MARK: - Model Selection State (for UI)

    var canSend: Bool { modelSelection.canSend }
    var hasConfiguredProviders: Bool { modelSelection.hasConfiguredProviders }
    var statusPrompt: String? { modelSelection.currentStatusPrompt() }
    var modelButtonTitle: String { modelSelection.currentModelMenuButtonTitle() }

    func sendBlockedMessage() -> String? {
        modelSelection.sendBlockedMessage()
    }

    /// Prepares the data needed by ModelConfigurationViewController.
    /// Returns `nil` when no providers are configured — the caller should
    /// show an error instead.
    func prepareModelConfiguration() -> ModelConfigurationContext? {
        let credentials = modelSelection.resolveProviderCredentials()
        modelSelection.refreshWithResolvedCredentials(credentials)
        guard modelSelection.hasConfiguredProviders else {
            Task { [weak self] in
                await self?.reloadModelSelectionContext()
            }
            return nil
        }

        return ModelConfigurationContext(
            initialState: modelSelection.selectionSnapshot,
            showsResetToDefaults: modelSelection.hasThreadOverride,
            inheritedState: modelSelection.inheritedSnapshot,
            inheritedStateProvider: { [weak modelSelection] in
                modelSelection?.inheritedSnapshot ?? .empty
            }
        )
    }

    func applyModelSelection(_ state: ModelSelectionDraft) -> SelectionApplyOutcome {
        modelSelection.applySelectionState(state)
    }

    func resetModelSelectionToDefaults() -> ModelSelectionDraft {
        modelSelection.resetToDefaults()
        return modelSelection.selectionSnapshot
    }

    // MARK: - Model Selection Reload

    func reloadModelSelectionContext() async {
        if let reloadTask = modelSelectionReloadTask {
            pendingModelSelectionReload = true
            await reloadTask.value
            return
        }

        let reloadTask = Task { [weak self] in
            guard let self else { return }
            repeat {
                self.pendingModelSelectionReload = false
                await self.modelSelection.reloadModelSelectionContext()
            } while self.pendingModelSelectionReload && !Task.isCancelled
            self.modelSelectionReloadTask = nil
        }
        modelSelectionReloadTask = reloadTask
        await reloadTask.value
    }

    func cancelModelRefresh() {
        modelSelection.cancelRefreshTask()
        modelSelectionReloadTask?.cancel()
        modelSelectionReloadTask = nil
        pendingModelSelectionReload = false
    }

    // MARK: - Pending Tool Confirmation

    func resumePendingToolConfirmationIfPossible() {
        guard pendingConfirmationPresentationTask == nil,
              let handler = activeConfirmationHandler,
              pendingToolConfirmation != nil
        else { return }

        pendingConfirmationPresentationTask = Task { @MainActor [weak self, weak handler] in
            guard let self else { return }
            guard let handler, let pending = self.pendingToolConfirmation else {
                self.pendingConfirmationPresentationTask = nil
                return
            }

            let decision = await handler.presentToolConfirmation(
                toolName: pending.toolName,
                tier: pending.tier,
                description: pending.description
            )
            self.pendingConfirmationPresentationTask = nil
            self.handlePendingToolConfirmationDecision(decision)
        }
    }

    private func suspendUntilToolConfirmationResolved(
        toolName: String,
        tier: ToolPermissionTier,
        description: String
    ) async -> Bool {
        guard pendingToolConfirmation == nil else {
            assertionFailure("Tool confirmation was already pending for project \(projectID)")
            return false
        }

        ProjectActivityStore.shared.setNeedsConfirmation(projectID: projectID)
        PiPProgressManager.shared.setNeedsUserAction(sessionID: projectID)

        return await withCheckedContinuation { continuation in
            pendingToolConfirmation = PendingToolConfirmation(
                toolName: toolName,
                tier: tier,
                description: description,
                continuation: continuation
            )
            resumePendingToolConfirmationIfPossible()
        }
    }

    private func handlePendingToolConfirmationDecision(_ decision: ToolConfirmationDecision) {
        guard let pending = pendingToolConfirmation else { return }

        switch decision {
        case .approved:
            pendingToolConfirmation = nil
            ProjectActivityStore.shared.taskDidStart(projectID: projectID)
            PiPProgressManager.shared.clearNeedsUserAction(sessionID: projectID)
            pending.continuation.resume(returning: true)
        case .denied:
            pendingToolConfirmation = nil
            ProjectActivityStore.shared.taskDidStart(projectID: projectID)
            PiPProgressManager.shared.clearNeedsUserAction(sessionID: projectID)
            pending.continuation.resume(returning: false)
        case .deferred:
            ProjectActivityStore.shared.setNeedsConfirmation(projectID: projectID)
            PiPProgressManager.shared.setNeedsUserAction(sessionID: projectID)
        }
    }

    private func cancelPendingToolConfirmationIfNeeded() {
        pendingConfirmationPresentationTask = nil
        guard let pending = pendingToolConfirmation else { return }
        pendingToolConfirmation = nil
        PiPProgressManager.shared.clearNeedsUserAction(sessionID: projectID)
        pending.continuation.resume(returning: false)
    }

    // MARK: - Messages (for UI)

    var messages: [ChatMessage] { messageStore.messages }

    @discardableResult
    func appendUserMessage(_ text: String) -> Int? {
        messageStore.appendMessage(role: .user, text: text)
    }

    // MARK: - Execution

    /// Builds and executes an LLM chat request from the current session state.
    /// The caller is responsible for appending the user message to the message
    /// store before calling this method.
    func sendMessage(
        _ userMessage: String,
        toolPermissionMode: ToolPermissionMode,
        validationServerBaseURL: URL?,
        validationBridge: DoufuBridge?
    ) {
        guard !taskCoordinator.isExecuting else { return }

        // Auto-create initial thread on first send.
        if threadManager.currentThread == nil {
            do {
                try threadManager.createInitialThread()
                delegate?.sessionDidSwitchThread()
            } catch {
                delegate?.sessionDidEncounterError(error)
                return
            }
        }

        guard modelSelection.canSend,
              let baseCredential = modelSelection.providerCredential
        else { return }

        let credential = modelSelection.runtimeCredential(from: baseCredential)
        let historyTurns = messageStore.buildHistoryTurns()
        messageStore.beginRequest(startedAt: Date())

        let sessionContext = ChatSessionContext(
            projectID: projectID,
            workspaceURL: project.appURL,
            projectRootURL: project.projectURL,
            projectName: project.name
        )
        let request = ChatTaskCoordinator.Request(
            userMessage: userMessage,
            history: historyTurns,
            sessionContext: sessionContext,
            credential: credential,
            memory: threadManager.sessionMemory,
            executionOptions: modelSelection.executionOptions(for: credential),
            confirmationHandler: self,
            permissionMode: toolPermissionMode,
            validationServerBaseURL: validationServerBaseURL,
            validationBridge: validationBridge
        )
        taskCoordinator.execute(request)
    }

    // MARK: - Thread Management

    func renameThread(threadID: String, newTitle: String) throws {
        try threadManager.renameThread(threadID: threadID, newTitle: newTitle)
    }

    func deleteThread(threadID: String) throws {
        guard !taskCoordinator.isExecuting else { return }
        try threadManager.deleteThread(threadID: threadID)
    }

    func reorderThreads(orderedIDs: [String]) throws {
        try threadManager.reorderThreads(orderedIDs: orderedIDs)
    }

    // MARK: - Initial Load

    func restoreThreadStateIfNeeded() throws {
        // Skip if execution is in progress — the thread and messages are
        // already set up from when the request was started.  Calling
        // replaceMessages mid-execution would corrupt the flow state machine.
        guard !taskCoordinator.isExecuting else { return }
        try threadManager.restoreThreadStateIfNeeded()
    }
}

// MARK: - ToolConfirmationHandler (proxy)

extension ChatSession: ToolConfirmationHandler {
    func confirmToolAction(
        toolName: String,
        tier: ToolPermissionTier,
        description: String
    ) async -> Bool {
        switch tier {
        case .autoAllow:
            return true
        case .confirmOnce, .alwaysConfirm:
            break
        }

        if let handler = activeConfirmationHandler {
            let decision = await handler.presentToolConfirmation(
                toolName: toolName,
                tier: tier,
                description: description
            )
            switch decision {
            case .approved:
                return true
            case .denied:
                return false
            case .deferred:
                break
            }
        }

        if Task.isCancelled {
            return false
        }

        return await suspendUntilToolConfirmationResolved(
            toolName: toolName,
            tier: tier,
            description: description
        )
    }
}

// MARK: - ChatTaskCoordinatorDelegate

extension ChatSession: ChatTaskCoordinatorDelegate {
    func coordinatorDidReceiveStreamedText(_ accumulatedText: String) {
        messageStore.receiveStreamedText(accumulatedText)
    }

    func coordinatorDidReceiveProgressEvent(_ event: ToolProgressEvent) {
        messageStore.receiveProgressEvent(event)
    }

    func coordinatorDidCompleteWithResult(_ result: ChatTaskResult) {
        guard threadManager.currentThread != nil else { return }

        threadManager.updateSessionMemory(result.updatedMemory)
        if let threadID = threadManager.currentThread?.id {
            try? dataService.persistSessionMemory(threadManager.sessionMemory, threadID: threadID)
        }

        var assistantText = result.assistantMessage
        if !result.changedPaths.isEmpty {
            let changesSummary = result.changedPaths.joined(separator: ", ")
            assistantText += String(
                format: String(localized: "chat.system.files_updated.append_format"),
                changesSummary
            )
        }

        // Mark for immediate persistence — completeWithResult finalizes
        // the assistant message and its mutation must be flushed at once.
        needsImmediatePersistence = true
        messageStore.completeWithResult(
            text: assistantText,
            requestTokenUsage: result.requestTokenUsage,
            toolSummary: result.toolActivitySummary
        )

        threadManager.touchCurrentThread()

        if !result.changedPaths.isEmpty {
            onProjectFilesUpdated?()
        }
    }

    func coordinatorDidCancel() {
        needsImmediatePersistence = true
        messageStore.handleCancellation()
    }

    func coordinatorDidFailWithError(_ error: Error) {
        needsImmediatePersistence = true
        messageStore.handleError(error)
    }

    func coordinatorDidFinishExecution() {
        needsImmediatePersistence = true
        messageStore.finishExecution()
        delegate?.sessionDidFinishExecution()

        // If no UI is observing (workspace was dismissed during execution),
        // clean up this session from the manager to prevent a memory leak.
        // Skip when the coordinator has explicitly suppressed auto-cleanup
        // (e.g. during a managed deleteProject flow).
        if delegate == nil && !suppressAutoEndSession {
            onProjectFilesUpdated = nil
            ChatSessionManager.shared.endSession(projectID: projectID)
        }
    }
}

// MARK: - ChatMessageStoreMutationDelegate

extension ChatSession: ChatMessageStoreMutationDelegate {
    func messageStoreDidMutateMessages() {
        guard threadManager.currentThread != nil else { return }

        // Certain call sites (completeWithResult, handleCancellation,
        // handleError, finishExecution) mark the mutation as requiring
        // an immediate flush — skip debouncing for those.
        if needsImmediatePersistence {
            needsImmediatePersistence = false
            persistenceDebounceTask?.cancel()
            persistenceDebounceTask = nil
            performMessagePersistence()
            return
        }

        // Debounce: cancel any previously scheduled write and reschedule.
        // This coalesces rapid successive mutations (e.g. appendMessage
        // followed immediately by completeWithResult) into a single write.
        persistenceDebounceTask?.cancel()
        persistenceDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.persistenceDebounceNanos)
            guard !Task.isCancelled, let self else { return }
            self.performMessagePersistence()
        }
    }

    /// Persists all current-thread state: messages, session memory, and
    /// model selection.  Called before thread switches to guarantee nothing
    /// is lost.
    private func persistFullState() {
        guard let threadID = threadManager.currentThread?.id else { return }
        flushPendingPersistence()
        do {
            try dataService.persistMessages(messageStore.messages, threadID: threadID)
            try dataService.persistSessionMemory(threadManager.sessionMemory, threadID: threadID)
        } catch {
            delegate?.sessionDidEncounterError(error)
        }
        modelSelection.persistCurrentModelSelection()
    }

    /// Flush any pending debounced persistence immediately.
    /// Must be called before thread switches or session teardown to avoid
    /// data loss.
    func flushPendingPersistence() {
        guard persistenceDebounceTask != nil else { return }
        persistenceDebounceTask?.cancel()
        persistenceDebounceTask = nil
        performMessagePersistence()
    }

    private func performMessagePersistence() {
        guard let threadID = threadManager.currentThread?.id else { return }
        do {
            try dataService.persistMessagesIncrementally(messageStore.messages, threadID: threadID)
        } catch {
            delegate?.sessionDidEncounterError(error)
        }
    }
}

// MARK: - ChatThreadManagerDelegate

extension ChatSession: ChatThreadManagerDelegate {
    func threadManagerWillSwitchThread() {
        persistFullState()
    }

    func threadManagerDidLoadThread(messages: [ChatMessage], memory: SessionMemory?) {
        modelSelection.reloadModelSelectionContext(triggerModelRefresh: false)
        messageStore.replaceMessages(messages)
    }

    func threadManagerDidSwitchThread() {
        delegate?.sessionDidSwitchThread()
    }

    func threadManagerDidEncounterError(_ error: Error) {
        delegate?.sessionDidEncounterError(error)
    }
}

// MARK: - ChatModelSelectionManagerDelegate

extension ChatSession: ChatModelSelectionManagerDelegate {
    func modelSelectionDidChange() {
        delegate?.sessionModelSelectionDidChange()
    }
}
