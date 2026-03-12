//
//  ChatTaskCoordinator.swift
//  Doufu
//

import Foundation

/// Encapsulates the result of a successful chat task execution.
struct ChatTaskResult {
    let assistantMessage: String
    let changedPaths: [String]
    let updatedMemory: SessionMemory
    let requestTokenUsage: ProjectChatService.RequestTokenUsage?
    let toolActivitySummary: String?
    let toolMetadata: [AgentToolProvider.ToolResultMetadata]
}

/// Delegate that receives lifecycle callbacks from ``ChatTaskCoordinator``.
/// All methods are called on the main actor.
@MainActor
protocol ChatTaskCoordinatorDelegate: AnyObject {
    func coordinatorDidReceiveStreamedText(_ accumulatedText: String)
    func coordinatorDidReceiveProgressEvent(_ event: ToolProgressEvent)
    func coordinatorDidCompleteWithResult(_ result: ChatTaskResult)
    func coordinatorDidCancel()
    func coordinatorDidFailWithError(_ error: Error)
    /// Called once after every execution finishes (success, cancel, or failure).
    func coordinatorDidFinishExecution()
}

/// Coordinates a single LLM chat task, managing the `Task` reference and
/// orchestrating `ActiveTaskManager` / `PiPProgressManager` lifecycle calls.
@MainActor
final class ChatTaskCoordinator {

    struct Request {
        let userMessage: String
        let history: [ProjectChatService.ChatTurn]
        let sessionContext: ChatSessionContext
        let credential: ProjectChatService.ProviderCredential
        let memory: SessionMemory?
        let executionOptions: ProjectChatService.ModelExecutionOptions
        let confirmationHandler: ToolConfirmationHandler?
        let permissionMode: ToolPermissionMode
        let validationServerBaseURL: URL?
        let validationBridge: DoufuBridge?
    }

    weak var delegate: ChatTaskCoordinatorDelegate?

    private(set) var isExecuting = false

    private let orchestrator: ProjectChatOrchestrator
    private var task: Task<Void, Never>?
    private var didCancelCurrentRequest = false
    private var didNotifiedCancel = false

    init(orchestrator: ProjectChatOrchestrator = ProjectChatOrchestrator(configuration: .default)) {
        self.orchestrator = orchestrator
    }

    func execute(_ request: Request) {
        guard !isExecuting else { return }
        isExecuting = true
        didCancelCurrentRequest = false
        didNotifiedCancel = false

        let sessionID = request.sessionContext.projectID
        ActiveTaskManager.shared.taskDidStart(sessionID: sessionID)
        PiPProgressManager.shared.taskDidStart(sessionID: sessionID, projectName: request.sessionContext.projectName, projectURL: request.sessionContext.projectRootURL)

        // Strong self capture: the coordinator must stay alive until the
        // Task completes so that ActiveTaskManager/PiPProgressManager always
        // receive their balancing taskDidEnd call.
        task = Task {
            defer {
                self.task = nil
                self.didCancelCurrentRequest = false
                self.didNotifiedCancel = false
                self.isExecuting = false
                self.delegate?.coordinatorDidFinishExecution()
            }

            do {
                let result = try await self.orchestrator.sendAndApply(
                    userMessage: request.userMessage,
                    history: request.history,
                    sessionContext: request.sessionContext,
                    credential: request.credential,
                    memory: request.memory,
                    executionOptions: request.executionOptions,
                    confirmationHandler: request.confirmationHandler,
                    permissionMode: request.permissionMode,
                    validationServerBaseURL: request.validationServerBaseURL,
                    validationBridge: request.validationBridge,
                    onStreamedText: { [weak self] text in
                        self?.delegate?.coordinatorDidReceiveStreamedText(text)
                    },
                    onProgress: { [weak self] event in
                        guard let self else { return }
                        PiPProgressManager.shared.updateStatus(event.displayText, sessionID: sessionID)
                        self.delegate?.coordinatorDidReceiveProgressEvent(event)
                    }
                )

                let chatResult = ChatTaskResult(
                    assistantMessage: result.assistantMessage,
                    changedPaths: result.changedPaths,
                    updatedMemory: result.updatedMemory,
                    requestTokenUsage: result.requestTokenUsage,
                    toolActivitySummary: result.toolActivitySummary,
                    toolMetadata: result.toolMetadata
                )

                ActiveTaskManager.shared.taskDidEnd(sessionID: sessionID)
                PiPProgressManager.shared.taskDidComplete(sessionID: sessionID)
                self.delegate?.coordinatorDidCompleteWithResult(chatResult)
            } catch is CancellationError {
                ActiveTaskManager.shared.taskDidEnd(sessionID: sessionID)
                PiPProgressManager.shared.taskDidCancel(sessionID: sessionID)
                if !self.didNotifiedCancel {
                    self.didNotifiedCancel = true
                    self.delegate?.coordinatorDidCancel()
                }
            } catch {
                ActiveTaskManager.shared.taskDidEnd(sessionID: sessionID)
                if self.didCancelCurrentRequest {
                    PiPProgressManager.shared.taskDidCancel(sessionID: sessionID)
                    if !self.didNotifiedCancel {
                        self.didNotifiedCancel = true
                        self.delegate?.coordinatorDidCancel()
                    }
                } else {
                    PiPProgressManager.shared.taskDidFail(sessionID: sessionID, message: error.localizedDescription)
                    self.delegate?.coordinatorDidFailWithError(error)
                }
            }
        }
    }

    func cancel() {
        guard isExecuting else { return }
        didCancelCurrentRequest = true
        task?.cancel()
    }
}
