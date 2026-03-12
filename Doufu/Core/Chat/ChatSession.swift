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

/// Long-lived per-project chat session that owns all execution infrastructure.
/// Survives UI dismissal so that in-flight LLM requests complete and persist.
@MainActor
final class ChatSession {

    let projectID: String
    private(set) var project: AppProjectRecord
    let dataService: ChatDataService
    let messageStore: ChatMessageStore
    let threadManager: ChatThreadManager
    let modelSelection: ChatModelSelectionManager
    let taskCoordinator: ChatTaskCoordinator

    weak var delegate: ChatSessionDelegate?

    /// Set via ``setUIObserver(_:)`` when the VC appears; cleared when it disappears.
    /// When nil, the session uses a fallback that auto-allows autoAllow tier
    /// and rejects everything else.
    private weak var activeConfirmationHandler: ToolConfirmationHandler?

    var onProjectFilesUpdated: (() -> Void)?

    /// Debounce window for coalescing rapid message persistence calls.
    private static let persistenceDebounceNanos: UInt64 = 500_000_000 // 0.5s
    private var persistenceDebounceTask: Task<Void, Never>?
    /// When true, the next `messageStoreDidMutateMessages` must flush
    /// immediately rather than scheduling a debounced write.
    private var needsImmediatePersistence = false

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
            messageStore: messageStore,
            modelSelection: modelSelection,
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
    func setUIObserver(_ observer: (ChatSessionDelegate & ChatMessageStoreDelegate & ToolConfirmationHandler)?) {
        delegate = observer
        activeConfirmationHandler = observer
        messageStore.delegate = observer
    }

    // MARK: - Project Metadata

    func updateProject(_ updatedProject: AppProjectRecord) {
        self.project = updatedProject
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
        guard threadManager.currentThread != nil else { return }
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
        if let handler = activeConfirmationHandler {
            return await handler.confirmToolAction(
                toolName: toolName,
                tier: tier,
                description: description
            )
        }
        // Fallback when UI is dismissed: auto-allow safe actions, reject the rest
        switch tier {
        case .autoAllow:
            return true
        case .confirmOnce, .alwaysConfirm:
            return false
        }
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
        if delegate == nil {
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
    func threadManagerWillPersistCurrentState() {
        // Cancel any pending debounced write — the thread manager
        // is about to perform a full persistence itself.
        persistenceDebounceTask?.cancel()
        persistenceDebounceTask = nil
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
