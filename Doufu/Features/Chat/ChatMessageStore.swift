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

/// Notified whenever messages are mutated, enabling external auto-persistence.
@MainActor
protocol ChatMessageStoreMutationDelegate: AnyObject {
    func messageStoreDidMutateMessages()
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
        /// A live tool message is tracking an executing tool call.
        case tool(messageIndex: Int)
    }

    private(set) var flowState: FlowState = .idle

    weak var delegate: ChatMessageStoreDelegate?
    weak var mutationDelegate: ChatMessageStoreMutationDelegate?

    private(set) var messages: [ChatMessage] = []

    /// Timestamp when the current request started (used for cancel/error messages).
    private var requestStartedAt: Date?

    private var didAppendCancelMessage = false
    private var lastProgressPhaseText: String?
    private var pendingProgressText: String?
    private var progressDebounceTask: Task<Void, Never>?
    private var streamRefreshTask: Task<Void, Never>?
    private var thinkingIndicatorTask: Task<Void, Never>?

    init() {}

    // MARK: - Request Lifecycle

    /// Called by `ChatSession.sendMessage(_:...)` before execution starts.
    func beginRequest(startedAt: Date) {
        requestStartedAt = startedAt
        didAppendCancelMessage = false
        lastProgressPhaseText = nil
        // flowState should already be .idle here; enforce it.
        flowState = .idle
        scheduleThinkingIndicator()
    }

    // MARK: - Incoming Events (State Machine Inputs)

    /// Receive a tool progress event from the coordinator.
    /// If a tool message is live, updates its summary (the cell display text).
    /// Otherwise transitions to `.progress`.
    func receiveProgressEvent(_ event: ToolProgressEvent) {
        cancelThinkingIndicator()
        // If a tool message is currently live, route the event to update its summary.
        if case let .tool(index) = flowState {
            let text = Self.formatProgressEvent(event)
            let normalized = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return }
            messages[index].summary = normalized
            delegate?.messageStoreDidUpdateCell(at: index, message: messages[index])
            return
        }

        let displayText = Self.formatProgressEvent(event)
        let normalized = displayText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalized.isEmpty else { return }
        // Dedup: skip if the text is identical to the current progress.
        guard normalized != lastProgressPhaseText else { return }

        // Cancel any pending debounced transition.
        progressDebounceTask?.cancel()
        pendingProgressText = normalized

        // During the 50ms window, the OLD live cell stays live — no gap.
        progressDebounceTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 50_000_000) // 50ms
            guard !Task.isCancelled, let self else { return }
            self.pendingProgressText = nil
            self.transitionToProgress(text: normalized)
        }
    }

    /// Receive the latest accumulated text from the LLM streaming response.
    /// The value is the full response text so far (not a delta).
    func receiveStreamedText(_ accumulatedText: String) {
        cancelThinkingIndicator()
        let trimmed = accumulatedText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }

        // Cancel any pending progress transition — streaming takes priority
        // when they race (the LLM started outputting text).
        progressDebounceTask?.cancel()
        progressDebounceTask = nil

        switch flowState {
        case .idle:
            let index = insertLiveMessage(role: .assistant, content: trimmed, isProgress: false, startedAt: Date())
            flowState = .streaming(messageIndex: index)

        case .progress(let oldIndex), .tool(let oldIndex):
            // Atomic transition: finalize progress/tool → create streaming.
            let now = Date()
            finalizeMessage(at: oldIndex, finishedAt: now)
            let newIndex = insertLiveMessage(role: .assistant, content: trimmed, isProgress: false, startedAt: now)
            flowState = .streaming(messageIndex: newIndex)

        case .streaming(let index):
            // Same cell — just update content.
            messages[index].content = trimmed
            scheduleStreamedCellRefresh(at: index)
        }
    }

    /// Called when the coordinator completes successfully.
    /// Finalizes the active cell or promotes streaming to the final assistant message.
    func completeWithResult(
        content: String,
        requestTokenUsage: ProjectChatService.RequestTokenUsage?,
        summary: String?
    ) {
        cancelPendingWorkItems()
        let now = Date()
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)

        switch flowState {
        case .streaming(let index):
            // Promote the streaming cell to the final assistant message.
            if !normalizedContent.isEmpty {
                messages[index].content = normalizedContent
            }
            messages[index].finishedAt = now
            messages[index].requestTokenUsage = requestTokenUsage
            messages[index].summary = summary
            delegate?.messageStoreDidUpdateCell(at: index, message: messages[index])
            delegate?.messageStoreDidRequestBatchUpdate()

        case .progress(let index), .tool(let index):
            // Finalize the progress/tool cell, then insert a separate final assistant message.
            finalizeMessage(at: index, finishedAt: now)
            if !normalizedContent.isEmpty {
                appendMessage(
                    role: .assistant,
                    content: normalizedContent,
                    startedAt: requestStartedAt,
                    finishedAt: now,
                    requestTokenUsage: requestTokenUsage,
                    summary: summary
                )
            }

        case .idle:
            // No streaming/progress happened (very fast response).
            if !normalizedContent.isEmpty {
                appendMessage(
                    role: .assistant,
                    content: normalizedContent,
                    startedAt: requestStartedAt,
                    finishedAt: now,
                    requestTokenUsage: requestTokenUsage,
                    summary: summary
                )
            }
        }

        flowState = .idle
        mutationDelegate?.messageStoreDidMutateMessages()
    }

    /// Called when the coordinator reports cancellation.
    func handleCancellation() {
        cancelPendingWorkItems()
        let now = Date()

        finalizeActiveFlowCell(finishedAt: now)

        if !didAppendCancelMessage {
            appendMessage(
                role: .system,
                content: String(localized: "chat.system.request_cancelled"),
                startedAt: requestStartedAt
            )
            didAppendCancelMessage = true
        }

        flowState = .idle
        mutationDelegate?.messageStoreDidMutateMessages()
    }

    /// Called when the coordinator reports an error.
    func handleError(_ error: Error) {
        cancelPendingWorkItems()
        let now = Date()

        finalizeActiveFlowCell(finishedAt: now)

        appendMessage(
            role: .system,
            content: error.localizedDescription,
            startedAt: requestStartedAt
        )

        flowState = .idle
        mutationDelegate?.messageStoreDidMutateMessages()
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
        mutationDelegate?.messageStoreDidMutateMessages()
    }

    // MARK: - Tool Messages

    /// Insert a new live tool message (tool execution just started).
    /// `summary` holds the description shown in the cell; `content` is empty
    /// until the tool completes and fills in the detailed result.
    func insertLiveToolMessage(_ description: String) {
        cancelThinkingIndicator()
        cancelPendingWorkItems()
        let now = Date()
        finalizeActiveFlowCell(finishedAt: now)
        let index = insertLiveMessage(role: .tool, content: description, isProgress: false, startedAt: now)
        messages[index].summary = description
        flowState = .tool(messageIndex: index)
    }

    /// Finalize (or append) a completed tool message from a `ToolActivityEntry`.
    /// - `summary` = short description (cell display).
    /// - `content` = JSON-encoded `[ToolActivityEntry]` (detail page).
    /// If `flowState == .tool(index)`: updates and finalizes that live message.
    /// Otherwise: directly appends a new already-completed tool message.
    func appendCompletedToolMessage(_ entry: ToolActivityEntry) {
        let json = (try? JSONEncoder().encode([entry]))
            .flatMap { String(data: $0, encoding: .utf8) }
        let now = Date()

        if case let .tool(index) = flowState {
            messages[index].content = json ?? entry.description
            messages[index].summary = entry.description
            messages[index].finishedAt = now
            flowState = .idle
            delegate?.messageStoreDidUpdateCell(at: index, message: messages[index])
            delegate?.messageStoreDidRequestBatchUpdate()
            mutationDelegate?.messageStoreDidMutateMessages()
            scheduleThinkingIndicator()
        } else {
            appendMessage(
                role: .tool,
                content: json ?? entry.description,
                startedAt: now,
                finishedAt: now,
                summary: entry.description
            )
            // Parallel batch: delay so rapid consecutive results don't each
            // spawn a thinking cell. Only the last one in the batch fires.
            scheduleThinkingIndicator()
        }
    }

    // MARK: - User / System Messages (outside the flow state machine)

    /// Append a user or system message. These are immediately finalized.
    @discardableResult
    func appendMessage(
        role: ChatMessage.Role,
        content: String,
        isProgress: Bool = false,
        startedAt: Date? = nil,
        finishedAt: Date? = nil,
        requestTokenUsage: ProjectChatService.RequestTokenUsage? = nil,
        summary: String? = nil
    ) -> Int? {
        let normalizedContent = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedContent.isEmpty else { return nil }

        let createdAt = Date()
        let startedAt = startedAt ?? createdAt
        let resolvedFinishedAt = finishedAt ?? (isProgress ? nil : createdAt)

        messages.append(
            ChatMessage(
                role: role,
                content: normalizedContent,
                createdAt: createdAt,
                startedAt: startedAt,
                finishedAt: resolvedFinishedAt,
                isProgress: isProgress,
                requestTokenUsage: requestTokenUsage,
                summary: summary
            )
        )
        let newIndex = messages.count - 1
        delegate?.messageStoreDidInsertRow(at: newIndex)
        delegate?.messageStoreDidRequestScroll(force: false)
        mutationDelegate?.messageStoreDidMutateMessages()
        return newIndex
    }

    // MARK: - History / Persistence

    func buildHistoryTurns() -> [ProjectChatService.ChatTurn] {
        messages.compactMap { message in
            let normalized = message.content.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { return nil }
            switch message.role {
            case .user:
                return .init(id: message.id.uuidString, role: .user, text: normalized)
            case .assistant:
                if message.isProgress { return nil }
                return .init(id: message.id.uuidString, role: .assistant, text: normalized, toolSummary: message.summary)
            case .system, .tool:
                return nil
            }
        }
    }

    func replaceMessages(_ newMessages: [ChatMessage]) {
        messages = newMessages
        flowState = .idle
    }

    // MARK: - Private — State Transitions

    /// Atomic transition to `.progress`. Finalizes the current live cell first.
    private func transitionToProgress(text: String) {
        let now = Date()

        // Cancel any pending stream refresh from a previous streaming phase
        // to avoid stale index updates after the state transition.
        streamRefreshTask?.cancel()
        streamRefreshTask = nil

        // Finalize whatever is currently live.
        finalizeActiveFlowCell(finishedAt: now)

        lastProgressPhaseText = text
        let newIndex = insertLiveMessage(role: .assistant, content: text, isProgress: true, startedAt: now)
        flowState = .progress(messageIndex: newIndex)
    }

    /// Insert a message with `finishedAt == nil` (live cell).
    @discardableResult
    private func insertLiveMessage(
        role: ChatMessage.Role,
        content: String,
        isProgress: Bool,
        startedAt: Date
    ) -> Int {
        let createdAt = Date()
        messages.append(
            ChatMessage(
                role: role,
                content: content,
                createdAt: createdAt,
                startedAt: startedAt,
                finishedAt: nil,
                isProgress: isProgress,
                requestTokenUsage: nil,
                summary: nil
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
        case .tool(let index):
            finalizeMessage(at: index, finishedAt: finishedAt)
        }
    }

    private func cancelPendingWorkItems() {
        progressDebounceTask?.cancel()
        progressDebounceTask = nil
        streamRefreshTask?.cancel()
        streamRefreshTask = nil
        thinkingIndicatorTask?.cancel()
        thinkingIndicatorTask = nil
    }

    /// Schedules a "Thinking" progress indicator after a short delay.
    /// Cancelled automatically when any real event arrives.
    private func scheduleThinkingIndicator() {
        thinkingIndicatorTask?.cancel()
        thinkingIndicatorTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            guard !Task.isCancelled, let self else { return }
            self.thinkingIndicatorTask = nil
            guard self.flowState == .idle else { return }
            let thinkingText = String(localized: "orchestrator.thinking")
            self.transitionToProgress(text: thinkingText)
        }
    }

    private func cancelThinkingIndicator() {
        thinkingIndicatorTask?.cancel()
        thinkingIndicatorTask = nil
    }

    /// Coalesces rapid streaming updates into a single cell refresh (100ms window).
    private func scheduleStreamedCellRefresh(at index: Int) {
        streamRefreshTask?.cancel()
        streamRefreshTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
            guard !Task.isCancelled, let self else { return }
            self.delegate?.messageStoreDidUpdateStreamingText(at: index, text: self.messages[index].content)
            self.delegate?.messageStoreDidRequestBatchUpdate()
            self.delegate?.messageStoreDidRequestScroll(force: false)
        }
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
