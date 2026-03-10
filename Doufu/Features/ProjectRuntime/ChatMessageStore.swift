//
//  ChatMessageStore.swift
//  Doufu
//

import UIKit

@MainActor
protocol ChatMessageStoreDelegate: AnyObject {
    func messageStoreDidInsertRow(at index: Int)
    func messageStoreDidUpdateCell(at index: Int, message: ChatMessage)
    func messageStoreDidUpdateStreamingText(at index: Int, text: String)
    func messageStoreDidRequestBatchUpdate()
    func messageStoreDidRequestScroll(force: Bool)
}

@MainActor
final class ChatMessageStore {

    // MARK: - Flow State Machine

    /// The single source of truth for the active message lifecycle.
    /// Invariant: while not `.idle`, exactly one message has `finishedAt == nil`.
    enum FlowState: Equatable {
        /// No active request — all messages are finalized.
        case idle
        /// A tool‐progress cell is the live message.
        case progress(messageIndex: Int)
        /// A streaming‐text cell is the live message.
        case streaming(messageIndex: Int)
    }

    private(set) var flowState: FlowState = .idle

    weak var delegate: ChatMessageStoreDelegate?

    private(set) var messages: [ChatMessage] = []

    /// Timestamp when the current request started (used for cancel/error messages).
    private var requestStartedAt: Date?

    private var didAppendCancelMessage = false
    private var lastProgressPhaseText: String?
    private var progressDebounceWorkItem: DispatchWorkItem?
    private var streamRefreshWorkItem: DispatchWorkItem?

    private let threadStore: ProjectChatThreadStore
    private let projectURL: URL
    private let currentThreadIDProvider: () -> String?

    init(
        threadStore: ProjectChatThreadStore,
        projectURL: URL,
        currentThreadIDProvider: @escaping () -> String?
    ) {
        self.threadStore = threadStore
        self.projectURL = projectURL
        self.currentThreadIDProvider = currentThreadIDProvider
    }

    // MARK: - Request Lifecycle

    /// Called by the VC right before `taskCoordinator.execute(...)`.
    func beginRequest(startedAt: Date) {
        requestStartedAt = startedAt
        didAppendCancelMessage = false
        lastProgressPhaseText = nil
        // flowState should already be .idle here; enforce it.
        flowState = .idle
    }

    // MARK: - Incoming Events (State Machine Inputs)

    /// Receive a tool progress event from the coordinator.
    /// Formats the event text and transitions to `.progress`.
    func receiveProgressEvent(_ event: ToolProgressEvent) {
        let displayText = Self.formatProgressEvent(event)
        let normalized = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        // Dedup: skip if the text is identical to the current progress.
        guard normalized != lastProgressPhaseText else { return }

        // Cancel any pending debounced transition.
        progressDebounceWorkItem?.cancel()

        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            self.transitionToProgress(text: normalized)
        }
        progressDebounceWorkItem = workItem
        // During the 50ms window, the OLD live cell stays live — no gap.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: workItem)
    }

    /// Receive a chunk of streamed text from the LLM.
    func receiveStreamedText(_ chunk: String) {
        let trimmed = chunk.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Cancel any pending progress transition — streaming takes priority
        // when they race (the LLM started outputting text).
        progressDebounceWorkItem?.cancel()
        progressDebounceWorkItem = nil

        switch flowState {
        case .idle:
            let index = insertLiveMessage(role: .assistant, text: trimmed, isProgress: false, startedAt: Date())
            flowState = .streaming(messageIndex: index)

        case .progress(let oldIndex):
            // Atomic transition: finalize progress → create streaming.
            let now = Date()
            finalizeMessage(at: oldIndex, finishedAt: now)
            let newIndex = insertLiveMessage(role: .assistant, text: trimmed, isProgress: false, startedAt: now)
            flowState = .streaming(messageIndex: newIndex)

        case .streaming(let index):
            // Same cell — just update text.
            messages[index].text = trimmed
            scheduleStreamedCellRefresh(at: index)
        }
    }

    /// Called when the coordinator completes successfully.
    /// Finalizes the active cell or promotes streaming to the final assistant message.
    func completeWithResult(
        text: String,
        requestTokenUsage: ProjectChatService.RequestTokenUsage?,
        toolSummary: String?
    ) {
        cancelPendingWorkItems()
        let now = Date()
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)

        switch flowState {
        case .streaming(let index):
            // Promote the streaming cell to the final assistant message.
            if !normalizedText.isEmpty {
                messages[index].text = normalizedText
            }
            messages[index].finishedAt = now
            messages[index].requestTokenUsage = requestTokenUsage
            messages[index].toolSummary = toolSummary
            delegate?.messageStoreDidUpdateCell(at: index, message: messages[index])
            delegate?.messageStoreDidRequestBatchUpdate()

        case .progress(let index):
            // Finalize the progress cell, then insert a separate final assistant message.
            finalizeMessage(at: index, finishedAt: now)
            if !normalizedText.isEmpty {
                appendMessage(
                    role: .assistant,
                    text: normalizedText,
                    startedAt: requestStartedAt,
                    finishedAt: now,
                    requestTokenUsage: requestTokenUsage,
                    toolSummary: toolSummary
                )
            }

        case .idle:
            // No streaming/progress happened (very fast response).
            if !normalizedText.isEmpty {
                appendMessage(
                    role: .assistant,
                    text: normalizedText,
                    startedAt: requestStartedAt,
                    finishedAt: now,
                    requestTokenUsage: requestTokenUsage,
                    toolSummary: toolSummary
                )
            }
        }

        flowState = .idle
    }

    /// Called when the coordinator reports cancellation.
    func handleCancellation() {
        cancelPendingWorkItems()
        let now = Date()

        finalizeActiveFlowCell(finishedAt: now)

        if !didAppendCancelMessage {
            appendMessage(
                role: .system,
                text: String(localized: "chat.system.request_cancelled"),
                startedAt: requestStartedAt
            )
            didAppendCancelMessage = true
        }

        flowState = .idle
    }

    /// Called when the coordinator reports an error.
    func handleError(_ error: Error) {
        cancelPendingWorkItems()
        let now = Date()

        finalizeActiveFlowCell(finishedAt: now)

        appendMessage(
            role: .system,
            text: error.localizedDescription,
            startedAt: requestStartedAt
        )

        flowState = .idle
    }

    /// Called once after every execution finishes (success, cancel, or error).
    /// Safety net: stamps any remaining open messages and resets all state.
    func finishExecution() {
        cancelPendingWorkItems()
        let now = Date()

        // Finalize via state machine first.
        finalizeActiveFlowCell(finishedAt: now)

        // Safety net: any orphaned messages with finishedAt == nil.
        for i in messages.indices where messages[i].finishedAt == nil {
            messages[i].finishedAt = now
            delegate?.messageStoreDidUpdateCell(at: i, message: messages[i])
        }

        flowState = .idle
        requestStartedAt = nil
        didAppendCancelMessage = false
        lastProgressPhaseText = nil
    }

    // MARK: - User / System Messages (outside the flow state machine)

    /// Append a user or system message. These are immediately finalized.
    @discardableResult
    func appendMessage(
        role: ChatMessage.Role,
        text: String,
        isProgress: Bool = false,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        requestTokenUsage: ProjectChatService.RequestTokenUsage? = nil,
        toolSummary: String? = nil
    ) -> Int? {
        let normalizedText = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedText.isEmpty else { return nil }

        let createdAt = Date()
        let startedAt = startedAt ?? createdAt
        let resolvedFinishedAt = finishedAt ?? (isProgress ? nil : createdAt)

        messages.append(
            ChatMessage(
                role: role,
                text: normalizedText,
                createdAt: createdAt,
                startedAt: startedAt,
                finishedAt: resolvedFinishedAt,
                isProgress: isProgress,
                requestTokenUsage: requestTokenUsage,
                toolSummary: toolSummary
            )
        )
        let newIndex = messages.count - 1
        delegate?.messageStoreDidInsertRow(at: newIndex)
        delegate?.messageStoreDidRequestScroll(force: false)
        return newIndex
    }

    // MARK: - History / Persistence

    func buildHistoryTurns() -> [ProjectChatService.ChatTurn] {
        messages.compactMap { message in
            let normalizedText = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalizedText.isEmpty else { return nil }
            switch message.role {
            case .user:
                return .init(id: message.id.uuidString, role: .user, text: normalizedText)
            case .assistant:
                if message.isProgress { return nil }
                return .init(id: message.id.uuidString, role: .assistant, text: normalizedText, toolSummary: message.toolSummary)
            case .system:
                return nil
            }
        }
    }

    func persistMessages() {
        guard let threadID = currentThreadIDProvider() else { return }
        let persisted = messages.compactMap { message -> ProjectChatPersistedMessage? in
            let text = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return nil }
            return ProjectChatPersistedMessage(
                role: message.role.rawValue,
                text: text,
                createdAt: message.createdAt,
                startedAt: message.startedAt,
                finishedAt: message.finishedAt,
                isProgress: message.isProgress,
                inputTokens: message.requestTokenUsage?.inputTokens,
                outputTokens: message.requestTokenUsage?.outputTokens,
                toolSummary: message.toolSummary
            )
        }
        threadStore.saveMessages(projectURL: projectURL, threadID: threadID, messages: persisted)
    }

    func replaceMessages(_ newMessages: [ChatMessage]) {
        messages = newMessages
        flowState = .idle
    }

    // MARK: - Private — State Transitions

    /// Atomic transition to `.progress`. Finalizes the current live cell first.
    private func transitionToProgress(text: String) {
        let now = Date()

        // Finalize whatever is currently live.
        finalizeActiveFlowCell(finishedAt: now)

        lastProgressPhaseText = text
        let newIndex = insertLiveMessage(role: .assistant, text: text, isProgress: true, startedAt: now)
        flowState = .progress(messageIndex: newIndex)
    }

    /// Insert a message with `finishedAt == nil` (live cell).
    @discardableResult
    private func insertLiveMessage(
        role: ChatMessage.Role,
        text: String,
        isProgress: Bool,
        startedAt: Date
    ) -> Int {
        let createdAt = Date()
        messages.append(
            ChatMessage(
                role: role,
                text: text,
                createdAt: createdAt,
                startedAt: startedAt,
                finishedAt: nil,
                isProgress: isProgress,
                requestTokenUsage: nil,
                toolSummary: nil
            )
        )
        let newIndex = messages.count - 1
        delegate?.messageStoreDidInsertRow(at: newIndex)
        delegate?.messageStoreDidRequestScroll(force: false)
        return newIndex
    }

    /// Set `finishedAt` on the message at `index` and notify the delegate.
    private func finalizeMessage(at index: Int, finishedAt: Date) {
        guard messages[index].finishedAt == nil else { return }
        messages[index].finishedAt = finishedAt
        delegate?.messageStoreDidUpdateCell(at: index, message: messages[index])
        delegate?.messageStoreDidRequestBatchUpdate()
    }

    /// Finalize the cell tracked by the current `flowState`, if any.
    private func finalizeActiveFlowCell(finishedAt: Date) {
        switch flowState {
        case .idle:
            break
        case .progress(let index):
            finalizeMessage(at: index, finishedAt: finishedAt)
        case .streaming(let index):
            finalizeMessage(at: index, finishedAt: finishedAt)
        }
    }

    private func cancelPendingWorkItems() {
        progressDebounceWorkItem?.cancel()
        progressDebounceWorkItem = nil
        streamRefreshWorkItem?.cancel()
        streamRefreshWorkItem = nil
    }

    /// Coalesces rapid streaming updates into a single cell refresh (100ms window).
    private func scheduleStreamedCellRefresh(at index: Int) {
        streamRefreshWorkItem?.cancel()
        let workItem = DispatchWorkItem { [weak self] in
            guard let self else { return }
            delegate?.messageStoreDidUpdateStreamingText(at: index, text: messages[index].text)
            delegate?.messageStoreDidRequestBatchUpdate()
            delegate?.messageStoreDidRequestScroll(force: false)
        }
        streamRefreshWorkItem = workItem
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1, execute: workItem)
    }

    // MARK: - Tool Progress Formatting

    private static func formatProgressEvent(_ event: ToolProgressEvent) -> String {
        switch event {
        case let .fileRead(path, lineCount, preview):
            let previewLines = preview.components(separatedBy: .newlines).prefix(3)
            let previewText = previewLines.joined(separator: "\n")
            return String(format: String(localized: "chat.progress.file_read_format"), path, lineCount) + "\n```\n\(previewText)\n```"
        case let .fileEdited(path, applied, total, diffPreview):
            return String(format: String(localized: "chat.progress.file_edited_format"), path, applied, total) + "\n\(diffPreview)"
        case let .searchCompleted(desc, count):
            return String(format: String(localized: "chat.progress.search_completed_format"), desc, count)
        case let .thinking(content):
            return content
        default:
            return event.displayText
        }
    }
}
