//
//  ChatSession.swift
//  Doufu
//

import Foundation

/// Delegate protocol for observing ChatSession events from the UI layer.
/// All methods are called on the main actor.
@MainActor
protocol ChatSessionObservationDelegate: AnyObject {
    // Message UI updates
    func sessionDidInsertMessage(at index: Int)
    func sessionDidUpdateMessage(at index: Int, message: ChatMessage)
    func sessionDidUpdateStreamingText(at index: Int, text: String)
    func sessionDidRequestBatchUpdate()
    func sessionDidRequestScroll(force: Bool)
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
    let project: AppProjectRecord
    let dataService: ChatDataService
    let messageStore: ChatMessageStore
    let threadSession: ChatThreadSessionManager
    let modelSelection: ChatModelSelectionManager
    let taskCoordinator: ChatTaskCoordinator

    weak var observationDelegate: ChatSessionObservationDelegate?

    /// Set by the VC when it appears; cleared when it disappears.
    /// When nil, the session uses a fallback that auto-allows autoAllow tier
    /// and rejects everything else.
    weak var activeConfirmationHandler: ToolConfirmationHandler?

    var onProjectFilesUpdated: (() -> Void)?

    init(project: AppProjectRecord) {
        self.project = project
        self.projectID = project.id

        let dataService = ChatDataService(projectID: project.id)
        self.dataService = dataService

        let messageStore = ChatMessageStore()
        self.messageStore = messageStore

        let modelSelection = ChatModelSelectionManager(
            projectID: project.id,
            currentThreadIDProvider: { nil } // set below after threadSession init
        )
        self.modelSelection = modelSelection

        let taskCoordinator = ChatTaskCoordinator()
        self.taskCoordinator = taskCoordinator

        let threadSession = ChatThreadSessionManager(
            dataService: dataService,
            messageStore: messageStore,
            modelSelection: modelSelection,
            isExecutingProvider: { taskCoordinator.isExecuting }
        )
        self.threadSession = threadSession

        // Wire up currentThreadIDProvider now that threadSession exists
        modelSelection.currentThreadIDProvider = { [weak threadSession] in
            threadSession?.currentThread?.id
        }

        // Wire delegates
        taskCoordinator.delegate = self
        messageStore.delegate = self
        messageStore.mutationDelegate = self
        threadSession.delegate = self
        modelSelection.delegate = self
    }

    // MARK: - Execution

    func execute(_ request: ChatTaskCoordinator.Request) {
        taskCoordinator.execute(request)
    }

    // MARK: - Initial Load

    func restoreThreadStateIfNeeded() throws {
        // Skip if execution is in progress — the thread and messages are
        // already set up from when the request was started.  Calling
        // replaceMessages mid-execution would corrupt the flow state machine.
        guard !taskCoordinator.isExecuting else { return }
        try threadSession.restoreThreadStateIfNeeded()
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
        observationDelegate?.sessionDidFinishExecution()

        // If no UI is observing (workspace was dismissed during execution),
        // clean up this session from the manager to prevent a memory leak.
        if observationDelegate == nil {
            onProjectFilesUpdated = nil
            ChatSessionManager.shared.endSession(projectID: projectID)
        }
    }
}

// MARK: - ChatMessageStoreDelegate

extension ChatSession: ChatMessageStoreDelegate {
    func messageStoreDidInsertRow(at index: Int) {
        observationDelegate?.sessionDidInsertMessage(at: index)
    }

    func messageStoreDidUpdateCell(at index: Int, message: ChatMessage) {
        observationDelegate?.sessionDidUpdateMessage(at: index, message: message)
    }

    func messageStoreDidUpdateStreamingText(at index: Int, text: String) {
        observationDelegate?.sessionDidUpdateStreamingText(at: index, text: text)
    }

    func messageStoreDidRequestBatchUpdate() {
        observationDelegate?.sessionDidRequestBatchUpdate()
    }

    func messageStoreDidRequestScroll(force: Bool) {
        observationDelegate?.sessionDidRequestScroll(force: force)
    }
}

// MARK: - ChatMessageStoreMutationDelegate

extension ChatSession: ChatMessageStoreMutationDelegate {
    func messageStoreDidMutateMessages() {
        guard let threadID = threadSession.currentThread?.id else { return }
        do {
            try dataService.persistMessages(messageStore.messages, threadID: threadID)
        } catch {
            observationDelegate?.sessionDidEncounterError(error)
        }
    }
}

// MARK: - ChatThreadSessionManagerDelegate

extension ChatSession: ChatThreadSessionManagerDelegate {
    func threadSessionDidSwitchThread() {
        observationDelegate?.sessionDidSwitchThread()
    }

    func threadSessionDidEncounterError(_ error: Error) {
        observationDelegate?.sessionDidEncounterError(error)
    }
}

// MARK: - ChatModelSelectionManagerDelegate

extension ChatSession: ChatModelSelectionManagerDelegate {
    func modelSelectionDidChange() {
        observationDelegate?.sessionModelSelectionDidChange()
    }
}
