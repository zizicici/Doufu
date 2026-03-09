//
//  ChatTaskCoordinator.swift
//  Doufu
//

import Foundation

/// Encapsulates the result of a successful chat task execution.
struct ChatTaskResult {
    let assistantMessage: String
    let changedPaths: [String]
    let updatedMemory: ProjectChatService.SessionMemory
    let requestTokenUsage: ProjectChatService.RequestTokenUsage?
    let toolActivitySummary: String?
    let toolMetadata: [AgentToolProvider.ToolResultMetadata]
}

/// Delegate that receives lifecycle callbacks from ``ChatTaskCoordinator``.
/// All methods are called on the main actor.
@MainActor
protocol ChatTaskCoordinatorDelegate: AnyObject {
    func coordinatorDidReceiveStreamedText(_ chunk: String)
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
        let projectIdentifier: String
        let projectName: String
        let projectURL: URL
        let credential: ProjectChatService.ProviderCredential
        let memory: ProjectChatService.SessionMemory?
        let executionOptions: ProjectChatService.ModelExecutionOptions
        let confirmationHandler: ToolConfirmationHandler?
        let permissionMode: ToolPermissionMode
        let validationServerBaseURL: URL?
        let validationBridge: DoufuBridge?
    }

    weak var delegate: ChatTaskCoordinatorDelegate?

    private(set) var isExecuting = false

    private let chatService: ProjectChatService
    private var task: Task<Void, Never>?
    private var didCancelCurrentRequest = false
    private var didNotifiedCancel = false

    init(chatService: ProjectChatService) {
        self.chatService = chatService
    }

    func execute(_ request: Request) {
        guard !isExecuting else { return }
        isExecuting = true
        didCancelCurrentRequest = false
        didNotifiedCancel = false

        ActiveTaskManager.shared.taskDidStart()
        PiPProgressManager.shared.taskDidStart(projectName: request.projectName, projectURL: request.projectURL)

        task = Task { [weak self] in
            guard let self else { return }
            defer {
                self.task = nil
                self.didCancelCurrentRequest = false
                self.didNotifiedCancel = false
                self.isExecuting = false
                self.delegate?.coordinatorDidFinishExecution()
            }

            do {
                let result = try await self.chatService.sendAndApply(
                    userMessage: request.userMessage,
                    history: request.history,
                    projectIdentifier: request.projectIdentifier,
                    projectURL: request.projectURL,
                    credential: request.credential,
                    memory: request.memory,
                    executionOptions: request.executionOptions,
                    confirmationHandler: request.confirmationHandler,
                    permissionMode: request.permissionMode,
                    validationServerBaseURL: request.validationServerBaseURL,
                    validationBridge: request.validationBridge,
                    onStreamedText: { [weak self] chunk in
                        self?.delegate?.coordinatorDidReceiveStreamedText(chunk)
                    },
                    onProgress: { [weak self] event in
                        guard let self else { return }
                        PiPProgressManager.shared.updateStatus(event.displayText)
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

                ActiveTaskManager.shared.taskDidEnd()
                PiPProgressManager.shared.taskDidComplete()
                self.delegate?.coordinatorDidCompleteWithResult(chatResult)
            } catch is CancellationError {
                ActiveTaskManager.shared.taskDidEnd()
                PiPProgressManager.shared.taskDidCancel()
                if !self.didNotifiedCancel {
                    self.didNotifiedCancel = true
                    self.delegate?.coordinatorDidCancel()
                }
            } catch {
                ActiveTaskManager.shared.taskDidEnd()
                if self.didCancelCurrentRequest {
                    PiPProgressManager.shared.taskDidCancel()
                    if !self.didNotifiedCancel {
                        self.didNotifiedCancel = true
                        self.delegate?.coordinatorDidCancel()
                    }
                } else {
                    PiPProgressManager.shared.taskDidFail(error.localizedDescription)
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
